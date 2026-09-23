# A2 — Policy-rate path (BVAR density forecast) ----
#
# A Bayesian VAR produces a DENSITY forecast of the Central Bank policy rate (a
# fan, not a point), conditioned on the macro state (SPEC A2). The companion
# market-implied reading (policy_rate_market.R) is the responsive near-term path;
# this BVAR is the model-based density + persisted posterior draws (the scenario-
# engine foundation). The reaction-function (ordered-probit) reading is still to
# come. The v1 note that this BVAR "does NOT anticipate announced policy turns"
# no longer holds unqualified: since v2 carries the REIBOR spreads (see below) it
# inherits part of the market's turn-pricing, which is most of where its accuracy
# gain comes from. It is still a level VAR on a ~0.93-AR rate and still slower
# than the market reading, so both remain written to forecast_policy_rate
# (distinguished by `source`) for the app to show side by side.
#
# Sourced by run_models.R (provides `con`; tidyverse + BVAR attached; DB helpers
# sourced). Runs after A1 (heat_index.R) — it reads the heat-index factor as an
# input, so model files sort/source alphabetically with heat_index before
# policy_rate. Target tables (upsert):
#   forecast_policy_rate  (origin_date, horizon, quantile)  — central path + bands
#   bvar_policy_draws     (origin_date, horizon, draw)       — full policy-rate draws
#   forecast_macro        (origin_date, horizon, variable, source, quantile) — the SAME
#     fit's density for every modelled variable (inflation, heat, the two REIBOR
#     spreads, ECB), not just the policy rate. The VAR is a joint system, so
#     these come free. NOTE the v2 variable set changed which rows appear here:
#     `gap` and `d_ltwi` are gone, `sp_r6`/`sp_r3` are new. See labels.R.
#
# Variable set (v2): policy rate, CPI YoY inflation, A1 heat-index factor, the
# REIBOR 6M and 3M spreads over the policy rate, and the ECB deposit rate
# (external anchor). Monthly frequency; daily series taken at MONTH-END.
#
# WHY THE MONEY-MARKET SPREADS (the v1 -> v2 change). v1 used the output gap and
# the ISK log change in place of the two REIBOR spreads. Racing twelve
# specifications on 60 rolling origins (R/models/checks/policy_rate_spec_race.R)
# put this set ahead of v1's by 13% / 31% / 33% / 21% RMSE at h = 1/3/6/12, and
# the win is broad rather than one episode: it beats v1 at 66-75% of individual
# origins and in five of six origin years. REIBOR was already in the repo as the
# separate point path in policy_rate_market.R, which exists precisely because it
# "prices turns the BVAR cannot anticipate" — putting the spreads INSIDE the
# system is what lets the density inherit that signal instead of leaving it in a
# parallel series. Entered as SPREADS over the policy rate, not levels, so the
# variable carries the expected change rather than restating the current level.
#
# The output gap was dropped with little loss: quarterly, interpolated to monthly
# and carried forward, it adds ~0.001 R-squared to the 6-month policy-rate change
# (see section 6 of the race script) while consuming a column of a k=6 system.
#
# NOTE ON WHAT DID *NOT* WORK. A better inflation forecast does not help here.
# ARIMA beats this BVAR on inflation by ~31% (inflation_forecast_race.R), but
# conditioning the system on that path is not a win. MEASURED (61 rolling origins,
# 2020-09..2025-09, conditional_inflation_check.R): fixing `infl` to the ARIMA path
# and drawing the other five from their conditional distribution moves policy-rate
# RMSE by -1.3%/-8.9%/-5.3%/+10.9% at h=1/3/6/12 — it helps in the middle and hurts
# a year out, and NO horizon is significant (Diebold-Mariano p = 0.20-0.60).
# (An earlier version of this comment claimed "under 1%" at every horizon; that was
# asserted, never measured, and is wrong at h=3. The conclusion is unchanged.)
# Predicting the 6-month policy-rate CHANGE,
# `heat` adds +0.22 R-squared and the ECB differential +0.18, while `infl` adds
# -0.03: the forecastable part of the policy rate is the stance and the
# money-market curve, not the inflation print. Do not re-litigate this without
# re-running the race.

MODEL_VERSION <- "A2-v2"
BVAR_LAGS     <- 2L
N_DRAW        <- 6000L
N_BURN        <- 2000L
HORIZON       <- 18L            # months ahead
QUANTILES     <- c(0.05, 0.16, 0.50, 0.84, 0.95)   # fixed band definition
SAMPLE_START  <- as.Date("2009-01-01")             # post-redenomination policy regime

# 1.0.0 PULL ----
# Each daily series taken at month-end (the value prevailing at month close). CPI
# YoY and the heat factor are already monthly.
# month_end_series / monthly_series live in R/models/helpers_bvar.R — the same
# reductions are needed by the FX module, so they are shared rather than repeated.
policy <- month_end_series(con, "rates_policy", series = NULL,
                           out_col = "policy_rate", value_col = "policy_rate")
ecb    <- month_end_series(con, "rates_external", "ECB_DEPO", "ecb")

infl <- monthly_series(con, "cpi", "CPI_change_A", "infl")
heat <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |>
  dplyr::select(date, index) |>
  dplyr::collect() |>
  dplyr::transmute(date, heat = index)

# The money-market curve at month end, one column per tenor. The same month-end
# reduction policy_rate_market.R applies to the same table — that module reads
# the curve to invert a point path; here the spreads enter the system directly.
reibor <- dplyr::tbl(con, "rates_reibor") |>
  dplyr::filter(tenor %in% c("3M", "6M")) |>
  dplyr::select(date, tenor, reibor) |>
  dplyr::collect() |>
  dplyr::mutate(m = lubridate::floor_date(date, "month")) |>
  dplyr::group_by(m, tenor) |>
  dplyr::slice_max(date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(date = m, tenor, reibor) |>
  tidyr::pivot_wider(names_from = tenor, values_from = reibor,
                     names_prefix = "reibor")

# 2.0.0 ASSEMBLE + TRANSFORM ----
# Common monthly spine from SAMPLE_START to the latest policy month. Rates and
# inflation enter in levels (%), the heat factor as its z-scale, and the REIBOR
# tenors as SPREADS over the policy rate (see the header). Every input is now
# monthly or daily, so nothing is interpolated and the forecast origin is simply
# the latest month with all six observed.
spine <- tibble::tibble(
  date = seq(SAMPLE_START, max(policy$date), by = "month")
)

dat <- spine |>
  dplyr::left_join(policy, by = "date") |>
  dplyr::left_join(infl,   by = "date") |>
  dplyr::left_join(heat,   by = "date") |>
  dplyr::left_join(ecb,    by = "date") |>
  dplyr::left_join(reibor, by = "date") |>
  dplyr::arrange(date) |>
  dplyr::mutate(sp_r6 = .data$reibor6M - .data$policy_rate,
                sp_r3 = .data$reibor3M - .data$policy_rate) |>
  dplyr::select(date, policy_rate, infl, heat, sp_r6, sp_r3, ecb)

# Estimation sample: rows where every modelled variable is present. policy_rate is
# column 1 so it stays the forecast target.
dat_fit <- dplyr::filter(dat, dplyr::if_all(-date, ~ !is.na(.)))
origin_date <- max(dat_fit$date)

# 3.0.0 FIT ----
Y <- as.matrix(dplyr::select(dat_fit, -date))
# Column order is load-bearing: policy_rate is column 1 so it stays the forecast
# target sliced at 4.0.0, and these names index the draws array's 3rd dimension.
model_vars <- colnames(Y)
fit <- BVAR::bvar(Y, lags = BVAR_LAGS, n_draw = N_DRAW, n_burn = N_BURN,
                  verbose = FALSE)

# 4.0.0 FORECAST ----
# Simulated from the posterior rather than via BVAR::predict(). v1 used
# predict() on the grounds that a persistent level forecast is dominated by the
# VAR dynamics and its bands "check out"; that was asserted, never measured, and
# it is wrong. Backtesting the published bands against realised outcomes over 59
# rolling origins (the PI-coverage section of policy_rate_spec_race.R) gives
# predict() a 90% band that actually contains the outcome 52%/63%/59%/56% of the
# time at h = 1/3/6/12 — every horizon rejects the nominal level at p < 1e-5, and
# the failure is TOO NARROW, the opposite direction to the over-dispersion
# helpers_bvar.R documents for the one-step FX case. bvar_simulate() over the
# same origins gives 88%/92%/90%/83%, none of which is rejected at the 90% level.
#
# So the band source is now the same in A2 and A6. The 68% band remains too
# narrow at h = 12 (46% against a nominal 68%, p < 0.001): the fan understates
# uncertainty a year out, which is noted on the methodology page rather than
# patched with a fudge factor.
#
# Returns draws x horizon x variable, the same shape predict()$fcast had.
fcast <- bvar_simulate(fit, Y, lags = BVAR_LAGS, horizon = HORIZON)

draws_long <- bvar_draws_long(fcast, 1L, HORIZON) |>
  dplyr::rename(rate = "value")

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
    bvar_draws_long(fcast, v_index, HORIZON) |>
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
                pk = c("origin_date", "horizon", "variable", "source", "quantile"))

# Clear any row at THIS origin for a variable this fit no longer models before
# upserting. The PK is (origin_date, horizon, variable, source, quantile) — it
# carries `source` because inflation_arima.R publishes a SECOND `infl` path at
# the same origin (source = "arima") and without it the two would collide and
# silently overwrite each other. A variable dropped from the set — `gap` and
# `d_ltwi` at the v1 -> v2 change — is never overwritten by the upsert and would
# linger at the current origin as a stale forecast the app would show beside the
# fresh ones. This deletes only the
# current origin's orphans: earlier vintages keep their full v1 variable set,
# which is the point of storing by origin.
DBI::dbExecute(con, paste0(
  "DELETE FROM forecast_macro WHERE origin_date = $1 AND source = 'bvar'",
  " AND variable NOT IN (",
  paste(DBI::dbQuoteString(con, model_vars), collapse = ", "), ")"),
  params = list(origin_date))

db_upsert(con, "forecast_macro", macro_tbl,
          conflict_cols = c("origin_date", "horizon", "variable", "source",
                            "quantile"))
