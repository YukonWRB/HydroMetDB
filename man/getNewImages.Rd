% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/getNewImages.R
\name{getNewImages}
\alias{getNewImages}
\title{Get new images}
\usage{
getNewImages(image_meta_ids = "all", con = hydrometConnect(silent = TRUE))
}
\arguments{
\item{image_meta_ids}{A vector of image_meta_id's. Default 'all' fetches all ids where img_type = 'auto'.}

\item{con}{A connection to the database, created with \code{\link[DBI:dbConnect]{DBI::dbConnect()}} or using the utility function \code{\link[=hydrometConnect]{hydrometConnect()}}.}
}
\description{
\ifelse{html}{\href{https://lifecycle.r-lib.org/articles/stages.html#stable}{\figure{lifecycle-stable.svg}{options: alt='[Stable]'}}}{\strong{[Stable]}}

Retrieves new data corresponding to entries in the table "images_index". As with the timeseries table, fetching new data depends on the function listed in the source_fx column of the relevant table and optionally on parameters in column source_fx_args. Refer to \code{\link[=addHydrometTimeseries]{addHydrometTimeseries()}} for a description of how to formulate these arguments.
\subsection{Default arguments passed to 'source_fx' functions:}{

This function passes default arguments to the "source_fx" function: 'location' gets the location referenced by the column 'location_id', start_datetime defaults to the instant after the last point already existing in the DB. Additional parameters can be passed using the "source_fx_args" column in the "timeseries" table.
}
}
