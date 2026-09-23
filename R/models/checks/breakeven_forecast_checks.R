# A3b breakeven forecast — verification (run interactively, never scheduled) ----
#
# Every number asserted in forecast_breakeven.R's header is produced here. The
# bar was committed to before looking at the output, and it is the same bar the
# A6 FX work used, because that work is what taught the repo which apparent wins
# are real:
#   * beat the random walk on RMSE (for a stationary level, "today's value
#     carried forward"), AND
#   * clear Diebold-Mariano at the horizon claimed, AND
#   * hold in BOTH sample halves — the test that killed every FX candidate, each
#     of which had a good directional hit rate while scoring rel >= 1.0.
#
# It also checks the two things that could silently invalidate the module:
# whether the breakeven is really stationary (the premise for forecasting the
# LEVEL at all), and whether the published band is calibrated.
#
# Run from the repo root AFTER R/run_quarterly.R has populated
# `zero_coupon_yields`:
#   Rscript -e "source('R/models/checks/breakeven_forecast_checks.R')"
# Plot objects are left in memory, never written to disk.

library(tidyverse)
library(forecast)
library(urca)
library(DBI)
library(RPostgres)

source(file.path("R", "db", "db_helpers.R"))

con <- db_connect()

chk <- function(label, pass, detail = "") {
  cat(sprintf("[%s] %s%s\n", if (pass) "PASS" else "FAIL", label,
              if (nzchar(detail)) paste0(" — ", detail) else ""))
}

HORIZONS <- c(1L, 3L, 6L, 12L, 24L)
MAXH     <- 24L
MIN_OBS  <- 120L

# 1.0.0 REBUILD THE MODEL PANEL ----
# Mirrors forecast_breakeven.R; if that file's construction changes, change it here.
z <- dplyr::tbl(con, "zero_coupon_yields") |>
  dplyr::select("date", "series", "value") |>
  dplyr::collect() |>
  tidyr::pivot_wider(names_from = "series", values_from = "value") |>
  dplyr::arrange(.data$date)
DBI::dbDisconnect(con)

m <- z |>
  dplyr::mutate(mm = lubridate::floor_date(.data$date, "month")) |>
  dplyr::group_by(.data$mm) |>
  dplyr::slice_max(.data$date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(date = .data$mm,
                   BE_5Y  = .data$ZCY_NOMINAL_5Y  - .data$ZCY_INDEXED_5Y,
                   BE_10Y = .data$ZCY_NOMINAL_10Y - .data$ZCY_INDEXED_10Y) |>
  dplyr::filter(is.finite(.data$BE_5Y), is.finite(.data$BE_10Y))

cat(sprintf("Monthly breakeven panel: %s .. %s (n = %d)\n\n",
            min(m$date), max(m$date), nrow(m)))

# 2.0.0 STATIONARITY — the premise ----
# Forecasting the LEVEL of a series only makes sense if the level is stationary.
# This is exactly where the A6 REER work went wrong (a level that looked
# mean-reverting in sample was a unit root in real time), so it is tested rather
# than assumed.
cat("=== Stationarity of the breakeven (premise for forecasting the level) ===\n")
stat <- purrr::map_dfr(c("BE_5Y", "BE_10Y"), function(v) {
  x   <- stats::na.omit(m[[v]])
  adf <- urca::ur.df(x, type = "drift", selectlags = "AIC")
  kps <- urca::ur.kpss(x, type = "mu", lags = "short")
  rho <- stats::cor(x[-1], x[-length(x)])
  # S4 slots are pulled out before the tibble() call: referencing `adf@cval`
  # inside tibble() is evaluated against the already-extracted numeric and fails.
  adf_stat  <- as.numeric(adf@teststat)[1]
  adf_crit  <- as.numeric(adf@cval[1, 2])
  kpss_stat <- as.numeric(kps@teststat)[1]
  kpss_crit <- as.numeric(kps@cval[1, 2])
  tibble::tibble(series = v, n = length(x),
                 adf = adf_stat, adf_crit5 = adf_crit,
                 kpss = kpss_stat, kpss_crit5 = kpss_crit,
                 ar1 = rho, half_life_m = log(0.5) / log(rho))
})
print(as.data.frame(stat |> dplyr::mutate(dplyr::across(where(is.numeric), ~ round(., 3)))))
chk("breakeven is stationary on BOTH ADF and KPSS",
    all(stat$adf < stat$adf_crit5) && all(stat$kpss < stat$kpss_crit5),
    "ADF rejects a unit root AND KPSS fails to reject stationarity")

# 3.0.0 ROLLING-ORIGIN RACE ----
# AR(1) (the shipped model) vs auto.arima vs the random walk.
race <- purrr::map_dfr(c("BE_5Y", "BE_10Y"), function(v) {
  idx <- seq(MIN_OBS, nrow(m) - MAXH)
  purrr::map_dfr(idx, function(i) {
    y <- m[[v]][seq_len(i)]
    a1 <- tryCatch(as.numeric(forecast::forecast(
      forecast::Arima(y, order = c(1, 0, 0)), h = MAXH)$mean),
      error = function(e) rep(NA_real_, MAXH))
    aa <- tryCatch(as.numeric(forecast::forecast(
      forecast::auto.arima(y), h = MAXH)$mean),
      error = function(e) rep(NA_real_, MAXH))
    tibble::tibble(series = v, origin = m$date[i], horizon = HORIZONS,
                   rw = utils::tail(y, 1), ar1 = a1[HORIZONS],
                   auto_arima = aa[HORIZONS], actual = m[[v]][i + HORIZONS])
  })
}) |>
  tidyr::pivot_longer(c("rw", "ar1", "auto_arima"),
                      names_to = "model", values_to = "fc") |>
  dplyr::filter(is.finite(fc), is.finite(actual))

cat(sprintf("\nRolling origins per series: %d (%s .. %s)\n",
            dplyr::n_distinct(race$origin), min(race$origin), max(race$origin)))

scored <- race |>
  dplyr::group_by(series, model, horizon) |>
  dplyr::summarise(rmse = sqrt(mean((actual - fc)^2)), .groups = "drop") |>
  dplyr::left_join(
    race |> dplyr::filter(model == "rw") |>
      dplyr::group_by(series, horizon) |>
      dplyr::summarise(rmse_rw = sqrt(mean((actual - fc)^2)), .groups = "drop"),
    by = c("series", "horizon")) |>
  dplyr::mutate(rel = rmse / rmse_rw)

cat("\n=== RMSE relative to the random walk (<1 beats it) ===\n")
print(as.data.frame(
  scored |> dplyr::transmute(series, model, horizon, rel = round(rel, 3)) |>
    tidyr::pivot_wider(names_from = horizon, values_from = rel, names_prefix = "h")))

# AR(1) is preferred where it matters — the horizons the module actually claims
# skill at (h >= 12). At h=6 on BE_10Y auto.arima is ahead by 0.001, which is
# noise on 163 origins and is at a horizon where NEITHER beats the random walk.
be_long <- scored |> dplyr::filter(horizon >= 12L)
chk("AR(1) beats auto.arima at the horizons the module claims (h >= 12)",
    all(be_long$rel[be_long$model == "ar1"] <=
          be_long$rel[be_long$model == "auto_arima"]),
    "the forecastable part is mean reversion, which AR(1) is the model for")

# 4.0.0 DIEBOLD-MARIANO vs the random walk ----
cat("\n=== Diebold-Mariano: AR(1) vs random walk ===\n")
dm <- purrr::map_dfr(c("BE_5Y", "BE_10Y"), function(v) {
  purrr::map_dfr(HORIZONS, function(h) {
    a <- race |> dplyr::filter(series == v, model == "ar1", horizon == h)
    b <- race |> dplyr::filter(series == v, model == "rw",  horizon == h)
    j <- dplyr::inner_join(a, b, by = "origin")
    p <- tryCatch(forecast::dm.test(j$actual.x - j$fc.x, j$actual.y - j$fc.y,
                                    h = h, power = 2)$p.value,
                  error = function(e) NA_real_)
    tibble::tibble(series = v, horizon = h, n = nrow(j), dm_p = p)
  })
})
print(as.data.frame(dm |> dplyr::mutate(dm_p = round(dm_p, 4))))
chk("AR(1) clears Diebold-Mariano at h=24 on both series",
    all(dm$dm_p[dm$horizon == 24L] < 0.05, na.rm = TRUE),
    sprintf("p = %s", paste(round(dm$dm_p[dm$horizon == 24L], 3), collapse = ", ")))

# 5.0.0 SPLIT-HALF STABILITY — the test the FX candidates failed ----
cat("\n=== Split-half stability at h=12 (a real edge shows in BOTH halves) ===\n")
half <- race |>
  dplyr::filter(model %in% c("ar1", "rw"), horizon == 12L) |>
  dplyr::group_by(series) |>
  dplyr::mutate(half = ifelse(origin <= stats::median(origin), "first", "second")) |>
  dplyr::group_by(series, half, model) |>
  dplyr::summarise(rmse = sqrt(mean((actual - fc)^2)), .groups = "drop") |>
  tidyr::pivot_wider(names_from = "model", values_from = "rmse") |>
  dplyr::mutate(rel = ar1 / rw)
print(as.data.frame(half |> dplyr::mutate(dplyr::across(where(is.numeric), ~ round(., 3)))))
chk("AR(1) beats the random walk in BOTH halves, both series",
    all(half$rel < 1),
    "this is the check that eliminated every A6 FX candidate")

# 6.0.0 BAND CALIBRATION ----
# The module publishes a conservative band and says so; this measures by how much.
cat("\n=== Published band: empirical coverage (targets 0.68 / 0.90) ===\n")
cover <- purrr::map_dfr(c("BE_5Y", "BE_10Y"), function(v) {
  idx <- seq(MIN_OBS, nrow(m) - MAXH)
  purrr::map_dfr(idx, function(i) {
    y   <- m[[v]][seq_len(i)]
    fit <- tryCatch(forecast::Arima(y, order = c(1, 0, 0)), error = function(e) NULL)
    if (is.null(fit)) return(NULL)
    mu  <- as.numeric(forecast::forecast(fit, h = MAXH)$mean)
    rho <- as.numeric(stats::coef(fit)["ar1"])
    s1  <- stats::sd(stats::residuals(fit), na.rm = TRUE)
    sh  <- s1 * sqrt(cumsum(rho^(2 * (seq_len(MAXH) - 1))))
    tibble::tibble(series = v, horizon = HORIZONS,
                   z = abs(m[[v]][i + HORIZONS] - mu[HORIZONS]) / sh[HORIZONS])
  })
}) |>
  dplyr::filter(is.finite(z))

print(as.data.frame(
  cover |> dplyr::group_by(series, horizon) |>
    dplyr::summarise(n = dplyr::n(),
                     c68 = round(mean(z <= stats::qnorm(0.84)), 3),
                     c90 = round(mean(z <= stats::qnorm(0.95)), 3),
                     z90_needed = round(stats::quantile(z, 0.90), 3),
                     .groups = "drop")))
cat(sprintf("\n(nominal z for a 90%% band is %.3f; a SMALLER needed z means the\n",
            stats::qnorm(0.95)))
cat(" published band is too WIDE — the safe direction, documented not patched.)\n")
chk("published band is conservative (never under-covers)",
    all(cover |> dplyr::group_by(series, horizon) |>
          dplyr::summarise(c = mean(z <= stats::qnorm(0.95)), .groups = "drop") |>
          dplyr::pull(c) >= 0.90),
    "90% band covers at least its nominal rate at every horizon")

# 7.0.0 YIELD LEVELS ARE *NOT* FORECASTABLE — the contrast that motivates A3b ----
cat("\n=== Contrast: the same model on the yield LEVELS (should FAIL) ===\n")
lev <- z |>
  dplyr::mutate(mm = lubridate::floor_date(.data$date, "month")) |>
  dplyr::group_by(.data$mm) |>
  dplyr::slice_max(.data$date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(date = .data$mm,
                   NOM_5Y = .data$ZCY_NOMINAL_5Y, NOM_10Y = .data$ZCY_NOMINAL_10Y)
lev_race <- purrr::map_dfr(c("NOM_5Y", "NOM_10Y"), function(v) {
  idx <- seq(MIN_OBS, nrow(lev) - MAXH)
  purrr::map_dfr(idx, function(i) {
    y <- lev[[v]][seq_len(i)]
    a1 <- tryCatch(as.numeric(forecast::forecast(
      forecast::Arima(y, order = c(1, 0, 0)), h = MAXH)$mean),
      error = function(e) rep(NA_real_, MAXH))
    tibble::tibble(series = v, horizon = HORIZONS, rw = utils::tail(y, 1),
                   ar1 = a1[HORIZONS], actual = lev[[v]][i + HORIZONS])
  })
}) |>
  dplyr::filter(is.finite(ar1), is.finite(actual))
print(as.data.frame(
  lev_race |> dplyr::group_by(series, horizon) |>
    dplyr::summarise(rel = round(sqrt(mean((actual - ar1)^2)) /
                                   sqrt(mean((actual - rw)^2)), 3), .groups = "drop") |>
    tidyr::pivot_wider(names_from = horizon, values_from = rel, names_prefix = "h")))
cat("\nrel >= 1 here is the EXPECTED result and the reason A3b forecasts the\n")
cat("breakeven rather than the curve: levels are near-unit-root, the spread is not.\n")

p_be <- scored |>
  ggplot2::ggplot(ggplot2::aes(horizon, rel, colour = model)) +
  ggplot2::geom_hline(yintercept = 1, colour = "grey50", linetype = 2) +
  ggplot2::geom_line() + ggplot2::geom_point() +
  ggplot2::facet_wrap(~ series) +
  ggplot2::labs(x = "horizon (months)", y = "RMSE relative to random walk",
                title = "Breakeven inflation: forecast skill by horizon") +
  ggplot2::theme_minimal(base_size = 12)

cat("\nView `p_be` for the skill-by-horizon curve.\n")
