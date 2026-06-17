# Daily — euro-area external rate anchors (ECB Data Portal) ----
# ECB deposit facility rate (the key policy rate), and the euro-area AAA-rated
# central-government spot yields at 2y and 10y. These join the FRED US anchors in
# rates_external as the BVAR's external rate inputs (SPEC A2).
#
# NOTE on the 2y/10y: data_sources.md asks for "Bund 2y/10y" (German). The ECB
# Data Portal publishes the euro-area AAA-government spot curve (YC flow), which
# is Germany-quality and tracks Bunds very closely but is NOT German-only — so
# these are stored honestly as EA_AAA_2Y / EA_AAA_10Y, not BUND_*. (Decision
# taken with the user: use the ECB AAA curve, labelled as what it is.) Both keys
# verified live against the ECB API before wiring.
#
# Sourced by run_daily.R, which provides `con`, has attached tidyverse + httr2,
# and sourced the DB helpers and R/ingest/ecb.R. Target table: rates_external
# (date, series, value), upsert on (date, series).

# series label -> (flow, key). Verified live: ECB_DEPO = deposit facility rate
# level (FM flow); EA_AAA_* = AAA euro-area government spot rate at the tenor
# (YC flow, SV_C_YM curve).
ecb_rate_specs <- tibble::tribble(
  ~series,       ~flow, ~key,
  "ECB_DEPO",    "FM",  "D.U2.EUR.4F.KR.DFR.LEV",
  "EA_AAA_2Y",   "YC",  "B.U2.EUR.4F.G_N_A.SV_C_YM.SR_2Y",
  "EA_AAA_10Y",  "YC",  "B.U2.EUR.4F.G_N_A.SV_C_YM.SR_10Y"
)

get_ecb_rates <- function(specs = ecb_rate_specs) {
  purrr::pmap(specs, \(series, flow, key) {
    ecb_series(flow, key) |>
      dplyr::mutate(series = series, .after = date)
  }) |>
    purrr::list_rbind() |>
    dplyr::arrange(series, date)
}

ecb_rates_tbl <- get_ecb_rates()

db_ensure_table(con, "rates_external",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "rates_external", ecb_rates_tbl, conflict_cols = c("date", "series"))
