# A6 — ISK exchange-rate path (BVAR density forecast) ----
#
# A second Bayesian VAR, separate from A2, producing a DENSITY forecast of the
# monthly change in the ISK trade-weighted index.
#
# WHY A SEPARATE MODEL rather than more variables in A2. A VAR's coefficient count
# grows with k^2: going from A2's six variables to a combined ten would take the
# system from 99 to 265 parameters on the same ~211 months, thinning every
# equation. More decisively, the two models want different things. A2 forecasts
# LEVELS (policy rate, inflation) at an origin tied to the heat-index month; this
# model forecasts a LOG DIFFERENCE at its own origin, which can run a month or two
# fresher because the TWI is daily. One model would force one compromise on all of
# it. The shared scaffolding lives in helpers_bvar.R, so a third BVAR is cheap.
#
# WHY THE LOG DIFFERENCE, NOT THE LEVEL. The TWI level has AR(1) ~ 0.97 — a
# near-unit-root. A level VAR on it would be persistence-dominated (the same
# pathology CLAUDE.md documents for A2's policy rate) and an 18-month level
# forecast would amount to "today's TWI, plus a fan that widens like a random
# walk". The monthly log change has AR(1) ~ 0.03, so it is close to white noise:
# whatever skill this model has must come from the OTHER variables, not from the
# exchange rate's own past.
#
# HOW TO READ THE OUTPUT — this matters more here than in A2:
#   * Monthly ISK returns are close to unforecastable in the mean. The honest
#     product is the DENSITY (how wide is the distribution of outcomes), not a
#     directional call. fx_path_backtest.R measures the directional hit rate out
#     of sample; whatever it reports is what the app is allowed to claim.
#   * The ISK is a managed float. The Central Bank intervened in a majority of
#     months over this sample (2015-16 alone: several hundred billion ISK of
#     one-way buying). Any forecast is conditional on the Bank not leaning against
#     the move, and intervention is endogenous — it happens BECAUSE the rate moved.
#
# Sourced by run_models.R (provides `con`; tidyverse + BVAR attached; DB helpers
# and helpers_bvar.R sourced). The filename matters: it must sort AFTER
# heat_index.R, because this model reads the A1 factor as an input and
# run_models.R sources model files in sorted order. Target tables:
#   forecast_fx    (origin_date, horizon, series, quantile) — bands
#   bvar_fx_draws  (origin_date, horizon, series, draw)     — full draws

MODEL_VERSION <- "A6-fx-v1"
FX_LAGS       <- 2L
FX_N_DRAW     <- 6000L
FX_N_BURN     <- 2000L
FX_HORIZON    <- 18L
FX_QUANTILES  <- c(0.05, 0.16, 0.50, 0.84, 0.95)
FX_SAMPLE_START <- as.Date("2009-01-01")   # post-crisis; see the regime note below

# 1.0.0 PULL ----
fx_twi    <- month_end_series(con, "fx_daily", "TWI", "twi")
fx_policy <- month_end_series(con, "rates_policy", NULL, "policy_rate", "policy_rate")
fx_ecb    <- month_end_series(con, "rates_external", "ECB_DEPO", "ecb")
fx_heat   <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |>
  dplyr::select(date, index) |>
  dplyr::collect() |>
  dplyr::transmute(date, heat = index)
fx_ca_q <- dplyr::tbl(con, "current_account") |>
  dplyr::filter(series == "CURRENT_ACCOUNT") |>
  dplyr::select(date, value) |>
  dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), ca = value)
fx_tot_q <- dplyr::tbl(con, "terms_of_trade") |>
  dplyr::filter(series == "TERMS_OF_TRADE_GS") |>
  dplyr::select(date, value) |>
  dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), tot = value)

# 2.0.0 ASSEMBLE + TRANSFORM ----
# Five variables, not ten. At k=5 the VAR(2) carries 70 parameters on ~211
# months; each further variable costs more in parameters than it plausibly adds
# in signal on a sample this short.
#
# The current account and terms of trade are quarterly and are interpolated to
# monthly. Note what that does: it turns ~70 real quarterly observations into 211
# monthly ones, so the posterior on those coefficients is more confident than the
# information content warrants. It is accepted here (the alternative is a
# quarterly model with a third of the observations) but it is a reason to read
# those two coefficients loosely.
fx_spine <- tibble::tibble(
  date = seq(FX_SAMPLE_START, max(fx_twi$date), by = "month")
)
fx_ca_m  <- quarterly_to_monthly(fx_spine, fx_ca_q, "ca")
fx_tot_m <- quarterly_to_monthly(fx_spine, fx_tot_q, "tot")

fx_dat <- fx_spine |>
  dplyr::left_join(fx_twi, by = "date") |>
  dplyr::left_join(fx_policy, by = "date") |>
  dplyr::left_join(fx_ecb, by = "date") |>
  dplyr::left_join(fx_heat, by = "date") |>
  dplyr::left_join(fx_ca_m, by = "date") |>
  dplyr::left_join(fx_tot_m, by = "date") |>
  dplyr::arrange(.data$date) |>
  dplyr::mutate(
    # The forecast target: monthly % log change. Positive = the index rose =
    # a WEAKER krona (the TWI is quoted so that up is depreciation).
    d_ltwi = 100 * (log(.data$twi) - log(dplyr::lag(.data$twi))),
    # Carry differential against the euro area — the textbook FX driver and the
    # reason a policy decision should move the rate at all.
    rdiff  = .data$policy_rate - .data$ecb,
    # Terms of trade as a growth rate, so it enters stationary like the target.
    d_ltot = 100 * (log(.data$tot) - log(dplyr::lag(.data$tot))),
    # Current account, scaled to tens of ISK bn so it sits on the same order of
    # magnitude as the other variables. The Minnesota prior is scale-sensitive:
    # left in raw m.kr. this series has sd ~44 against ~2 for everything else,
    # which distorts the shrinkage applied across equations.
    ca_scaled = .data$ca / 10000
  ) |>
  dplyr::select("date", "d_ltwi", "rdiff", "ca_scaled", "d_ltot", "heat")

# d_ltwi is column 1 so it stays the forecast target when the draws are sliced.
fx_fit_dat <- dplyr::filter(fx_dat, dplyr::if_all(-"date", ~ !is.na(.)))
fx_origin  <- max(fx_fit_dat$date)

# 3.0.0 FIT ----
fx_Y <- as.matrix(dplyr::select(fx_fit_dat, -"date"))
fx_vars <- colnames(fx_Y)
fx_bvar <- BVAR::bvar(fx_Y, lags = FX_LAGS, n_draw = FX_N_DRAW,
                      n_burn = FX_N_BURN, verbose = FALSE)

# 4.0.0 FORECAST ----
# Simulated from the posterior rather than via BVAR::predict(), which is
# over-dispersed by ~2.4x on this package version (see bvar_simulate() in
# helpers_bvar.R for the evidence). For a near-white-noise target the forecast
# IS essentially the error distribution, so that factor is the difference between
# a +/-4% monthly band and a meaningless +/-10% one.
fx_fcast <- bvar_simulate(fx_bvar, fx_Y, FX_LAGS, FX_HORIZON)
fx_draws_long <- bvar_draws_long(fx_fcast, 1L, FX_HORIZON)   # d_ltwi

# 5.0.0 WRITE ----
fx_now <- Sys.time()

fx_forecast_tbl <- fx_draws_long |>
  bvar_bands(fx_origin, FX_QUANTILES) |>
  dplyr::mutate(series = "TWI", source = "bvar",
                model_version = MODEL_VERSION, computed_at = fx_now) |>
  dplyr::select("origin_date", "horizon", "forecast_date", "series", "source",
                "quantile", "value", "model_version", "computed_at")

db_ensure_table(con, "forecast_fx",
                cols = c(origin_date = "DATE", horizon = "INTEGER",
                         forecast_date = "DATE", series = "TEXT", source = "TEXT",
                         quantile = "DOUBLE PRECISION", value = "DOUBLE PRECISION",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("origin_date", "horizon", "series", "quantile"))
db_upsert(con, "forecast_fx", fx_forecast_tbl,
          conflict_cols = c("origin_date", "horizon", "series", "quantile"))

fx_draws_tbl <- fx_draws_long |>
  dplyr::transmute(origin_date = fx_origin,
                   horizon = as.integer(.data$horizon),
                   series = "TWI",
                   draw = as.integer(.data$draw),
                   value = .data$value,
                   model_version = MODEL_VERSION, computed_at = fx_now)

db_ensure_table(con, "bvar_fx_draws",
                cols = c(origin_date = "DATE", horizon = "INTEGER",
                         series = "TEXT", draw = "INTEGER",
                         value = "DOUBLE PRECISION",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("origin_date", "horizon", "series", "draw"))
db_upsert(con, "bvar_fx_draws", fx_draws_tbl,
          conflict_cols = c("origin_date", "horizon", "series", "draw"))
