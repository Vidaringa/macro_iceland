# A2 — Policy-rate path (BVAR density forecast) ----
#
# A Bayesian VAR produces a DENSITY forecast of the Central Bank policy rate (a
# fan, not a point), conditioned on the macro state (SPEC A2). The companion
# market-implied reading (policy_rate_market.R) is the responsive near-term path;
# this BVAR is the model-based density + persisted posterior draws (the scenario-
# engine foundation). The reaction-function (ordered-probit) reading is still to
# come. Note the BVAR is persistence-dominated (a level VAR on a ~0.93-AR policy
# rate): it gives the conditional density and longer-horizon view, but does NOT
# anticipate announced policy turns — that is the market reading's job, and both
# are written to forecast_policy_rate (distinguished by `source`) for the app to
# show side by side.
#
# Sourced by run_models.R (provides `con`; tidyverse + BVAR attached; DB helpers
# sourced). Runs after A1 (heat_index.R) — it reads the heat-index factor as an
# input, so model files sort/source alphabetically with heat_index before
# policy_rate. Target tables (upsert):
#   forecast_policy_rate  (origin_date, horizon, quantile)  — central path + bands
#   bvar_policy_draws     (origin_date, horizon, draw)       — full policy-rate draws
#   forecast_macro        (origin_date, horizon, variable, quantile) — the SAME
#     fit's density for every modelled variable (inflation, heat, gap, ECB, FX),
#     not just the policy rate. The VAR is a joint system, so these come free.
#
# Compact-core variable set (estimable on the short ISK sample): policy rate,
# CPI YoY inflation, A1 heat-index factor, ISK trade-weighted index (monthly log
# change), output gap, ECB deposit rate (external anchor). Monthly frequency;
# daily series taken at MONTH-END. Output gap is quarterly -> linearly interpolated
# to monthly (a slow-moving estimate) and carried forward at the ragged edge so the
# forecast origin uses the freshest policy/inflation/FX month.

MODEL_VERSION <- "A2-v1"
BVAR_LAGS     <- 2L
N_DRAW        <- 6000L
N_BURN        <- 2000L
HORIZON       <- 18L            # months ahead
QUANTILES     <- c(0.05, 0.16, 0.50, 0.84, 0.95)   # fixed band definition
SAMPLE_START  <- as.Date("2009-01-01")             # post-redenomination policy regime

# 1.0.0 PULL ----
# Each daily series taken at month-end (the value prevailing at month close). CPI
# YoY and the heat factor are already monthly. Output gap is quarterly.
# month_end_series / monthly_series live in R/models/helpers_bvar.R — the same
# reductions are needed by the FX module, so they are shared rather than repeated.
policy <- month_end_series(con, "rates_policy", series = NULL,
                           out_col = "policy_rate", value_col = "policy_rate")
twi    <- month_end_series(con, "fx_daily", "TWI", "twi")
ecb    <- month_end_series(con, "rates_external", "ECB_DEPO", "ecb")

infl <- monthly_series(con, "cpi", "CPI_change_A", "infl")
heat <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |>
  dplyr::select(date, index) |>
  dplyr::collect() |>
  dplyr::transmute(date, heat = index)
gap_q <- dplyr::tbl(con, "output_gap") |>
  dplyr::select(date, value) |>
  dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), gap = value)

# 2.0.0 ASSEMBLE + TRANSFORM ----
# Common monthly spine from SAMPLE_START to the latest policy month. Output gap
# interpolated to monthly then carried forward past its last quarter (ragged edge).
# ISK TWI enters as the monthly % log change. Rates and inflation enter in levels
# (%), the heat factor as its z-scale. Forecast origin = latest month with policy
# rate, inflation, heat and FX observed (gap carried forward).
spine <- tibble::tibble(
  date = seq(SAMPLE_START, max(policy$date), by = "month")
)
gap_m <- quarterly_to_monthly(spine, gap_q, "gap")

dat <- spine |>
  dplyr::left_join(policy, by = "date") |>
  dplyr::left_join(infl,   by = "date") |>
  dplyr::left_join(heat,   by = "date") |>
  dplyr::left_join(gap_m,  by = "date") |>
  dplyr::left_join(ecb,    by = "date") |>
  dplyr::left_join(twi,    by = "date") |>
  dplyr::arrange(date) |>
  dplyr::mutate(d_ltwi = 100 * (log(twi) - log(dplyr::lag(twi)))) |>
  dplyr::select(date, policy_rate, infl, heat, gap, ecb, d_ltwi)

# Estimation sample: rows where every modelled variable is present. policy_rate is
# column 1 so it stays the forecast target.
dat_fit <- dplyr::filter(dat, dplyr::if_all(-date, ~ !is.na(.)))
origin_date <- max(dat_fit$date)

# 3.0.0 FIT ----
Y <- as.matrix(dplyr::select(dat_fit, -date))
# Column order is load-bearing: policy_rate is column 1 so it stays the forecast
# target sliced at 4.0.0, and these names index pred$fcast's third dimension.
model_vars <- colnames(Y)
fit <- BVAR::bvar(Y, lags = BVAR_LAGS, n_draw = N_DRAW, n_burn = N_BURN,
                  verbose = FALSE)

# 4.0.0 FORECAST ----
# predict() returns $fcast as draws x horizon x variable. Policy rate is variable 1.
# Reshape the draws-x-horizon matrix to long (draw, horizon, rate) once; both
# outputs build off it.
pred <- predict(fit, horizon = HORIZON)
policy_draws <- pred$fcast[, , 1]               # n_draw x HORIZON

draws_long <- tibble::tibble(
  draw    = rep(seq_len(nrow(policy_draws)), times = HORIZON),
  horizon = rep(seq_len(HORIZON), each = nrow(policy_draws)),
  rate    = as.numeric(policy_draws)
)

# 5.0.0 WRITE ----
now <- Sys.time()

# forecast_policy_rate — central path (q50) + fixed bands, long over (horizon, quantile).
# `source` distinguishes this BVAR density reading from the market-implied path
# (policy_rate_market.R) and the future reaction-function reading, which share this
# table so the app reads all policy-rate forecasts uniformly (SPEC A2: three
# readings side by side).
forecast_tbl <- draws_long |>
  dplyr::group_by(horizon) |>
  dplyr::reframe(quantile = QUANTILES,
                 value    = stats::quantile(rate, QUANTILES)) |>
  dplyr::mutate(origin_date = origin_date,
                forecast_date = origin_date %m+% months(horizon),
                source = "bvar",
                model_version = MODEL_VERSION, computed_at = now) |>
  dplyr::select(origin_date, horizon, forecast_date, source, quantile, value,
                model_version, computed_at)

# v1 of this table had no `source` column; drop it once so it recreates with the
# current schema (the new PK includes source).
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
db_upsert(con, "forecast_policy_rate", forecast_tbl,
          conflict_cols = c("origin_date", "horizon", "source", "quantile"))

# bvar_policy_draws — full policy-rate draw x horizon for this origin vintage. The
# scenario engine re-weights/filters these without re-fitting. Accretes by origin.
draws_tbl <- draws_long |>
  dplyr::transmute(origin_date = origin_date,
                   horizon = as.integer(horizon),
                   draw = as.integer(draw),
                   rate,
                   model_version = MODEL_VERSION, computed_at = now)

db_ensure_table(con, "bvar_policy_draws",
                cols = c(origin_date = "DATE", horizon = "INTEGER",
                         draw = "INTEGER", rate = "DOUBLE PRECISION",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("origin_date", "horizon", "draw"))
db_upsert(con, "bvar_policy_draws", draws_tbl,
          conflict_cols = c("origin_date", "horizon", "draw"))

# 6.0.0 WRITE — the OTHER five variables ----
# The VAR is a joint system: predict() already returned a density for every
# modelled variable, and until now four of the six were computed and discarded.
# Publishing them costs nothing beyond this loop — no extra fit, no extra draws —
# and an inflation density forecast is the single most-wanted number on the site.
#
# These go to their OWN table rather than into forecast_policy_rate, which is the
# documented "three readings of the policy rate" contract (CLAUDE.md): its
# `source` column means reading-METHOD, and overloading it with quantity would
# leave a table dense in one cell and empty in ten. The policy rate deliberately
# appears in both; the two must agree exactly, which is a free cross-check.
#
# Units differ per variable (%, z-score, % of potential, % log change), so no unit
# is stored here — the app resolves it from its label dictionary.
macro_tbl <- purrr::imap_dfr(
  stats::setNames(seq_along(model_vars), model_vars),
  function(v_index, v_name) {
    bvar_draws_long(pred$fcast, v_index, HORIZON) |>
      bvar_bands(origin_date, QUANTILES) |>
      dplyr::mutate(variable = v_name)
  }) |>
  dplyr::mutate(source = "bvar",
                model_version = MODEL_VERSION, computed_at = now) |>
  dplyr::select(origin_date, horizon, forecast_date, variable, source, quantile,
                value, model_version, computed_at)

db_ensure_table(con, "forecast_macro",
                cols = c(origin_date = "DATE", horizon = "INTEGER",
                         forecast_date = "DATE", variable = "TEXT",
                         source = "TEXT", quantile = "DOUBLE PRECISION",
                         value = "DOUBLE PRECISION", model_version = "TEXT",
                         computed_at = "TIMESTAMPTZ"),
                pk = c("origin_date", "horizon", "variable", "quantile"))
db_upsert(con, "forecast_macro", macro_tbl,
          conflict_cols = c("origin_date", "horizon", "variable", "quantile"))
