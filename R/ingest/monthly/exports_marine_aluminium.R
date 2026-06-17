# Monthly — marine export value + aluminium export volume (Hagstofa) ----
# From the foreign-trade SITC table UTA06107.px (exports by SITC 1&2, monthly,
# 2015-). Two external heat-index inputs (SPEC A1), summed over all countries:
#
#   MARINE_EXPORT_VALUE  = SITC 03 (fish & processed fish), Útflutningur fob
#                          (export value, thousand ISK)
#   ALUMINIUM_EXPORT_TONS = SITC 68 (non-ferrous metals), Útflutningur tonn
#                          (export volume, tonnes)
#
# Cadence note: data_sources.md lists these as monthly. Hagstofa's fisheries /
# industry export tables are ANNUAL; the monthly figures only exist in this
# foreign-trade SITC table, which is why the value/volume come from here.
#
# Aluminium proxy note: this SITC1&2 table resolves to 2-digit groups, so the
# closest aluminium code is SITC 68 "Málmar aðrir en járn" (non-ferrous metals),
# not aluminium-only (SITC 684). For Iceland this is a tight proxy — non-ferrous
# metal exports are overwhelmingly aluminium — and the tonnage (~50-70k t/month)
# matches national aluminium output. Stored honestly as ALUMINIUM_EXPORT_TONS
# from the SITC 68 group; if a 684-only series is ever needed it requires the
# SITC-3-digit table (UTA06108, which currently ends 2025).
#
# Country aggregation: the Land dimension is omitted, returning the all-country
# total (verified equivalent to summing all countries, as for trade_imports).
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# exports_marine_aluminium (date, series, value), upsert on (date, series).

UTA_EXPORT_SITC <- "Efnahagur/utanrikisverslun/1_voruvidskipti/01_voruskipti/UTA06107.px"

get_hagstofa_marine_aluminium_exports <- function() {
  marine <- hagstofa_pxweb_query(
    UTA_EXPORT_SITC,
    selections = list("SITC" = "03", "Flæði" = "0")   # fish, value (fob)
  ) |>
    dplyr::transmute(date = hagstofa_month_to_date(`Mánuður`),
                     series = "MARINE_EXPORT_VALUE", value)

  aluminium <- hagstofa_pxweb_query(
    UTA_EXPORT_SITC,
    selections = list("SITC" = "68", "Flæði" = "1")   # non-ferrous metals, tonnes
  ) |>
    dplyr::transmute(date = hagstofa_month_to_date(`Mánuður`),
                     series = "ALUMINIUM_EXPORT_TONS", value)

  dplyr::bind_rows(marine, aluminium) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

exports_marine_aluminium_tbl <- get_hagstofa_marine_aluminium_exports()

db_ensure_table(con, "exports_marine_aluminium",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "exports_marine_aluminium", exports_marine_aluminium_tbl,
          conflict_cols = c("date", "series"))
