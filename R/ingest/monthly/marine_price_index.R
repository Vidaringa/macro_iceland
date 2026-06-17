# Monthly — marine-product price index (Hagstofa) ----
# Verðvísitala sjávarafurða from PX-Web SJA06100.px (base 2005Q4=100), monthly
# from 2006. We take the headline marine-product price index (Flokkur = PPI) as
# both the index LEVEL and the year-on-year change — an external/terms-of-trade
# heat-index input (SPEC A1). The table also carries ~19 species/product
# subindices (cod, haddock, fishmeal, ...) which we do not pull at launch.
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# marine_price_index (date, series, value), upsert on (date, series). `series`
# is MARINE_PPI_index / MARINE_PPI_change_A.

get_hagstofa_marine_price_index <- function() {
  hagstofa_pxweb_query(
    "Atvinnuvegir/sjavarutvegur/verdvisitolursjav/verdvisitolur/SJA06100.px",
    selections = list(
      "Flokkur" = "PPI",                  # headline marine-product price index
      "Liður"   = c("index", "change_A")
    )
  ) |>
    dplyr::transmute(
      date   = hagstofa_month_to_date(`Mánuður`),
      series = paste0("MARINE_PPI_", `Liður`),
      value
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

marine_price_index_tbl <- get_hagstofa_marine_price_index()

db_ensure_table(con, "marine_price_index",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "marine_price_index", marine_price_index_tbl,
          conflict_cols = c("date", "series"))
