# Daily — CBI FX intervention (Seðlabankinn) ----
# The Central Bank's own buying and selling of foreign currency in the domestic
# FX market (group 8, "Velta á gjaldeyrismarkaði"): FX_SALE = 285
# (Gjaldeyrissala SÍ í ISK, CBI sells FX) and FX_BUY = 287 (Gjaldeyriskaup SÍ í
# ISK, CBI buys FX), in ISK. An FX-flow input (SPEC A7); most days are 0 because
# the CBI intervenes only occasionally.
#
# Sourced by run_daily.R, which provides `con`, has attached tidyverse + xml2,
# and sourced the DB helpers and R/ingest/sedlabanki.R. Target table:
# fx_intervention (date, series, value), upsert on (date, series).

fx_intervention_ids <- c("FX_SALE" = 285, "FX_BUY" = 287)

get_cbi_fx_intervention <- function(ids = fx_intervention_ids) {
  purrr::imap(ids, \(id, label) {
    cbi_series(id) |>
      dplyr::transmute(date, series = label, value)
  }) |>
    purrr::list_rbind() |>
    dplyr::arrange(series, date)
}

fx_intervention_tbl <- get_cbi_fx_intervention()

db_ensure_table(con, "fx_intervention",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "fx_intervention", fx_intervention_tbl,
          conflict_cols = c("date", "series"))
