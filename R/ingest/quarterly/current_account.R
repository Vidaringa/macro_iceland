# Quarterly — current account (Seðlabankinn) ----
# Balance-of-payments current account from the CBI xmltimeseries SDDS/NSDP feed
# (group 30, series NSDP.EXS.BPCAAC.XXX.ISK.IS.N.Q, TimeSeriesID 83). This is the
# external-balance series data_sources.md lists (attributed to Hagstofa, but the
# full BoP current account is a Seðlabankinn statistic — see UNRESOLVED note that
# this entry resolves). Quarterly, in million ISK; a deficit prints negative.
#
# Sourced by run_quarterly.R, which provides `con`, has attached tidyverse +
# xml2, and sourced the DB helpers and R/ingest/sedlabanki.R. Target table:
# current_account (date, series, value), upsert on (date, series).
#
# HISTORY DEPTH: the SDDS/NSDP feed (group 30) only serves a rolling ~last-4-
# quarters window regardless of the requested DagsFra — so a single run backfills
# only ~1 year. There is no deep backfill from this feed. The upsert is what
# saves us: each scheduled run appends the newest quarter and never overwrites,
# so history ACCRETES over time. (A deeper backfill, if needed, requires a
# different CBI release — logged for awareness in UNRESOLVED_SOURCES.md.)

get_cbi_current_account <- function() {
  cbi_series(83) |>
    dplyr::transmute(date, series = "CURRENT_ACCOUNT", value) |>
    dplyr::arrange(date)
}

current_account_tbl <- get_cbi_current_account()

db_ensure_table(con, "current_account",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "current_account", current_account_tbl,
          conflict_cols = c("date", "series"))
