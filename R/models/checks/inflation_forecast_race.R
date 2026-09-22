# A2 inflation forecast — model race (run interactively, never scheduled) ----
#
# The question this answers: is the A2 BVAR's inflation forecast — which the app
# publishes from `forecast_macro` — worth publishing at all, or would a plain
# univariate model do better?
#
# The rule is committed to in advance, before looking at the output:
#   * a model is only preferred over the incumbent BVAR if it wins on RMSE AND
#     the Diebold-Mariano test clears p < 0.05 at that horizon;
#   * the random walk (last observed YoY rate carried forward) is the floor. A
#     model that cannot beat it has no claim to be on the site at all.
# Pre-committing is what stops this becoming a search across specifications for
# one that happens to look good on this sample.
#
# Method: rolling origin, 72 monthly origins (2019-09 .. 2025-08, so the window
# spans COVID and the 2022 inflation surge). At each origin every model is re-fit
# on data available AT THAT TIME only, then forecast 1/3/6/12 months ahead and
# scored against realised YoY CPI inflation.
#
# NOTE ON THE SAMPLES. The univariate models are fit on the DEEP CPI history
# (1989-, 460 months from `cpi.CPI_index`); the BVARs are confined to 2009- like
# A2 itself, because the heat index and the post-redenomination policy regime do
# not go back further. That is not an unfair comparison — it is one of the
# reasons the univariate models win, and section 6 measures how much of the gap
# it accounts for (answer: little; ARIMA on the SHORT sample still beats every
# BVAR).
#
# BVAR::predict() vs bvar_simulate(): the race scores the MEDIAN path, and the
# documented ~2.4x over-dispersion inflates the band, not the centre. Simulating
# here therefore scores A2's central path fairly while staying on one code path.
#
# Run from the repo root AFTER R/run_models.R (it needs `heatindex_level`):
#   Rscript -e "source('R/models/checks/inflation_forecast_race.R')"
# Plot objects are left in memory, never written to disk.

library(tidyverse)
library(forecast)
library(BVAR)
library(DBI)
library(RPostgres)

source(file.path("R", "db", "db_helpers.R"))
source(file.path("R", "models", "helpers_bvar.R"))

con <- db_connect()

chk <- function(label, pass, detail = "") {
  cat(sprintf("[%s] %s%s\n", if (pass) "PASS" else "FAIL", label,
              if (nzchar(detail)) paste0(" — ", detail) else ""))
}

HORIZONS <- c(1L, 3L, 6L, 12L)
MAXH     <- 12L
N_TEST   <- 72L
SAMPLE_START <- as.Date("2009-01-01")   # matches A2

# 1.0.0 PULL ----
# YoY inflation is rebuilt from CPI_index rather than read from CPI_change_A so
# that the deep history and the modelled definition are guaranteed identical.
cpi_idx <- dplyr::tbl(con, "cpi") |>
  dplyr::filter(series == "CPI_index") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), cpi = value) |>
  dplyr::arrange(date)

policy <- month_end_series(con, "rates_policy", NULL, "policy_rate", "policy_rate")
twi    <- month_end_series(con, "fx_daily", "TWI", "twi")
ecb    <- month_end_series(con, "rates_external", "ECB_DEPO", "ecb")
heat   <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |>
  dplyr::select(date, index) |> dplyr::collect() |>
  dplyr::transmute(date, heat = index)
gap_q  <- dplyr::tbl(con, "output_gap") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), gap = value)
DBI::dbDisconnect(con)

infl <- cpi_idx |>
  dplyr::mutate(infl = 100 * (cpi / dplyr::lag(cpi, 12) - 1)) |>
  dplyr::filter(!is.na(infl))

# 2.0.0 ASSEMBLE THE BVAR PANEL ----
# Mirrors policy_rate_path.R exactly; if that file's variable set changes, change
# it here too.
spine <- tibble::tibble(date = seq(SAMPLE_START, max(policy$date), by = "month"))
panel <- spine |>
  dplyr::left_join(dplyr::select(infl, date, infl), by = "date") |>
  dplyr::left_join(policy, by = "date") |>
  dplyr::left_join(heat, by = "date") |>
  dplyr::left_join(quarterly_to_monthly(spine, gap_q, "gap"), by = "date") |>
  dplyr::left_join(ecb, by = "date") |>
  dplyr::left_join(twi, by = "date") |>
  dplyr::arrange(date) |>
  dplyr::mutate(d_ltwi = 100 * (log(twi) - log(dplyr::lag(twi)))) |>
  dplyr::select(date, policy_rate, infl, heat, gap, ecb, d_ltwi) |>
  dplyr::filter(dplyr::if_all(-date, ~ !is.na(.)))

actual_at <- function(dt) {
  unname(stats::setNames(infl$infl, as.character(infl$date))[as.character(dt)])
}

# 3.0.0 ROLLING ORIGIN ----
# Candidate BVAR specifications. V6 is A2's own variable set; the others test
# whether the loss is a variable-set or a lag-length problem rather than
# something inherent to the approach.
V6 <- c("policy_rate", "infl", "heat", "gap", "ecb", "d_ltwi")
V4 <- c("infl", "policy_rate", "heat", "d_ltwi")
V3 <- c("infl", "policy_rate", "heat")
BVAR_SPECS <- list(bvar_a2     = list(v = V6, l = 2L),
                   bvar_p4_l2  = list(v = V4, l = 2L),
                   bvar_p3_l2  = list(v = V3, l = 2L),
                   bvar_a2_l6  = list(v = V6, l = 6L),
                   bvar_a2_l12 = list(v = V6, l = 12L))

origins <- utils::tail(seq_len(nrow(panel) - MAXH), N_TEST)
cat(sprintf("Rolling origins: %s .. %s (n = %d)\n",
            panel$date[min(origins)], panel$date[max(origins)], length(origins)))

race <- purrr::map_dfr(origins, function(i) {
  od <- panel$date[i]

  # Univariate models on the deep YoY history available at this origin.
  y  <- dplyr::filter(infl, date <= od)
  ts_y <- stats::ts(y$infl, frequency = 12,
                    start = c(lubridate::year(min(infl$date)),
                              lubridate::month(min(infl$date))))
  fc <- list(
    rw         = rep(as.numeric(utils::tail(ts_y, 1)), MAXH),
    arima      = tryCatch(as.numeric(forecast(auto.arima(ts_y), h = MAXH)$mean),
                          error = function(e) rep(NA_real_, MAXH)),
    ets        = tryCatch(as.numeric(forecast(ets(ts_y), h = MAXH)$mean),
                          error = function(e) rep(NA_real_, MAXH)),
    stlm_arima = tryCatch(as.numeric(forecast(stlm(ts_y, method = "arima"), h = MAXH)$mean),
                          error = function(e) rep(NA_real_, MAXH)),
    stlm_ets   = tryCatch(as.numeric(forecast(stlm(ts_y, method = "ets"), h = MAXH)$mean),
                          error = function(e) rep(NA_real_, MAXH)),
    theta      = tryCatch(as.numeric(thetaf(ts_y, h = MAXH)$mean),
                          error = function(e) rep(NA_real_, MAXH)),
    nnetar     = tryCatch(as.numeric(forecast(nnetar(ts_y), h = MAXH)$mean),
                          error = function(e) rep(NA_real_, MAXH))
  )

  # BVARs on the 2009- panel. A fit that fails (BVAR's automatic prior setup
  # occasionally cannot handle a near-integrated column) yields NA for that
  # origin rather than killing the run.
  train <- panel[seq_len(i), ]
  for (nm in names(BVAR_SPECS)) {
    sp <- BVAR_SPECS[[nm]]
    fc[[nm]] <- tryCatch({
      Y <- as.matrix(dplyr::select(train, dplyr::all_of(sp$v)))
      fit <- suppressWarnings(BVAR::bvar(Y, lags = sp$l, n_draw = 3000L,
                                         n_burn = 1000L, verbose = FALSE))
      sim <- bvar_simulate(fit, Y, lags = sp$l, horizon = MAXH)
      apply(sim[, , which(sp$v == "infl"), drop = FALSE], 2, stats::median,
            na.rm = TRUE)
    }, error = function(e) rep(NA_real_, MAXH))
  }

  purrr::map_dfr(names(fc), function(m) {
    tibble::tibble(origin = od, model = m, horizon = HORIZONS,
                   forecast = fc[[m]][HORIZONS],
                   actual = actual_at(od %m+% months(HORIZONS)))
  })
}) |>
  dplyr::filter(!is.na(forecast), !is.na(actual))

# 4.0.0 ACCURACY ----
acc <- race |>
  dplyr::group_by(model, horizon) |>
  dplyr::summarise(n = dplyr::n(),
                   rmse = sqrt(mean((actual - forecast)^2)),
                   mae  = mean(abs(actual - forecast)),
                   bias = mean(forecast - actual), .groups = "drop") |>
  dplyr::left_join(race |> dplyr::filter(model == "rw") |>
                     dplyr::group_by(horizon) |>
                     dplyr::summarise(rmse_rw = sqrt(mean((actual - forecast)^2)),
                                      .groups = "drop"),
                   by = "horizon") |>
  dplyr::mutate(rel_rw = rmse / rmse_rw)

for (h in HORIZONS) {
  cat(sprintf("\n=== h = %d months (rel_rw < 1 beats the random walk) ===\n", h))
  print(as.data.frame(
    acc |> dplyr::filter(horizon == h) |> dplyr::arrange(rmse) |>
      dplyr::select(model, n, rmse, rel_rw, mae, bias) |>
      dplyr::mutate(dplyr::across(c(rmse, rel_rw, mae, bias), ~ round(., 3)))))
}

# 5.0.0 DIEBOLD-MARIANO vs THE INCUMBENT ----
# Equal predictive accuracy against bvar_a2, one-sided (is the challenger
# better). h-step forecast errors are serially correlated by construction, so the
# test is run at the matching h with the Harvey-Leybourne-Newbold correction.
cat("\n=== Diebold-Mariano vs bvar_a2 (p < 0.05 = challenger genuinely better) ===\n")
errs <- race |>
  dplyr::mutate(err = actual - forecast) |>
  dplyr::select(origin, model, horizon, err) |>
  tidyr::pivot_wider(names_from = model, values_from = err)

dm_tbl <- purrr::map_dfr(setdiff(unique(race$model), "bvar_a2"), function(m) {
  purrr::map_dfr(HORIZONS, function(h) {
    d <- errs |> dplyr::filter(horizon == h) |>
      dplyr::select(chal = dplyr::all_of(m), inc = "bvar_a2") |>
      dplyr::filter(!is.na(chal), !is.na(inc))
    t <- tryCatch(forecast::dm.test(d$chal, d$inc, h = h, power = 2,
                                    alternative = "less"),
                  error = function(e) NULL)
    tibble::tibble(model = m, horizon = h, n = nrow(d),
                   dm = if (is.null(t)) NA_real_ else unname(t$statistic),
                   p  = if (is.null(t)) NA_real_ else t$p.value)
  })
})
print(as.data.frame(dm_tbl |> dplyr::mutate(dm = round(dm, 2), p = round(p, 4)) |>
                      dplyr::arrange(horizon, p)))

# 6.0.0 IS IT THE DEEPER HISTORY? ----
# The univariate winner is re-run on the SHORT (2009-) sample, so the only
# difference from the BVARs is the model, not the data. If the short-sample ARIMA
# still beats them, the deep history is a bonus and not the explanation.
cat("\n=== ARIMA: deep (1989-) vs short (2009-) sample ===\n")
hist_cmp <- purrr::map_dfr(origins, function(i) {
  od <- panel$date[i]
  y_d <- dplyr::filter(infl, date <= od)
  y_s <- dplyr::filter(infl, date <= od, date >= SAMPLE_START)
  f <- list(
    arima_deep  = tryCatch(as.numeric(forecast(auto.arima(
      stats::ts(y_d$infl, frequency = 12,
                start = c(lubridate::year(min(infl$date)),
                          lubridate::month(min(infl$date))))), h = MAXH)$mean),
      error = function(e) rep(NA_real_, MAXH)),
    arima_short = tryCatch(as.numeric(forecast(auto.arima(
      stats::ts(y_s$infl, frequency = 12, start = c(2009, 1))), h = MAXH)$mean),
      error = function(e) rep(NA_real_, MAXH))
  )
  purrr::map_dfr(names(f), function(m) {
    tibble::tibble(model = m, horizon = HORIZONS, forecast = f[[m]][HORIZONS],
                   actual = actual_at(od %m+% months(HORIZONS)))
  })
}) |>
  dplyr::filter(!is.na(forecast), !is.na(actual)) |>
  dplyr::group_by(model, horizon) |>
  dplyr::summarise(rmse = round(sqrt(mean((actual - forecast)^2)), 3),
                   .groups = "drop") |>
  tidyr::pivot_wider(names_from = model, values_from = rmse) |>
  dplyr::left_join(acc |> dplyr::filter(model == "bvar_a2") |>
                     dplyr::transmute(horizon, bvar_a2 = round(rmse, 3)),
                   by = "horizon")
print(as.data.frame(hist_cmp))

# 7.0.0 VERDICT ----
best <- acc |>
  dplyr::group_by(horizon) |>
  dplyr::slice_min(rmse, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::select(horizon, best = model, best_rmse = rmse) |>
  dplyr::left_join(acc |> dplyr::filter(model == "bvar_a2") |>
                     dplyr::select(horizon, bvar_rmse = rmse), by = "horizon") |>
  dplyr::left_join(dm_tbl |> dplyr::select(horizon, model, p),
                   by = c("horizon", "best" = "model")) |>
  dplyr::mutate(gain_pct = 100 * (bvar_rmse - best_rmse) / bvar_rmse,
                significant = !is.na(p) & p < 0.05)

cat("\n=== VERDICT ===\n")
print(as.data.frame(best |> dplyr::mutate(
  dplyr::across(c(best_rmse, bvar_rmse, gain_pct), ~ round(., 3)), p = round(p, 4))))

for (i in seq_len(nrow(best))) {
  chk(sprintf("h=%d: incumbent BVAR is the best available model", best$horizon[i]),
      best$best[i] == "bvar_a2",
      sprintf("best = %s (%.1f%% better, DM p = %s)", best$best[i],
              best$gain_pct[i],
              if (is.na(best$p[i])) "n/a" else formatC(best$p[i], format = "f", digits = 4)))
}

if (any(best$best != "bvar_a2" & best$significant)) {
  cat("\nThe BVAR inflation forecast is beaten by a univariate model at a\n",
      "horizon where the difference is significant. `forecast_macro`'s\n",
      "inflation rows should not be published as the site's inflation view\n",
      "without addressing this.\n", sep = "")
} else {
  cat("\nNo challenger beats the incumbent significantly; the BVAR stands.\n")
}

# Left in memory for interactive viewing, never saved.
p_race <- ggplot2::ggplot(
  acc |> dplyr::filter(model %in% c("rw", "arima", "ets", "stlm_ets", "bvar_a2")),
  ggplot2::aes(factor(horizon), rmse, fill = model)) +
  ggplot2::geom_col(position = "dodge") +
  ggplot2::labs(x = "horizon (months)", y = "RMSE (pp of YoY inflation)",
                title = "Inflation forecast race: out-of-sample RMSE") +
  ggplot2::theme_minimal(base_size = 12)

cat("\nView `p_race` for the RMSE comparison.\n")
