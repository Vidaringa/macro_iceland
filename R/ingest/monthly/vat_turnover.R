# Bi-monthly — VAT turnover (Hagstofa) ----
# Velta samkvæmt virðisaukaskattsskýrslum from PX-Web FYR04101.px: total
# economy-wide turnover (Atvinnugrein = Alls, vsk-þrep = Alls), reported per
# bi-monthly VAT period from 2008. A demand/activity heat-index input (SPEC A1).
#
# Cadence: VAT periods are bi-monthly (Jan-Feb, Mar-Apr, ...), so this updates
# six times a year, not monthly — the runner's per-source tryCatch handles the
# ragged edge between periods. Each period is dated to its FIRST month
# (Tímabil 08 -> January, 16 -> March, 24 -> May, 32 -> July, 40 -> September,
# 48 -> November).
#
# Only the economy-wide total is stored at launch; the table also carries a
# 62-industry breakdown that can be added later if the DFM wants sector detail.
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# vat_turnover (date, series, value), upsert on (date, series).

# VAT-period code -> first month of the period.
vat_period_month <- c("08" = 1L, "16" = 3L, "24" = 5L,
                      "32" = 7L, "40" = 9L, "48" = 11L)

get_hagstofa_vat_turnover <- function() {
  hagstofa_pxweb_query(
    "Atvinnuvegir/fyrirtaeki/veltutolur/velta/FYR04101.px",
    selections = list(
      "Atvinnugrein (ÍSAT2008)" = "Alls",
      "vsk-þrep"                = "Alls"
    )
  ) |>
    dplyr::transmute(
      date   = lubridate::make_date(as.integer(`Ár`),
                                    unname(vat_period_month[`Tímabil`]), 1L),
      series = "VAT_TURNOVER_TOTAL",
      value
    ) |>
    dplyr::filter(!is.na(value), !is.na(date)) |>
    dplyr::arrange(date)
}

vat_turnover_tbl <- get_hagstofa_vat_turnover()

db_ensure_table(con, "vat_turnover",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "vat_turnover", vat_turnover_tbl, conflict_cols = c("date", "series"))
