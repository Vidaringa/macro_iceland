# Daily — commodities: Brent crude + aluminium (public, via quantmod/Yahoo) ----
# Brent front-month crude (USD/bbl) and LME-linked aluminium (USD/tonne), both
# daily closes from Yahoo Finance through quantmod — no API key. Brent feeds the
# derived Brent-in-ISK series downstream (computed later, not scraped here).
#
# Symbols verified live before wiring (INGEST_TASK §0): BZ=F is Brent
# front-month (~79 USD/bbl); ALI=F is the aluminium future (~3700 USD/tonne).
# (Yahoo's CB=F is NOT Brent, and FRED's aluminium series are monthly, not daily
# — so neither is used here.)
#
# Sourced by run_daily.R, which provides `con`, has attached tidyverse +
# quantmod, and sourced the DB helpers. Target table: commodities_daily
# (date, series, value), upsert on (date, series). `series` is BRENT / ALUMINIUM.

commodity_symbols <- c(
  "BRENT"     = "BZ=F",
  "ALUMINIUM" = "ALI=F"
)

get_commodities <- function(symbols = commodity_symbols,
                            from = as.Date("2000-01-01")) {
  purrr::imap(symbols, \(sym, label) {
    x <- quantmod::getSymbols(sym, src = "yahoo", from = from,
                              auto.assign = FALSE)
    tibble::tibble(
      date   = as.Date(zoo::index(x)),
      series = label,
      value  = as.numeric(quantmod::Cl(x))
    )
  }) |>
    purrr::list_rbind() |>
    # Yahoo carries NA closes on non-trading days; log-miss rather than store NA.
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

commodities_tbl <- get_commodities()

db_ensure_table(con, "commodities_daily",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "commodities_daily", commodities_tbl,
          conflict_cols = c("date", "series"))
