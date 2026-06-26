# Monthly — residential house-price index (Hagstofa) ----
# Markaðsverð íbúðarhúsnæðis, whole country, monthly from 2000M05. A core heat-
# index input (SPEC A1) and the deepest housing signal we have: house prices
# crashed through the 2008-09 crisis (YoY +16% in early 2008 to -13% by mid-2009),
# so this series is what makes the GFC visible to the heat index where the
# late-starting trade/VAT series cannot.
#
# Source: Hagstofa "saved query" (sq) endpoint — a stable GUID URL that returns
# the table directly as semicolon-CSV (a simpler GET than the PX-Web POST that
# hagstofa.R wraps). Endpoint GUID taken from the hagdeild/thjodhagslikan project
# (R/data/02_prices.R, "Markaðsverð húsnæðis"). Two columns: month code, index.
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 attached; DB helpers
# sourced). Target table: house_prices (date, series, value), upsert on
# (date, series).

HOUSE_PRICE_SQ <- "https://px.hagstofa.is/pxis/sq/8dce57db-b8db-4b8f-abdc-924217b2b874"

get_hagstofa_house_prices <- function() {
  readr::read_csv2(HOUSE_PRICE_SQ, show_col_types = FALSE,
                   locale = readr::locale(encoding = "UTF-8")) |>
    rlang::set_names(c("month", "value")) |>
    dplyr::transmute(
      date   = lubridate::ym(month),
      series = "HOUSE_PRICE_INDEX",
      value  = as.numeric(value)
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date)
}

house_prices_tbl <- get_hagstofa_house_prices()

db_ensure_table(con, "house_prices",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "house_prices", house_prices_tbl, conflict_cols = c("date", "series"))
