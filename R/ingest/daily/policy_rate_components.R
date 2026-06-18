# Daily — policy-rate corridor components (Seðlabankinn) ----
# The four CBI policy-rate components (group 1, "Vextir Seðlabankans"), found by
# group-catalogue lookup against the feed's own Name/Description captions:
#
#   DEPOSIT_7D        = 17923 Meginvextir (7-day term deposit, the headline)
#   CURRENT_ACCOUNT   = 28    Vextir á viðskiptareikningum (current-account rate)
#   OVERNIGHT_LENDING = 24    Vextir á daglánum (overnight lending rate)
#   COLLAT_LENDING_7D = 55    Vextir á 7 daga veðlánum (7-day collateralised lending)
#
# The existing daily source (policy_rate.R) keeps writing the headline 7-day rate
# to rates_policy (date, policy_rate) for the app's existing contract. This file
# adds the full corridor (including the headline, for a self-contained component
# table) in long form, completing the policy-rate component set the spec asks for.
#
# Sourced by run_daily.R, which provides `con`, has attached tidyverse + xml2,
# and sourced the DB helpers and R/ingest/sedlabanki.R. Target table:
# rates_policy_components (date, series, value), upsert on (date, series).

policy_rate_component_ids <- c(
  "DEPOSIT_7D"        = 17923,
  "CURRENT_ACCOUNT"   = 28,
  "OVERNIGHT_LENDING" = 24,
  "COLLAT_LENDING_7D" = 55
)

get_cbi_policy_rate_components <- function(ids = policy_rate_component_ids) {
  purrr::imap(ids, \(id, label) {
    cbi_series(id) |>
      dplyr::transmute(date, series = label, value)
  }) |>
    purrr::list_rbind() |>
    dplyr::arrange(series, date)
}

policy_rate_components_tbl <- get_cbi_policy_rate_components()

db_ensure_table(con, "rates_policy_components",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "rates_policy_components", policy_rate_components_tbl,
          conflict_cols = c("date", "series"))
