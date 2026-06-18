# Shared Seðlabankinn (Central Bank of Iceland) xmltimeseries helpers
#
# The CBI serves time series from an ASP.NET feed at
#   https://www.sedlabanki.is/xmltimeseries/Default.aspx
# addressed either by a single TimeSeriesID or by a whole GroupID, both with a
# DagsFra/DagsTil date window. The existing daily sources (policy rate, REIBOR,
# FX) already hit this feed by TimeSeriesID; these helpers add (a) group
# discovery — list every series ID + Name + Description in a group, so the right
# TimeSeriesID is FOUND from the feed's own captions rather than guessed
# (INGEST_TASK §0) — and (b) a single-series pull returning a tidy tibble.
#
# Sourced by run_*.R, which have attached tidyverse + xml2 (+ httr2).

CBI_XMLTS <- "https://www.sedlabanki.is/xmltimeseries/Default.aspx"

# List every series in a group: its TimeSeriesID (the <TimeSeries ID="..."> attr),
# Name and Description. Used to locate the exact ID for a wanted series.
cbi_group_catalog <- function(group_id, from = "2000-01-01", to = Sys.Date()) {
  url <- paste0(CBI_XMLTS, "?GroupID=", group_id,
                "&DagsFra=", from, "&DagsTil=", to, "&Type=xml")
  x <- xml2::read_xml(url)
  ts <- xml2::xml_find_all(x, ".//TimeSeries")
  tibble::tibble(
    time_series_id = xml2::xml_attr(ts, "ID"),
    name           = xml2::xml_text(xml2::xml_find_first(ts, "./Name")),
    description    = xml2::xml_text(xml2::xml_find_first(ts, "./Description"))
  )
}

# Pull a single CBI series by TimeSeriesID into a tidy (date, value) tibble.
# Dates in the feed are mm/dd/yyyy h:m:s; values numeric. NA-valued entries
# (non-publication points) are dropped so callers log-miss rather than store NA.
cbi_series <- function(time_series_id, from = "2000-01-01", to = Sys.Date()) {
  url <- paste0(CBI_XMLTS, "?TimeSeriesID=", time_series_id,
                "&DagsFra=", from, "&DagsTil=", to, "&Type=xml")
  x <- xml2::read_xml(url)
  entries <- xml2::xml_find_all(x, ".//Entry")
  tibble::tibble(
    date = lubridate::mdy_hms(
      xml2::xml_text(xml2::xml_find_first(entries, ".//Date"))
    ) |> as.Date(),
    value = as.numeric(
      xml2::xml_text(xml2::xml_find_first(entries, ".//Value"))
    )
  ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date)
}
