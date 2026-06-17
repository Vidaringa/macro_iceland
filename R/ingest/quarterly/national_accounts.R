# Quarterly — national accounts: GDP & domestic demand (Hagstofa) ----
# From PX-Web THJ01601.px (GDP by quarter, 1995-). The headline cycle read
# (SPEC A1 / national accounts): GDP and its main expenditure components, each
# as the chain-linked REAL level (Keðjutengt verðmæti) and the year-on-year %
# change (Ársbreyting eftir ársfjórðungum):
#
#   GDP             = 8. Verg landsframleiðsla
#   DOMESTIC_DEMAND = 5. Þjóðarútgjöld alls (total national expenditure)
#   PRIV_CONS       = 1. Einkaneysla (private consumption)
#   INVESTMENT      = 3. Fjármunamyndun (gross capital formation)
#
# Non-seasonally-adjusted is taken on purpose (consistent with the other
# sources): the DFM/BVAR handle seasonality. The seasonally adjusted variants
# exist in the same table (Mælikvarði 3-7) if ever needed.
#
# Sourced by run_quarterly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# national_accounts (date, series, value), upsert on (date, series). `series`
# is <COMPONENT>_real / <COMPONENT>_yoy.

na_components <- c("0" = "PRIV_CONS", "2" = "INVESTMENT",
                   "7" = "DOMESTIC_DEMAND", "14" = "GDP")
na_measures   <- c("1" = "real", "2" = "yoy")

get_hagstofa_national_accounts <- function() {
  hagstofa_pxweb_query(
    "Efnahagur/thjodhagsreikningar/landsframl/2_landsframleidsla_arsfj/THJ01601.px",
    selections = list(
      "Mælikvarði" = names(na_measures),
      "Skipting"   = names(na_components)
    )
  ) |>
    dplyr::transmute(
      date   = hagstofa_quarter_to_date(`Ársfjórðungur`),
      series = paste0(unname(na_components[`Skipting`]), "_",
                      unname(na_measures[`Mælikvarði`])),
      value
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

national_accounts_tbl <- get_hagstofa_national_accounts()

db_ensure_table(con, "national_accounts",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "national_accounts", national_accounts_tbl,
          conflict_cols = c("date", "series"))
