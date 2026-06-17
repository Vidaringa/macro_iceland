# Monthly — Wage index / launavísitala (Hagstofa) ----
# Launavísitala from PX-Web table LAU04000.px, monthly from 1989. We pull the
# index LEVEL (canonical source-of-truth) and the year-on-year change
# (Ársbreyting, %) — the headline wage-growth number the BVAR reads (SPEC A2).
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# wage_index (date, series, value), upsert on (date, series). `series` is
# WAGE_index / WAGE_change_A.

get_hagstofa_wage_index <- function() {
  hagstofa_pxweb_query(
    "Samfelag/launogtekjur/2_lvt/1_manadartolur/LAU04000.px",
    selections = list("Eining" = c("index", "change_A"))
  ) |>
    dplyr::transmute(
      date   = hagstofa_month_to_date(`Mánuður`),
      series = paste0("WAGE_", `Eining`),
      value
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

wage_index_tbl <- get_hagstofa_wage_index()

db_ensure_table(con, "wage_index",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "wage_index", wage_index_tbl, conflict_cols = c("date", "series"))
