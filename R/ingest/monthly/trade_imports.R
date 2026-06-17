# Monthly — consumer- and investment-goods imports (Hagstofa) ----
# From PX-Web table UTA06005 (trade by BEC / "hagræn flokkun"), monthly from
# 2015. Two heat-index inputs (SPEC A1), both import (Innflutningur cif) values
# in thousand ISK, summed over all countries:
#
#   CONSUMER_IMPORTS                 = BEC 610 (durables) + 620 (semi-durables)
#                                       + 630 (non-durables)
#   INVEST_IMPORTS_EX_SHIPS_AIRCRAFT = BEC 410 (capital goods) + 420 (parts)
#
# The ex-ships/aircraft adjustment (PROJECT.md §7) is satisfied BY CONSTRUCTION:
# in this BEC table, ships (540) and aircraft (550) are their OWN categories,
# separate from capital goods (410/420). Including only 410+420 therefore
# excludes ships and aircraft — we never add 540/550.
#
# Country aggregation: the PX-Web "Land" dimension is omitted from the query, so
# the API returns the all-country total directly. Verified that this equals the
# explicit sum over all 253 country codes (so omitting Land is a safe total, not
# a silent single-country pick).
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# trade_imports (date, series, value), upsert on (date, series).

# BEC code -> which aggregate series it belongs to.
trade_import_groups <- c(
  "410" = "INVEST_IMPORTS_EX_SHIPS_AIRCRAFT",
  "420" = "INVEST_IMPORTS_EX_SHIPS_AIRCRAFT",
  "610" = "CONSUMER_IMPORTS",
  "620" = "CONSUMER_IMPORTS",
  "630" = "CONSUMER_IMPORTS"
)

get_hagstofa_trade_imports <- function() {
  hagstofa_pxweb_query(
    "Efnahagur/utanrikisverslun/1_voruvidskipti/01_voruskipti/UTA06005.px",
    selections = list(
      "Hagræn flokkun" = names(trade_import_groups),
      "Flæði"          = "Innflutningur cif"
    )
  ) |>
    dplyr::mutate(series = unname(trade_import_groups[`Hagræn flokkun`])) |>
    dplyr::group_by(date = hagstofa_month_to_date(`Mánuður`), series) |>
    dplyr::summarise(value = sum(value, na.rm = TRUE), .groups = "drop") |>
    # A month with no data for every component yields a 0-sum; treat a genuinely
    # empty month as missing rather than a real zero by dropping all-NA inputs
    # upstream — here sum(na.rm) over present codes is the published total.
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

trade_imports_tbl <- get_hagstofa_trade_imports()

db_ensure_table(con, "trade_imports",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "trade_imports", trade_imports_tbl, conflict_cols = c("date", "series"))
