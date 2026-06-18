# Monthly — international reserves (Seðlabankinn) ----
# CBI official international reserves, total, in USD millions, from the SDDS/NSDP
# feed (group 30, NSDP.EXS.BPINRE.XXX.USD.IS.N.M, TimeSeriesID 130). External /
# FX-flow heat-index input (SPEC A1/A7).
#
# Sourced by run_monthly.R, which provides `con`, has attached tidyverse + xml2,
# and sourced the DB helpers and R/ingest/sedlabanki.R. Target table:
# reserves (date, series, value), upsert on (date, series).
#
# HISTORY DEPTH: like all group-30 SDDS/NSDP series, the feed serves only a
# rolling ~last-12-months window, so a single run backfills ~1 year; history
# accretes as the scheduled monthly run appends new months via upsert.

get_cbi_reserves <- function() {
  cbi_series(130) |>
    dplyr::transmute(date, series = "RESERVES_USD_M", value) |>
    dplyr::arrange(date)
}

reserves_tbl <- get_cbi_reserves()

db_ensure_table(con, "reserves",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "reserves", reserves_tbl, conflict_cols = c("date", "series"))
