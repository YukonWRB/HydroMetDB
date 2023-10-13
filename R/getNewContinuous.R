#' Get new continuous-type data
#'
#' @description
#' `r lifecycle::badge("stable")`
#'
#' Retrieves new real-time data starting from the last data point in the local database, using the function specified in the timeseries table column "source_fx". Only works on stations that are ALREADY in the measurements_continuous table and that have a proper entry in the timeseries table; refer to [addHydrometTimeseries()] for how to add new stations. Does not work on any timeseries of category "discrete": for that, use [getNewDiscrete()]. Timeseries with no specified souce_fx will be ignored.
#'
#' ## Default arguments passed to 'source_fx' functions:
#' This function passes default arguments to the "source_fx" function: 'location' gets the location as entered in the 'timeseries' table, 'param_code' gets the parameter code defined in the 'settings' table, and start_datetime defaults to the instant after the last point already existing in the DB. Each of these can however be set using the "source_fx_args" column in the "timeseries" table; refer to [addHydrometTimeseries()] for a description of how to formulate these arguments.
#'
#' ## Assigning measurement periods:
#' With the exception of "instantaneous" timeseries which automatically receive a period of "00:00:00" (0 time), the period associated with measurements (ex: 1 hour precipitation sum) is derived from the interval between measurements UNLESS a period column is provided by the source function (column source_fx, may also depend on source_fx_args). This function typically fetches only a few hours of measurements at a time, so if the interval cannot be conclusively determined from the new data (i.e. hourly measurements over four hours with two measurements missed) then additional data points will be pulled from the database.
#'
#' If a period supplied by any data fetch function cannot be coerced to an period object acceptable to "duration" data type, NULL values will be entered to differentiate from instantaneous periods of "00:00:00".
#'
#' @param con A connection to the database, created with [DBI::dbConnect()] or using the utility function [hydrometConnect()].
#' @param timeseries_id The timeseries_ids you wish to have updated, as character or numeric vector. Defaults to "all", which means all timeseries of category 'continuous'.
#'
#' @return The database is updated in-place, and a data.frame is generated with one row per updated location.
#' @export

 getNewContinuous <- function(con = hydrometConnect(silent=TRUE), timeseries_id = "all")
{
  settings <- DBI::dbGetQuery(con,  "SELECT source_fx, parameter, remote_param_name FROM settings;")
  if (timeseries_id[1] == "all"){
    all_timeseries <- DBI::dbGetQuery(con, "SELECT location, parameter, timeseries_id, source_fx, source_fx_args, end_datetime, type FROM timeseries WHERE category = 'continuous' AND source_fx IS NOT NULL;")
  } else {
    all_timeseries <- DBI::dbGetQuery(con, paste0("SELECT location, parameter, timeseries_id, source_fx, source_fx_args, end_datetime, type FROM timeseries WHERE timeseries_id IN ('", paste(timeseries_id, collapse = "', '"), "') AND category = 'continuous' AND source_fx IS NOT NULL;"))
    if (length(timeseries_id) != nrow(all_timeseries)){
      warning("At least one of the timeseries IDs you called for cannot be found in the database, is not of category 'continuous', or has no function specified in column source_fx.")
    }
  }

  count <- 0 #counter for number of successful new pulls
  success <- data.frame("location" = NULL, "parameter" = NULL, "timeseries" = NULL)
  for (i in 1:nrow(all_timeseries)){
    loc <- all_timeseries$location[i]
    parameter <- all_timeseries$parameter[i]
    tsid <- all_timeseries$timeseries_id[i]
    source_fx <- all_timeseries$source_fx[i]
    source_fx_args <- all_timeseries$source_fx_args[i]
    param_code <- settings[settings$parameter == parameter & settings$source_fx == source_fx , "remote_param_name"]
    last_data_point <- all_timeseries$end_datetime[i] + 1 #one second after the last data point
    type <- all_timeseries$type[i]

    tryCatch({
      args_list <- list(location = loc, param_code = param_code, start_datetime = last_data_point)
      if (!is.na(source_fx_args)){ #add some arguments if they are specified
        args <- strsplit(source_fx_args, "\\},\\s*\\{")
        pairs <- lapply(args, function(pair){
          gsub("[{}]", "", pair)
          })
        pairs <- lapply(pairs, function(pair){
          gsub("\"", "", pair)
        })
        pairs <- lapply(pairs, function(pair){
          gsub("'", "", pair)
        })
        pairs <- strsplit(unlist(pairs), "=")
        pairs <- lapply(pairs, function(pair){
          trimws(pair)
        })
        for (j in 1:length(pairs)){
          args_list[[pairs[[j]][1]]] <- pairs[[j]][[2]]
        }
      }

      ts <- do.call(source_fx, args_list) #Get the data using the args_list

      ts <- ts[!is.na(ts$value) , ]

      if (nrow(ts) > 0){
        if (type == "instantaneous"){ #Period is always 0 for instantaneous data
          ts$period <- "00:00:00"
          no_period <- data.frame() # Created here for use later
        } else if ((type != "instantaneous") & !("period" %in% names(ts))) { #types of mean, median, min, max should all have a period
          # Get datetimes from the earliest missing period to calculate necessary values, as some might be missing
          no_period <- DBI::dbGetQuery(con, paste0("SELECT datetime, value, grade, approval FROM measurements_continuous WHERE timeseries_id = ", tsid, " AND datetime >= (SELECT MIN(datetime) FROM measurements_continuous WHERE period IS NULL AND timeseries_id = ", tsid, ");"))
          if (nrow(no_period) > 0){
            ts <- rbind(ts, no_period)
          }
          ts <- ts[order(ts$datetime) ,] #Sort ascending
          diffs <- as.numeric(diff(ts$datetime), units = "hours")
          smoothed_diffs <- zoo::rollmedian(diffs, k = 3, fill = NA, align = "center")
          # Initialize variables to track changes
          consecutive_count <- 0
          changes <- data.frame()
          last_diff <- 0
          for (j in 1:length(smoothed_diffs)) {
            if (!is.na(smoothed_diffs[j]) && smoothed_diffs[j] < 25 && smoothed_diffs[j] != last_diff) { # Check if smoothed interval is less than threshold, which is set to more than a whole day (greatest interval possible is 24 hours) as well as not the same as the last recorded diff
              consecutive_count <- consecutive_count + 1
              if (consecutive_count == 3) { # At three consecutive new measurements it's starting to look like a pattern
                last_diff <- smoothed_diffs[j]
                change <- data.frame(datetime = ts$datetime[j-3],
                                     period = last_diff)
                changes <- rbind(changes, change)
                consecutive_count <- 0
              }
            } else {
              consecutive_count <- 0
            }
          }
          # Calculate the duration in days, hours, minutes, and seconds and assign to the right location in ts
          ts$period <- NA
          if (nrow(changes) > 0){
            for (j in 1:nrow(changes)){
              days <- floor(changes$period[j] / 24)
              remaining_hours <- changes$period[j] %% 24
              minutes <- floor((remaining_hours - floor(remaining_hours)) * 60)
              seconds <- round(((remaining_hours - floor(remaining_hours)) * 60 - minutes) * 60)
              ts[ts$datetime == changes$datetime[j]+10*60, "period"] <- paste("P", days, "DT", floor(remaining_hours), "H", minutes, "M", seconds, "S", sep = "")
            }
            #carry non-na's forward and backwards, if applicable
            ts$period <- zoo::na.locf(zoo::na.locf(ts$period, na.rm = FALSE), fromLast=TRUE)

          } else { #In this case there were too few measurements to conclusively determine a period so pull a few from the DB and redo the calculation
            no_period <- DBI::dbGetQuery(con, paste0("SELECT datetime, value, grade, approval FROM measurements_continuous WHERE timeseries_id = ", tsid, " ORDER BY datetime DESC LIMIT 10;"))
            ts <- rbind(ts, no_period)
            ts <- ts[order(ts$datetime), ]
            diffs <- as.numeric(diff(ts$datetime), units = "hours")
            smoothed_diffs <- zoo::rollmedian(diffs, k = 3, fill = NA, align = "center")
            consecutive_count <- 0
            changes <- data.frame()
            last_diff <- 0
            for (j in 1:length(smoothed_diffs)) {
              if (!is.na(smoothed_diffs[j]) && smoothed_diffs[j] < 25 && smoothed_diffs[j] != last_diff) {
                consecutive_count <- consecutive_count + 1
                if (consecutive_count == 3) {
                  last_diff <- smoothed_diffs[j]
                  change <- data.frame(datetime = ts$datetime[j-3],
                                       period = last_diff)
                  changes <- rbind(changes, change)
                  consecutive_count <- 0
                }
              } else {
                consecutive_count <- 0
              }
            }
            if (nrow(changes) > 0){
              for (k in 1:nrow(changes)){
                days <- floor(changes$period[k] / 24)
                remaining_hours <- changes$period[k] %% 24
                minutes <- floor((remaining_hours - floor(remaining_hours)) * 60)
                seconds <- round(((remaining_hours - floor(remaining_hours)) * 60 - minutes) * 60)
                ts[ts$datetime == changes$datetime[k]+10*60, "period"] <- paste("P", days, "DT", floor(remaining_hours), "H", minutes, "M", seconds, "S", sep = "")
              }
              #carry non-na's forward and backwards, if applicable
              ts$period <- zoo::na.locf(zoo::na.locf(ts$period, na.rm = FALSE), fromLast=TRUE)
            } else {
              ts$period <- NULL
            }
          }
        } else { #Check to make sure that the supplied period can actually be coerced to a period
          check <- lubridate::period(unique(ts$period))
          if (NA %in% check){
            ts$period <- NA
          }
        }
        ts$timeseries_id <- tsid
        # The column for "imputed" defaults to FALSE in the DB, so even though it is NOT NULL it doesn't need to be specified UNLESS this function gets modified to impute values.
        DBI::dbWithTransaction(
          con, {
            if (nrow(no_period) > 0){
              DBI::dbExecute(con, paste0("DELETE FROM measurements_continous WHERE datetime >= '", min(ts$datetime), "' AND timeseries_id = ", tsid, ";"))
            }
            DBI::dbAppendTable(con, "measurements_continuous", ts)
            #make the new entry into table timeseries
            DBI::dbExecute(con, paste0("UPDATE timeseries SET end_datetime = '", max(ts$datetime),"', last_new_data = '", .POSIXct(Sys.time(), "UTC"), "' WHERE timeseries_id = ", tsid, ";"))
            count <- count + 1
            success <- rbind(success, data.frame("location" = loc, "parameter" = parameter, "timeseries_id" = tsid))
          }
        )
      }
    }, error = function(e) {
      warning("getNewContinuous: Failed to get new data or to append new data at location ", loc, " and parameter ", parameter, " (timeseries_id ", all_timeseries$timeseries_id[i], ").")
    }) #End of tryCatch
  } #End of iteration over each location + param
  message(count, " out of ", nrow(all_timeseries), " timeseries were updated.")
  DBI::dbExecute(con, paste0("UPDATE internal_status SET value = '", .POSIXct(Sys.time(), "UTC"), "' WHERE event = 'last_new_continuous'"))
  if (nrow(success) > 0){
    return(success)
  }
} #End of function
