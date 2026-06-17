# Daily — Policy rate components (Seðlabankinn) ----
# 7-day term deposit rate (headline), current account rate,
# overnight rate, collateralised lending rate.
#
# Sourced by run_daily.R, which provides `con` (the shared connection) and has
# already attached tidyverse + xml2 and sourced the DB helpers. Target table:
# rates_policy (date, policy_rate), upsert on date.

get_cbi_policy_rate <- function(from = "2009-01-01", to = Sys.Date()) {

  url <- paste0(
    "https://www.sedlabanki.is/xmltimeseries/Default.aspx?",
    "DagsFra=", from,
    "&DagsTil=", to,
    "&TimeSeriesID=17923",
    "&Type=xml"
  )

  x <- xml2::read_xml(url)
  entries <- xml2::xml_find_all(x, ".//Entry")

  tibble::tibble(
    date = lubridate::mdy_hms(
      xml2::xml_text(xml2::xml_find_first(entries, ".//Date"))
    ) |> as.Date(),
    policy_rate = as.numeric(
      xml2::xml_text(xml2::xml_find_first(entries, ".//Value"))
    )
  ) |>
    dplyr::arrange(date)
}

policy_rate_tbl <- get_cbi_policy_rate()

db_upsert(con, "rates_policy", policy_rate_tbl, conflict_cols = "date")
