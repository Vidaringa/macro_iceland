# A6 ISK path — out-of-sample backtest (run interactively, never scheduled) ----
#
# The question this answers: does the model have DIRECTIONAL skill, or is it only
# a statement about uncertainty? That decision governs what the app is allowed to
# claim, so it is measured here rather than asserted.
#
# The rule is committed to in advance, before looking at the output. Three
# horizons are tested, so the threshold is Bonferroni-corrected (p < 0.05/3):
# testing three things and reporting the best one at p < 0.05 would find
# "skill" in pure noise 14% of the time.
#   * a horizon clearing the corrected threshold AND beating the random walk on
#     RMSE lets the app state the measured rate and show a directional view;
#   * anything weaker means the app presents a DENSITY only, and the methodology
#     page says plainly that the central path is uninformative.
# Pre-committing is what stops this turning into a search across specifications
# for one that happens to look good.
#
# Method: rolling origin. Re-fit on data up to each origin month, forecast h
# months ahead, compare sign(median forecast) with sign(actual). The benchmark is
# a random walk — for a log CHANGE that means "no change", i.e. a forecast of
# zero, which is the honest null for an exchange rate.
#
# Run from the repo root AFTER R/run_models.R:
#   Rscript -e "source('R/models/checks/isk_path_backtest.R')"
# Plot objects are left in memory, never written to disk.

library(tidyverse)
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

# 1.0.0 REBUILD THE MODEL PANEL ----
# Mirrors isk_path.R exactly; if that file's variable set changes, change it here.
twi  <- month_end_series(con, "fx_daily", "TWI", "twi")
pol  <- month_end_series(con, "rates_policy", NULL, "policy_rate", "policy_rate")
ecb  <- month_end_series(con, "rates_external", "ECB_DEPO", "ecb")
heat <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |>
  dplyr::select(date, index) |> dplyr::collect() |>
  dplyr::transmute(date, heat = index)
ca_q <- dplyr::tbl(con, "current_account") |>
  dplyr::filter(series == "CURRENT_ACCOUNT") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), ca = value)
tot_q <- dplyr::tbl(con, "terms_of_trade") |>
  dplyr::filter(series == "TERMS_OF_TRADE_GS") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), tot = value)
DBI::dbDisconnect(con)

spine <- tibble::tibble(date = seq(as.Date("2009-01-01"), max(twi$date), by = "month"))
panel <- spine |>
  dplyr::left_join(twi, by = "date") |>
  dplyr::left_join(pol, by = "date") |>
  dplyr::left_join(ecb, by = "date") |>
  dplyr::left_join(heat, by = "date") |>
  dplyr::left_join(quarterly_to_monthly(spine, ca_q, "ca"), by = "date") |>
  dplyr::left_join(quarterly_to_monthly(spine, tot_q, "tot"), by = "date") |>
  dplyr::arrange(date) |>
  dplyr::mutate(
    d_ltwi    = 100 * (log(twi) - log(dplyr::lag(twi))),
    rdiff     = policy_rate - ecb,
    d_ltot    = 100 * (log(tot) - log(dplyr::lag(tot))),
    ca_scaled = ca / 10000) |>
  dplyr::select(date, d_ltwi, rdiff, ca_scaled, d_ltot, heat) |>
  dplyr::filter(dplyr::if_all(-date, ~ !is.na(.)))

N_TEST  <- 60L    # months of out-of-sample origins
HORIZONS <- c(1L, 3L, 6L)
MAXH <- max(HORIZONS)

# 2.0.0 ROLLING ORIGIN ----
# Each origin re-fits on data available AT THAT TIME only — no peeking. Draws are
# reduced here (the point is the median, not the band) to keep ~60 refits quick.
origins <- utils::tail(seq_len(nrow(panel) - MAXH), N_TEST)
res <- purrr::map_dfr(origins, function(i) {
  train <- panel[seq_len(i), ]
  Y <- as.matrix(dplyr::select(train, -date))
  fit <- suppressWarnings(
    BVAR::bvar(Y, lags = 2L, n_draw = 3000L, n_burn = 1000L, verbose = FALSE))
  sim <- bvar_simulate(fit, Y, lags = 2L, horizon = MAXH)
  purrr::map_dfr(HORIZONS, function(h) {
    tibble::tibble(
      origin   = train$date[i],
      horizon  = h,
      forecast = stats::median(sim[, h, 1], na.rm = TRUE),
      actual   = panel$d_ltwi[i + h])
  })
})

# 3.0.0 DIRECTIONAL SKILL ----
cat("\n=== Directional hit rate (sign of forecast vs sign of actual) ===\n")
hits <- res |>
  dplyr::filter(!is.na(actual), actual != 0) |>
  dplyr::group_by(horizon) |>
  dplyr::summarise(
    n    = dplyr::n(),
    hits = sum(sign(forecast) == sign(actual)),
    rate = hits / n,
    p    = stats::binom.test(hits, n, 0.5, alternative = "greater")$p.value,
    .groups = "drop")
print(as.data.frame(hits |> dplyr::mutate(rate = round(rate, 3), p = round(p, 4))))

for (i in seq_len(nrow(hits))) {
  chk(sprintf("h=%d beats a coin flip", hits$horizon[i]),
      hits$p[i] < 0.05,
      sprintf("%d/%d = %.1f%%, p=%.3f", hits$hits[i], hits$n[i],
              100 * hits$rate[i], hits$p[i]))
}

# 4.0.0 ACCURACY VS THE RANDOM WALK ----
# For a log change the random walk predicts zero. Beating it on RMSE is a
# stronger claim than direction and is rarer in FX.
cat("\n=== RMSE vs the random-walk (zero-change) benchmark ===\n")
acc <- res |>
  dplyr::filter(!is.na(actual)) |>
  dplyr::group_by(horizon) |>
  dplyr::summarise(
    rmse_model = sqrt(mean((actual - forecast)^2)),
    rmse_rw    = sqrt(mean(actual^2)),
    ratio      = rmse_model / rmse_rw,
    .groups = "drop")
print(as.data.frame(acc |> dplyr::mutate(dplyr::across(-horizon, ~round(., 3)))))

for (i in seq_len(nrow(acc))) {
  chk(sprintf("h=%d beats the random walk on RMSE", acc$horizon[i]),
      acc$ratio[i] < 1,
      sprintf("ratio=%.3f", acc$ratio[i]))
}

# 5.0.0 VERDICT ----
# Both conditions, at the same horizon: a corrected-significant hit rate AND an
# RMSE better than the random walk. Direction alone can be right while the
# forecast is still useless in size, and one significant result out of three
# tested horizons is what multiple testing produces from noise.
alpha <- 0.05 / nrow(hits)
verdict_tbl <- hits |>
  dplyr::select(horizon, n, hits, rate, p) |>
  dplyr::left_join(dplyr::select(acc, horizon, ratio), by = "horizon") |>
  dplyr::mutate(passes = p < alpha & ratio < 1)

cat("\n=== VERDICT ===\n")
cat(sprintf("Bonferroni threshold for %d horizons: p < %.4f\n", nrow(hits), alpha))
print(as.data.frame(verdict_tbl |>
  dplyr::mutate(rate = round(rate, 3), p = round(p, 4), ratio = round(ratio, 3))))

if (any(verdict_tbl$passes)) {
  cat("\nDirectional skill established. The app MAY state the measured hit rate\n",
      "and show the median as a directional view.\n", sep = "")
} else {
  cat("\nNo horizon clears BOTH bars. The app presents this as a DENSITY only;\n",
      "the methodology page must say the central path is uninformative.\n",
      "(A nominally significant single horizon that fails Bonferroni or loses\n",
      " to the random walk on RMSE is not evidence of skill.)\n", sep = "")
}

# Left in memory for interactive viewing, never saved.
p_hits <- ggplot2::ggplot(res |> dplyr::filter(!is.na(actual)),
                          ggplot2::aes(forecast, actual)) +
  ggplot2::geom_hline(yintercept = 0, colour = "grey70") +
  ggplot2::geom_vline(xintercept = 0, colour = "grey70") +
  ggplot2::geom_point(alpha = 0.6) +
  ggplot2::facet_wrap(~ horizon, labeller = ggplot2::label_both) +
  ggplot2::labs(x = "forecast (% log change)", y = "actual (% log change)",
                title = "ISK path: out-of-sample forecast vs actual") +
  ggplot2::theme_minimal(base_size = 12)

cat("\nView `p_hits` for the scatter of forecast vs actual.\n")
