# A2 (market reading) — Market-implied policy-rate path from REIBOR ----
#
# A near-term expected policy path backed out of the REIBOR money-market curve
# (SPEC A2: the market-implied reading shown alongside the BVAR density). REIBOR
# fixings embed the market's expected AVERAGE policy rate over each tenor plus a
# term/credit premium; removing a fixed premium and inverting a linear-path
# assumption gives the expected policy LEVEL at 1/3/6 months. This is the reading
# that prices central-bank turns the BVAR cannot anticipate — in validation it
# went negative months before the 2024-25 cutting cycle (the level VAR stayed flat).
#
# Honest horizon: REIBOR only informs ~6 months, so this path stops at 6m (it is
# NOT extrapolated to the BVAR's 18m). It is a POINT path (no density), stored at
# quantile 0.5 with source='market' in the shared forecast_policy_rate table.
#
# Term premium: the spread of each tenor's REIBOR over the realised average policy
# rate, estimated ONCE over a calm window (2015-2019) and FROZEN in
# market_term_premium (insert-if-absent, version-aware) — the fixed-once convention.
#
# Sourced by run_models.R (provides `con`; tidyverse attached; DB helpers sourced).

MODEL_VERSION <- "A2-market-v1"
TP_REF_START  <- as.Date("2015-01-01")   # calm reference window for the term premium
TP_REF_END    <- as.Date("2019-12-31")
TENOR_MONTHS  <- c("1M" = 1L, "3M" = 3L, "6M" = 6L)   # REIBOR tenors used, in months

# 1.0.0 PULL ----
# Month-end REIBOR curve and month-end policy rate.
reibor <- dplyr::tbl(con, "rates_reibor") |>
  dplyr::filter(tenor %in% c("1M", "3M", "6M")) |>
  dplyr::select(date, tenor, reibor) |>
  dplyr::collect() |>
  dplyr::mutate(m = lubridate::floor_date(date, "month")) |>
  dplyr::group_by(m, tenor) |>
  dplyr::slice_max(date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(date = m, tenor, reibor)

policy <- dplyr::tbl(con, "rates_policy") |>
  dplyr::select(date, policy_rate) |>
  dplyr::collect() |>
  dplyr::mutate(m = lubridate::floor_date(date, "month")) |>
  dplyr::group_by(m) |>
  dplyr::slice_max(date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(date = m, policy = policy_rate)

curve <- reibor |>
  tidyr::pivot_wider(names_from = tenor, values_from = reibor) |>
  dplyr::inner_join(policy, by = "date") |>
  dplyr::arrange(date)

# 2.0.0 TERM PREMIUM (frozen) ----
# For each tenor k, term_premium = mean over the calm window of
# (REIBOR_k - realised average policy over the next k months). Frozen so the
# implied path is comparable across vintages.
realised_avg <- function(x, k) {
  vapply(seq_along(x), function(i) {
    j <- i + k - 1L
    if (j > length(x)) NA_real_ else mean(x[i:j])
  }, numeric(1))
}

db_ensure_table(con, "market_term_premium",
                cols = c(tenor = "TEXT", premium = "DOUBLE PRECISION",
                         ref_start = "DATE", ref_end = "DATE",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("tenor"))
# re-baseline if params predate this version
DBI::dbExecute(con, "DELETE FROM market_term_premium WHERE model_version IS DISTINCT FROM $1",
               params = list(MODEL_VERSION))
tp_existing <- dplyr::tbl(con, "market_term_premium") |>
  dplyr::select(tenor, premium) |> dplyr::collect()

if (nrow(tp_existing) < length(TENOR_MONTHS)) {
  tp_new <- purrr::imap_dfr(TENOR_MONTHS, function(k, tnr) {
    ra <- realised_avg(curve$policy, k)
    prem <- mean(curve[[tnr]][curve$date >= TP_REF_START & curve$date <= TP_REF_END] -
                 ra[curve$date >= TP_REF_START & curve$date <= TP_REF_END], na.rm = TRUE)
    tibble::tibble(tenor = tnr, premium = prem)
  }) |>
    dplyr::filter(!tenor %in% tp_existing$tenor) |>
    dplyr::mutate(ref_start = TP_REF_START, ref_end = TP_REF_END,
                  model_version = MODEL_VERSION, computed_at = Sys.time())
  db_upsert(con, "market_term_premium", tp_new, conflict_cols = c("tenor"))
  tp_existing <- dplyr::bind_rows(tp_existing, dplyr::select(tp_new, tenor, premium))
}
premium <- rlang::set_names(tp_existing$premium, tp_existing$tenor)

# 3.0.0 IMPLIED PATH (latest curve) ----
# Expected average policy over the next k months = REIBOR_k - premium_k. Under a
# locally-linear path from the current policy level p0, the expected LEVEL at the
# horizon end h_k is end ~= 2 * exp_avg_k - p0. The O/N-anchored 1m point is taken
# directly. Horizons: 1, 3, 6 months.
latest <- dplyr::slice_max(curve, date, n = 1, with_ties = FALSE)
origin_date <- latest$date
p0 <- latest$policy

market_path <- purrr::imap_dfr(TENOR_MONTHS, function(k, tnr) {
  exp_avg <- latest[[tnr]] - premium[[tnr]]
  tibble::tibble(horizon = k, value = 2 * exp_avg - p0)
}) |>
  dplyr::arrange(horizon) |>
  dplyr::mutate(
    origin_date   = origin_date,
    forecast_date = origin_date %m+% months(horizon),
    source        = "market",
    quantile      = 0.5,            # point path, no density
    model_version = MODEL_VERSION,
    computed_at   = Sys.time()
  ) |>
  dplyr::select(origin_date, horizon, forecast_date, source, quantile, value,
                model_version, computed_at)

# 4.0.0 WRITE ----
# Shares forecast_policy_rate with the BVAR reading (source distinguishes them).
# This module sorts before policy_rate_path.R, so it may run first; drop a pre-
# source-column table once here so it recreates with the source-aware schema
# (the BVAR module has the same guard for whichever order they run in).
if (DBI::dbExistsTable(con, "forecast_policy_rate") &&
    !"source" %in% DBI::dbListFields(con, "forecast_policy_rate")) {
  DBI::dbRemoveTable(con, "forecast_policy_rate")
}
db_ensure_table(con, "forecast_policy_rate",
                cols = c(origin_date = "DATE", horizon = "INTEGER",
                         forecast_date = "DATE", source = "TEXT",
                         quantile = "DOUBLE PRECISION",
                         value = "DOUBLE PRECISION", model_version = "TEXT",
                         computed_at = "TIMESTAMPTZ"),
                pk = c("origin_date", "horizon", "source", "quantile"))
db_upsert(con, "forecast_policy_rate", market_path,
          conflict_cols = c("origin_date", "horizon", "source", "quantile"))
