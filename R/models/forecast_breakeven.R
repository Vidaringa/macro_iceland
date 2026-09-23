# A3b — Breakeven inflation forecast (AR(1) density) ----
#
# Forecasts the 5y and 10y breakeven inflation rate (nominal minus indexed
# zero-coupon yield) 24 months ahead, as a density.
#
# WHY THIS IS THE ONE TERM-STRUCTURE OBJECT WORTH FORECASTING. The yield LEVELS
# are not forecastable: over the same 163 rolling origins a random walk beats an
# AR(1) on the 5y and 10y nominal yield at every horizon (rel 1.08-1.55; section
# 7 of the check script). That is the standard term-structure result and this data
# reproduces it. The BREAKEVEN is different because it is stationary
# where the levels are not — ADF -5.06/-5.29 and KPSS 0.186/0.193 for 5y/10y, the
# uncommon case where both tests agree — with a monthly AR(1) half-life of 5.4
# (5y) and 3.7 (10y) months against 11-20 months for the yield levels.
#
# MEASURED SKILL (163 rolling origins, 2011-01 .. 2024-06, RMSE relative to a
# random walk; see checks/breakeven_forecast_checks.R):
#            h=1    h=3    h=6   h=12   h=24
#   BE_5Y   1.013  0.982  0.946  0.863  0.725
#   BE_10Y  1.083  1.088  1.055  0.915  0.682
# So the model only earns its place from h=12 out. It is published from h=1
# anyway, because a fan that starts at the origin is how every other forecast on
# the site reads and truncating it would be more confusing than the honest note
# that the short end is no better than "today's breakeven, carried forward".
# Diebold-Mariano against the random walk at h=24: p=0.048 (5y), p=0.014 (10y).
# The win is stable across sample halves — both halves beat the RW at h=12 —
# which is the test that killed the A6 FX candidates.
#
# AR(1) NOT auto.arima. Racing them, AR(1) wins at every horizon this module
# claims skill at (h = 12: 0.863/0.915 vs 0.925/0.919; h = 24: 0.725/0.682 vs
# 0.796/0.789 for 5y/10y). The one exception is BE_10Y at h=6, where auto.arima
# leads by 0.001 — noise on 163 origins, at a horizon where neither beats the
# random walk. auto.arima chases short-run structure that does not survive out of
# sample; the forecastable part here is just mean reversion, which AR(1) is
# exactly the model for.
#
# BANDS ARE CONSERVATIVE, AND KNOWN TO BE. Measured coverage of the nominal 68%
# band is 0.77-0.96 and of the nominal 90% band 0.97-1.00 — the fan is roughly
# 30% too WIDE (the z that would calibrate the 90% band is 0.81-1.26 against a
# nominal 1.645). The cause is that the AR(1) error-accumulation formula adds
# each step's variance without crediting the mean reversion that pulls the error
# back. This is documented rather than patched with a fudge factor, exactly as A2
# documents its too-narrow 68% band at h=12 — a hand-tuned band would not survive
# the next vintage. Erring wide is the safe direction for a published density.
#
# Sourced by run_models.R (provides `con`; tidyverse + forecast attached; DB
# helpers sourced). The filename sorts after yield_curve.R, which does not matter
# here — this module reads `zero_coupon_yields` (the Hagvísar ingest), not A3's
# output — but it keeps the curve files adjacent. Target table:
#   forecast_breakeven (origin_date, horizon, series, quantile)

MODEL_VERSION <- "A3b-be-v1"
BE_HORIZON    <- 24L
BE_QUANTILES  <- c(0.05, 0.16, 0.50, 0.84, 0.95)
BE_MIN_OBS    <- 120L   # 10y of monthly history before a fit is attempted

# 1.0.0 PULL ----
# Month-end reduction: the breakeven prevailing at month close, matching the
# convention every other monthly model in the repo uses for a daily price.
be_daily <- dplyr::tbl(con, "zero_coupon_yields") |>
  dplyr::select("date", "series", "value") |>
  dplyr::collect() |>
  tidyr::pivot_wider(names_from = "series", values_from = "value") |>
  dplyr::arrange(.data$date)

be_monthly <- be_daily |>
  dplyr::mutate(m = lubridate::floor_date(.data$date, "month")) |>
  dplyr::group_by(.data$m) |>
  dplyr::slice_max(.data$date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(
    date  = .data$m,
    BE_5Y  = .data$ZCY_NOMINAL_5Y  - .data$ZCY_INDEXED_5Y,
    BE_10Y = .data$ZCY_NOMINAL_10Y - .data$ZCY_INDEXED_10Y)

# 2.0.0 FIT + FORECAST ----
# The origin is the last month for which BOTH series are observed, so the two
# forecasts share one origin and the app can show them on a single axis.
be_fit_dat <- dplyr::filter(be_monthly,
                            is.finite(.data$BE_5Y), is.finite(.data$BE_10Y))
be_origin  <- max(be_fit_dat$date)
be_now     <- Sys.time()

be_forecast <- purrr::map_dfr(c("BE_5Y", "BE_10Y"), function(s) {
  y <- be_fit_dat[[s]]
  if (length(y) < BE_MIN_OBS) return(NULL)
  fit <- tryCatch(forecast::Arima(y, order = c(1, 0, 0)), error = function(e) NULL)
  if (is.null(fit)) return(NULL)

  mu  <- as.numeric(forecast::forecast(fit, h = BE_HORIZON)$mean)
  # h-step error sd for an AR(1): the one-step residual sd accumulated over the
  # horizon with the AR coefficient. Uses the EMPIRICAL residual sd rather than
  # the ML sigma, which makes no measurable difference here but is the more
  # honest scale when the residuals are not exactly Gaussian.
  rho <- as.numeric(stats::coef(fit)["ar1"])
  s1  <- stats::sd(stats::residuals(fit), na.rm = TRUE)
  sh  <- s1 * sqrt(cumsum(rho^(2 * (seq_len(BE_HORIZON) - 1))))

  tidyr::expand_grid(horizon = seq_len(BE_HORIZON), quantile = BE_QUANTILES) |>
    dplyr::mutate(
      series = s,
      value  = mu[.data$horizon] + stats::qnorm(.data$quantile) * sh[.data$horizon])
})

if (nrow(be_forecast) == 0) stop("breakeven forecast produced no rows")

# 3.0.0 WRITE ----
be_out <- be_forecast |>
  dplyr::mutate(
    origin_date   = be_origin,
    forecast_date = lubridate::`%m+%`(be_origin, months(.data$horizon)),
    horizon       = as.integer(.data$horizon),
    source        = "ar1",
    model_version = MODEL_VERSION,
    computed_at   = be_now) |>
  dplyr::select("origin_date", "horizon", "forecast_date", "series", "source",
                "quantile", "value", "model_version", "computed_at")

db_ensure_table(con, "forecast_breakeven",
                cols = c(origin_date = "DATE", horizon = "INTEGER",
                         forecast_date = "DATE", series = "TEXT", source = "TEXT",
                         quantile = "DOUBLE PRECISION", value = "DOUBLE PRECISION",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("origin_date", "horizon", "series", "quantile"))
db_upsert(con, "forecast_breakeven", be_out,
          conflict_cols = c("origin_date", "horizon", "series", "quantile"))
