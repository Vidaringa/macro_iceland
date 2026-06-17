# Daily — US external rate anchors (FRED) ----
# Daily effective Fed funds rate (DFF), and US Treasury constant-maturity
# 2-year (DGS2) and 10-year (DGS10) yields, via the FRED API (fredr package).
# These are the external rate anchors the BVAR uses (SPEC A2 inputs).
#
# Sourced by run_daily.R, which provides `con`, has attached tidyverse, sourced
# the DB helpers, and lifted the FRED key out of the HOME .Renviron into the
# session env (named FRED_API_KEY or FREDR). Target table: rates_external
# (date, series, value), upsert on (date, series). `series` is FED_FUNDS /
# UST_2Y / UST_10Y.
#
# The DFM/BVAR only need recent history; we pull from 2000 to keep the series
# long enough for the model's lookback without fetching the full archive daily.

# Resolve the FRED key under either env name, set it for fredr, and skip the
# source (raising so run_daily logs it) if no key is present — rather than
# silently writing nothing.
local({
  key <- Sys.getenv("FRED_API_KEY")
  if (!nzchar(key)) key <- Sys.getenv("FREDR")
  if (!nzchar(key)) stop("No FRED API key (FRED_API_KEY / FREDR) in env")
  fredr::fredr_set_key(key)
})

fred_series <- c(
  "FED_FUNDS" = "DFF",
  "UST_2Y"    = "DGS2",
  "UST_10Y"   = "DGS10"
)

get_fred_rates <- function(series = fred_series, from = as.Date("2000-01-01")) {
  purrr::imap(series, \(id, label) {
    fredr::fredr(series_id = id, observation_start = from) |>
      dplyr::transmute(date, series = label, value)
  }) |>
    purrr::list_rbind() |>
    # FRED returns NA on non-publication days (weekends/holidays for DGS*);
    # log-miss those rather than write NA rows.
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

fred_rates_tbl <- get_fred_rates()

db_ensure_table(con, "rates_external",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "rates_external", fred_rates_tbl, conflict_cols = c("date", "series"))
