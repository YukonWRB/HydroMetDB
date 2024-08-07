#' Get new discrete-category data
#'
#' @description
#' `r lifecycle::badge("stable")`
#'
#' Retrieves new discrete data starting from the last data point in the local database, using the function specified in the timeseries table column "source_fx". Only works on stations that are ALREADY in the discrete table and that have a proper entry in the timeseries table; refer to [addACTimeseries()] for how to add new stations. Does not work on any timeseries of category "continuous": for that, use [getNewContinuous()]. Timeseries with no specified souce_fx will be ignored.
#'
#' ## Default arguments passed to 'source_fx' functions:
#' This function passes default arguments to the "source_fx" function: 'location' gets the location as entered in the 'timeseries' table, 'param_code' gets the parameter code defined in the 'settings' table, and start_datetime defaults to the instant after the last point already existing in the DB. Additional parameters can be passed using the "source_fx_args" column in the "timeseries" table; refer to [addACTimeseries()] for a description of how to formulate these arguments.
#' 
#' ## Sharing privileges and ownership
#' The parameters of column share_with of table timeseries will be used to determine which users will have access to the new data and the owner column will be used to determine the owner of the new data.
#'
#' @param con A connection to the database, created with [DBI::dbConnect()] or using the utility function [AquaConnect()].
#' @param timeseries_id The timeseries_ids you wish to have updated, as character or numeric vector. Defaults to "all", which means all timeseries of category 'discrete'.
#' @param active Sets behavior for import of new data. If set to 'default', the function will look to the column 'active' in the 'timeseries' table to determine if new data should be fetched. If set to 'all', the function will ignore the 'active' column and import all data.

#'
#' @return The database is updated in-place, and a data.frame is generated with one row per updated location.
#' @export
#'

getNewDiscrete <- function(con = AquaConnect(silent = TRUE), timeseries_id = "all", active = 'default') {

  
  if (!active %in% c('default', 'all')) {
    stop("Parameter 'active' must be either 'default' or 'all'.")
  }
  
  # Create table of timeseries
  if (timeseries_id[1] == "all") {
    all_timeseries <- DBI::dbGetQuery(con, "SELECT location, parameter, timeseries_id, source_fx, source_fx_args, end_datetime, period_type, record_rate, share_with, owner, active FROM timeseries WHERE category = 'discrete' AND source_fx IS NOT NULL;")
  } else {
    all_timeseries <- DBI::dbGetQuery(con, paste0("SELECT location, parameter, timeseries_id, source_fx, source_fx_args, end_datetime, period_type, record_rate, share_with, owner, active FROM timeseries WHERE timeseries_id IN ('", paste(timeseries_id, collapse = "', '"), "') AND category = 'discrete' AND source_fx IS NOT NULL;"))
    if (length(timeseries_id) != nrow(all_timeseries)) {
      warning("At least one of the timeseries IDs you called for cannot be found in the database, is not of category 'discrete', or has no function specified in column source_fx.")
    }
  }
  
  if (active == 'default') {
    all_timeseries <- all_timeseries[all_timeseries$active == TRUE, ]
  }

  count <- 0 #counter for number of successful new pulls
  success <- data.frame("location" = NULL, "parameter" = NULL, "timeseries" = NULL)

  # Run for loop over timeseries rows
  EQcon <- NULL #This prevents multiple connections to EQcon...
  snowCon <- NULL
  for (i in 1:nrow(all_timeseries)) {
    loc <- all_timeseries$location[i]
    parameter <- all_timeseries$parameter[i]
    period_type <- all_timeseries$period_type[i]
    record_rate <- all_timeseries$record_rate[i]
    tsid <- all_timeseries$timeseries_id[i]
    source_fx <- all_timeseries$source_fx[i]
    share_with <- all_timeseries$share_with[i]
    owner <- all_timeseries$owner[i]
    
    if (source_fx == "downloadEQWin" & is.null(EQcon)) {
      EQcon <- EQConnect(silent = TRUE)
      on.exit(DBI::dbDisconnect(EQcon), add = TRUE)
    }
    if (source_fx == "downloadSnowCourse" & is.null(snowCon)) {
      snowCon <- snowConnect(silent = TRUE)
      on.exit(DBI::dbDisconnect(snowCon), add = TRUE)
    }
    source_fx_args <- all_timeseries$source_fx_args[i]
    if (is.na(record_rate)) {
      param_code <- DBI::dbGetQuery(con, paste0("SELECT remote_param_name FROM settings WHERE parameter = '", parameter, "' AND source_fx = '", source_fx, "' AND period_type = '", period_type, "' AND record_rate IS NULL;"))[1,1]
    } else {
      param_code <- DBI::dbGetQuery(con, paste0("SELECT remote_param_name FROM settings WHERE parameter = '", parameter, "' AND source_fx = '", source_fx, "' AND period_type = '", period_type, "' AND record_rate = '", record_rate, "';"))[1,1]
    }
    last_data_point <- all_timeseries$end_datetime[i] + 1 #one second after the last data point

    tryCatch({
      args_list <- list(location = loc, param_code = param_code, start_datetime = last_data_point)
      # Connections to snow and eqwin are set before the source_fx_args are made, that way source_fx_args will override the same named param.
      if (source_fx == "downloadEQWin") {
        args_list[["EQcon"]] <- EQcon
      }
      if (source_fx == "downloadSnowCourse") {
        args_list[["snowCon"]] <- snowCon
        args_list[["ACCon"]] <- con
      }
      if (!is.na(source_fx_args)) { #add some arguments if they are specified
        args <- strsplit(source_fx_args, "\\},\\s*\\{")
        pairs <- lapply(args, function(pair) {
          gsub("[{}]", "", pair)
        })
        pairs <- lapply(pairs, function(pair) {
          gsub("\"", "", pair)
        })
        pairs <- lapply(pairs, function(pair) {
          gsub("'", "", pair)
        })
        pairs <- strsplit(unlist(pairs), "=")
        pairs <- lapply(pairs, function(pair) {
          trimws(pair)
        })
        for (j in 1:length(pairs)) {
          args_list[[pairs[[j]][1]]] <- pairs[[j]][[2]]
        }
      }

      ts <- do.call(source_fx, args_list) #Get the data using the args_list
      ts <- ts[!is.na(ts$value) , ]

      if (!is.na(owner)) {
        ts$owner <- owner
      }
      ts$share_with <- share_with
      
      if (nrow(ts) > 0) {
        ts$timeseries_id <- tsid
        DBI::dbWithTransaction(
          con, {
            if (min(ts$datetime) < last_data_point - 1) { #This might happen because a source_fx is feeding in data before the requested datetime. Example: downloadSnowCourse if a new station is run in parallel with an old station, and the offset between the two used to adjust "old" measurements to the new measurements.
              DBI::dbExecute(con, paste0("DELETE FROM measurements_discrete WHERE datetime >= '", min(ts$datetime), "' AND timeseries_id = ", tsid, ";"))
            }
            DBI::dbAppendTable(con, "measurements_discrete", ts)
            #make the new entry into table timeseries
            DBI::dbExecute(con, paste0("UPDATE timeseries SET end_datetime = '", max(ts$datetime),"', last_new_data = '", .POSIXct(Sys.time(), "UTC"), "' WHERE timeseries_id = ", tsid, ";"))
            count <- count + 1
            success <- rbind(success, data.frame("location" = loc, "parameter" = parameter, "timeseries_id" = tsid))
          }
        )
      }
    }, error = function(e) {
      warning("getNewDiscrete: Failed to get new data or to append new data at location ", loc, " and parameter ", parameter, " (timeseries_id ", all_timeseries$timeseries_id[i], ").")
    }) #End of tryCatch
  } #End of iteration over each location + param

  message(count, " out of ", nrow(all_timeseries), " timeseries were updated.")
  DBI::dbExecute(con, paste0("UPDATE internal_status SET value = '", .POSIXct(Sys.time(), "UTC"), "' WHERE event = 'last_new_discrete'"))

  if (nrow(success) > 0) {
    return(success)
  }
}
