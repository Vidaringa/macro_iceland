# Daily — REIBOR fixings (Seðlabankinn), O/N and 1, 3, 6 months ----
# CBI xmltimeseries feed, one TimeSeriesID per tenor. The IDs are NOT
# consecutive and do not match tenor order: IDs 18/19 return no data, and
# the bid-side REIBID series sit at 3-8, so the REIBOR ask-side fixings we
# want are 12 (O/N), 13 (1M), 15 (3M), 16 (6M). Verified against the feed's
# <TimeSeries><Name> captions.
#
# Sourced by run_daily.R, which provides `con` and has already attached
# tidyverse + xml2 and sourced the DB helpers. Target table: rates_reibor
# (date, tenor, reibor), upsert on (date, tenor).
reibor_series <- c(
  "O/N" = 12,
  "1M"  = 13,
  "3M"  = 15,
  "6M"  = 16
)

get_cbi_reibor <- function(series = reibor_series,
                           from = "2000-01-01", to = Sys.Date()) {

  purrr::imap(series, \(id, tenor) {
    url <- paste0(
      "https://www.sedlabanki.is/xmltimeseries/Default.aspx?",
      "DagsFra=", from,
      "&DagsTil=", to,
      "&TimeSeriesID=", id,
      "&Type=xml"
    )

    x <- xml2::read_xml(url)
    entries <- xml2::xml_find_all(x, ".//Entry")

    tibble::tibble(
      date = lubridate::mdy_hms(
        xml2::xml_text(xml2::xml_find_first(entries, ".//Date"))
      ) |> as.Date(),
      tenor  = tenor,
      reibor = as.numeric(
        xml2::xml_text(xml2::xml_find_first(entries, ".//Value"))
      )
    )
  }) |>
    purrr::list_rbind() |>
    dplyr::arrange(date, tenor)
}

reibor_tbl <- get_cbi_reibor()

db_ensure_table(con, "rates_reibor",
                cols = c(date = "DATE", tenor = "TEXT", reibor = "DOUBLE PRECISION"),
                pk = c("date", "tenor"))
db_upsert(con, "rates_reibor", reibor_tbl, conflict_cols = c("date", "tenor"))
