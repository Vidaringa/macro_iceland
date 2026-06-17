# Shared ECB Data Portal (SDMX REST) query helper
#
# The ECB Data Portal serves public time series over an SDMX REST API with no
# key required. We request CSV ("csvdata") and parse it — simpler and more
# robust than the XML SDMX, and avoids needing an SDMX R package. Each series is
# addressed by a dataflow + a dot-separated series key (both verified against the
# live API before use — never guessed, per INGEST_TASK §0).
#
# Sourced by run_daily.R / run_monthly.R, which have attached tidyverse + httr2.

ECB_DATA_API <- "https://data-api.ecb.europa.eu/service/data/"

# Fetch one ECB series and return a tidy tibble (date, value). `flow` is the
# dataflow id (e.g. "FM", "YC"); `key` is the series key under it. `from`
# restricts the start date server-side.
ecb_series <- function(flow, key, from = "2000-01-01") {
  url <- paste0(ECB_DATA_API, flow, "/", key,
                "?startPeriod=", from, "&format=csvdata")
  resp <- httr2::request(url) |>
    httr2::req_timeout(60) |>
    httr2::req_perform()

  readr::read_csv(I(httr2::resp_body_string(resp)), show_col_types = FALSE) |>
    dplyr::transmute(
      date  = as.Date(TIME_PERIOD),
      value = as.numeric(OBS_VALUE)
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date)
}
