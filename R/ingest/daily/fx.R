# Daily — ISK exchange rates (Seðlabankinn): USD, EUR, GBP + trade-weighted ----
# Same CBI xmltimeseries feed. The currency mid-rates ("skráð miðgengi") live
# in group 9 ("Opinbert viðmiðunargengi SÍ"), where each currency has three
# IDs (buy/mid/sell) but only the mid is populated: USD 4055, EUR 4064,
# GBP 4103. The trade-weighted index is the narrow trade weight (vísitala
# meðalgengis, viðskiptavog þröng), ID 4117. The same group also carries the
# wide weights and the goods-only (vöruskiptavog) variants — 4114 Vöruskiptavog
# víð, 4115 Vöruskiptavog þröng, 4116 Viðskiptavog víð — which we do not use.
# (The minor currencies in group 7 do NOT include the majors.)
# Verified against each series' <Name>/<Description> captions.
#
# Sourced by run_daily.R, which provides `con` and has already attached
# tidyverse + xml2 and sourced the DB helpers. Target table: fx_daily
# (date, series, value), upsert on (date, series).
fx_series <- c(
  "USD" = 4055,
  "EUR" = 4064,
  "GBP" = 4103,
  "TWI" = 4117
)

get_cbi_fx <- function(series = fx_series,
                       from = "2000-01-01", to = Sys.Date()) {

  purrr::imap(series, \(id, label) {
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
      date  = lubridate::mdy_hms(
        xml2::xml_text(xml2::xml_find_first(entries, ".//Date"))
      ) |> as.Date(),
      series = label,
      value  = as.numeric(
        xml2::xml_text(xml2::xml_find_first(entries, ".//Value"))
      )
    )
  }) |>
    purrr::list_rbind() |>
    dplyr::arrange(date, series)
}

fx_tbl <- get_cbi_fx()

db_ensure_table(con, "fx_daily",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "fx_daily", fx_tbl, conflict_cols = c("date", "series"))
