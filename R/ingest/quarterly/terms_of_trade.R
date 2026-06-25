# Quarterly — terms of trade, goods + services (Hagstofa, derived) ----
# The dedicated goods terms-of-trade table (UTA07002) is discontinued at 2021.
# The live replacement is the quarterly national accounts THJ01601.px, which
# carries exports and imports of goods AND services at both current prices
# (Mælikvarði 0, Verðlag hvers árs) and chain-linked volume (Mælikvarði 1,
# Keðjutengt verðmæti). The implicit price deflator of each flow is
# current / volume, and terms of trade = export deflator / import deflator —
# the standard national-accounts (goods+services) terms-of-trade concept, live
# to 2026. A relative-price / external-balance read (SPEC A1).
#
# Skipting codes are 0-based and were read from the table metadata, NOT guessed:
#   "8"  = 6. Útflutningur alls (total exports)
#   "11" = 7. Innflutningur alls (total imports)
# (verified against THJ01601 metadata — "6"/"7" are inventory changes / domestic
# demand, so guessing them would have been silently wrong.)
#
# Sourced by run_quarterly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# terms_of_trade (date, series, value), upsert on (date, series). Series are the
# two implicit deflators and the terms-of-trade index, each a ~100-based index
# (= 100 in the national-accounts chain-link reference year).

tot_skipting <- c("8" = "EXPORTS", "11" = "IMPORTS")
tot_measure  <- c("0" = "current", "1" = "volume")

get_hagstofa_terms_of_trade <- function() {
  raw <- hagstofa_pxweb_query(
    "Efnahagur/thjodhagsreikningar/landsframl/2_landsframleidsla_arsfj/THJ01601.px",
    selections = list(
      "Mælikvarði" = names(tot_measure),
      "Skipting"   = names(tot_skipting)
    )
  ) |>
    dplyr::transmute(
      date    = hagstofa_quarter_to_date(`Ársfjórðungur`),
      flow    = unname(tot_skipting[`Skipting`]),
      measure = unname(tot_measure[`Mælikvarði`]),
      value
    ) |>
    dplyr::filter(!is.na(value))

  # Implicit price deflator per flow & quarter = current / chain-linked volume.
  raw |>
    tidyr::pivot_wider(names_from = measure, values_from = value) |>
    dplyr::filter(!is.na(current), !is.na(volume), volume != 0) |>
    dplyr::mutate(deflator = current / volume) |>
    dplyr::select(date, flow, deflator) |>
    tidyr::pivot_wider(names_from = flow, values_from = deflator) |>
    dplyr::filter(!is.na(EXPORTS), !is.na(IMPORTS)) |>
    dplyr::transmute(
      date,
      EXPORT_DEFLATOR_GS = 100 * EXPORTS,
      IMPORT_DEFLATOR_GS = 100 * IMPORTS,
      TERMS_OF_TRADE_GS  = 100 * EXPORTS / IMPORTS
    ) |>
    tidyr::pivot_longer(-date, names_to = "series", values_to = "value") |>
    dplyr::arrange(series, date)
}

terms_of_trade_tbl <- get_hagstofa_terms_of_trade()

db_ensure_table(con, "terms_of_trade",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "terms_of_trade", terms_of_trade_tbl,
          conflict_cols = c("date", "series"))
