# Monthly — new company registrations + bankruptcies (Hagstofa) ----
# From PX-Web FYR03001.px (new registrations and bankruptcies by month), total
# across all industries (Atvinnugreinar = Alls) and all legal forms
# (Rekstrarform = Alls). Two business-demography heat-index inputs (SPEC A1),
# monthly from 2008:
#
#   NEW_REGISTRATIONS = Fjöldi nýskráninga  (count of new company registrations)
#   BANKRUPTCIES      = Fjöldi gjaldþrota    (count of company bankruptcies)
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# company_registrations (date, series, value), upsert on (date, series).

company_reg_vars <- c(
  "Fjöldi nýskráninga" = "NEW_REGISTRATIONS",
  "Fjöldi gjaldþrota"  = "BANKRUPTCIES"
)

get_hagstofa_company_registrations <- function() {
  hagstofa_pxweb_query(
    "Atvinnuvegir/fyrirtaeki/skradfyrirtaeki/2_skraningar/FYR03001.px",
    selections = list(
      "Atvinnugreinar" = "Alls",
      "Rekstrarform"   = "Alls",
      "Breytur"        = names(company_reg_vars)
    )
  ) |>
    dplyr::transmute(
      date   = hagstofa_month_to_date(`Mánuður`),
      series = unname(company_reg_vars[`Breytur`]),
      value
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

company_registrations_tbl <- get_hagstofa_company_registrations()

db_ensure_table(con, "company_registrations",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "company_registrations", company_registrations_tbl,
          conflict_cols = c("date", "series"))
