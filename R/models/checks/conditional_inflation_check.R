# A2 — does conditioning the system on a better inflation path help? ----
#
# The question this answers: inflation_forecast_race.R shows ARIMA beats the A2
# BVAR on inflation by ~31%. The obvious follow-up is whether feeding that better
# path INTO the system improves the policy-rate forecast — the number A2 exists
# to produce. Until this script was written the answer lived only in a code
# comment ("moves RMSE by under 1%"), with nothing in the repo that could have
# measured it. It is measured here.
#
# WHAT A CONDITIONAL FORECAST IS, AND IS NOT. Simulating the VAR forward and then
# overwriting the inflation element with the ARIMA value is NOT a conditional
# forecast — it leaves the other five variables drawn from their UNconditional
# shocks, so the system never learns anything from the imposed path. The correct
# object partitions each draw's shock covariance: given the conditioned variable's
# value, the remaining five are drawn from
#     N( mu_f + S_fc S_cc^-1 (c - mu_c),  S_ff - S_fc S_cc^-1 S_cf )
# so the imposed inflation path propagates into the policy rate through the
# contemporaneous correlations. That is what bvar_sim_cond() below does.
#
# RESULT (60 rolling origins, 2020-09 .. 2025-08, v2 variable set): conditioning
# moves policy-rate RMSE by -1.3% / -8.9% / -5.3% / +10.9% at h = 1/3/6/12. It
# helps in the middle of the fan and hurts a year out, and no horizon clears
# Diebold-Mariano (p = 0.20-0.60). So A2 stays unconditional — but the claim now
# rests on this script rather than on an assertion. (Figures move a little run to
# run with the MCMC seed; the sign pattern and the non-significance do not.)
#
# The test window is the 2021-23 hiking cycle (0.75% -> 9.25% -> 7.5%), which is
# also why a random walk looks strong here: it wins on the 2023-24 plateau and
# loses on the 2022 turn. That is a property of the window, not a verdict on the
# BVAR, and it is why this script reports the RW column rather than hiding it.
#
# Run from the repo root AFTER R/run_models.R (it needs `heatindex_level`):
#   Rscript -e "source('R/models/checks/conditional_inflation_check.R')"
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

HORIZONS     <- c(1L, 3L, 6L, 12L)
MAXH         <- 12L
SAMPLE_START <- as.Date("2009-01-01")
ORIGIN_FROM  <- as.Date("2020-09-01")
COND_IDX     <- 2L          # `infl` is column 2 of the v2 variable set

# 1.0.0 PULL ----
pol  <- month_end_series(con, "rates_policy", NULL, "policy_rate", "policy_rate")
infl <- monthly_series(con, "cpi", "CPI_change_A", "infl")
heat <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |>
  dplyr::select(date, index) |> dplyr::collect() |>
  dplyr::transmute(date, heat = index)
ecb  <- month_end_series(con, "rates_external", "ECB_DEPO", "ecb")
reibor <- dplyr::tbl(con, "rates_reibor") |>
  dplyr::filter(tenor %in% c("3M", "6M")) |>
  dplyr::select(date, tenor, reibor) |> dplyr::collect() |>
  dplyr::mutate(m = lubridate::floor_date(date, "month")) |>
  dplyr::group_by(m, tenor) |>
  dplyr::slice_max(date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::select(date = m, tenor, reibor) |>
  tidyr::pivot_wider(names_from = tenor, values_from = reibor)

# The ARIMA path is fit on the DEEP CPI history (1989-), which is the whole reason
# it beats the BVAR's own inflation forecast — see inflation_forecast_race.R.
cpi_deep <- dplyr::tbl(con, "cpi") |>
  dplyr::filter(series == "CPI_index") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), cpi = value) |>
  dplyr::arrange(date) |>
  dplyr::mutate(infl_deep = 100 * (cpi / dplyr::lag(cpi, 12) - 1))

DBI::dbDisconnect(con)

# 2.0.0 ASSEMBLE — the v2 variable set, column order load-bearing ----
model_vars <- c("policy_rate", "infl", "heat", "sp_r6", "sp_r3", "ecb")
panel <- pol |>
  dplyr::left_join(infl, by = "date") |>
  dplyr::left_join(heat, by = "date") |>
  dplyr::left_join(ecb,  by = "date") |>
  dplyr::left_join(reibor, by = "date") |>
  dplyr::mutate(sp_r6 = .data$`6M` - .data$policy_rate,
                sp_r3 = .data$`3M` - .data$policy_rate) |>
  dplyr::filter(date >= SAMPLE_START) |>
  dplyr::select("date", dplyr::all_of(model_vars))
panel <- panel[apply(is.finite(as.matrix(panel[, model_vars])), 1, all), ]

# 3.0.0 CONDITIONAL SIMULATION ----
# As bvar_simulate(), but when cond_idx/cond_path are supplied the conditioned
# variable is pinned to the given path and the others are drawn from their
# conditional distribution given it (see the header for why that matters).
# Kept here rather than in helpers_bvar.R: one caller, so the repo's
# "no function until it is used 3x" rule says inline it with its user.
bvar_sim_cond <- function(fit, Y, lags, horizon, cond_idx = NULL, cond_path = NULL) {
  beta <- fit$beta; sigma <- fit$sigma
  n_draw <- dim(beta)[1]; k <- dim(beta)[3]
  out <- array(NA_real_, dim = c(n_draw, horizon, k))
  last <- Y[(nrow(Y) - lags + 1):nrow(Y), , drop = FALSE]
  free <- setdiff(seq_len(k), cond_idx)

  for (i in seq_len(n_draw)) {
    B <- beta[i, , ]; S <- sigma[i, , ]
    hist <- last; ok <- TRUE
    for (h in seq_len(horizon)) {
      x  <- c(1, as.numeric(t(hist[rev(seq_len(lags)), , drop = FALSE])))
      mu <- as.numeric(x %*% B)
      y  <- numeric(k)
      if (is.null(cond_idx)) {
        C <- tryCatch(chol(S), error = function(e) NULL)
        if (is.null(C)) { ok <- FALSE; break }
        y <- mu + as.numeric(stats::rnorm(k) %*% C)
      } else {
        cv   <- cond_path[h]
        Scc  <- S[cond_idx, cond_idx, drop = FALSE]
        Sfc  <- S[free, cond_idx, drop = FALSE]
        Sff  <- S[free, free, drop = FALSE]
        iScc <- tryCatch(solve(Scc), error = function(e) NULL)
        if (is.null(iScc)) { ok <- FALSE; break }
        mf <- mu[free] + as.numeric(Sfc %*% iScc %*% (cv - mu[cond_idx]))
        Vf <- Sff - Sfc %*% iScc %*% t(Sfc)
        Cf <- tryCatch(chol((Vf + t(Vf)) / 2), error = function(e) NULL)
        if (is.null(Cf)) { ok <- FALSE; break }
        y[free]     <- mf + as.numeric(stats::rnorm(length(free)) %*% Cf)
        y[cond_idx] <- cv
      }
      out[i, h, ] <- y
      hist <- rbind(hist[-1, , drop = FALSE], y)
    }
    if (!ok) out[i, , ] <- NA
  }
  out
}

# 4.0.0 ROLLING ORIGIN ----
origins <- panel$date[panel$date >= ORIGIN_FROM &
                        panel$date <= max(panel$date) %m-% months(MAXH)]
cat(sprintf("Rolling origins: %s .. %s (n = %d)\n",
            min(origins), max(origins), length(origins)))

res <- purrr::map_dfr(origins, function(od) {
  train <- dplyr::filter(panel, date <= od)
  Y <- as.matrix(train[, model_vars])
  fit <- tryCatch(suppressWarnings(
    BVAR::bvar(Y, lags = 2L, n_draw = 1500L, n_burn = 500L, verbose = FALSE)),
    error = function(e) NULL)
  if (is.null(fit)) return(NULL)

  deep <- dplyr::filter(cpi_deep, date <= od, is.finite(infl_deep))
  arima_path <- tryCatch(
    as.numeric(forecast::forecast(forecast::auto.arima(deep$infl_deep),
                                  h = MAXH)$mean),
    error = function(e) rep(NA_real_, MAXH))

  unc  <- bvar_sim_cond(fit, Y, 2L, MAXH)
  cond <- if (anyNA(arima_path)) NULL else
    bvar_sim_cond(fit, Y, 2L, MAXH, cond_idx = COND_IDX, cond_path = arima_path)

  median_path <- function(a) {
    if (is.null(a)) return(rep(NA_real_, MAXH))
    apply(matrix(a[, , 1], nrow = dim(a)[1]), 2, stats::median, na.rm = TRUE)
  }
  tibble::tibble(origin = od, horizon = HORIZONS,
                 uncond = median_path(unc)[HORIZONS],
                 cond   = median_path(cond)[HORIZONS],
                 rw     = utils::tail(train$policy_rate, 1),
                 actual = panel$policy_rate[match(od, panel$date) + HORIZONS])
}) |>
  dplyr::filter(is.finite(actual))

# 5.0.0 SCORE ----
cat("\n=== Policy-rate RMSE by model and horizon ===\n")
print(as.data.frame(
  res |>
    tidyr::pivot_longer(c("uncond", "cond", "rw"),
                        names_to = "model", values_to = "fc") |>
    dplyr::filter(is.finite(fc)) |>
    dplyr::group_by(model, horizon) |>
    dplyr::summarise(rmse = sqrt(mean((actual - fc)^2)), .groups = "drop") |>
    dplyr::mutate(rmse = round(rmse, 4)) |>
    tidyr::pivot_wider(names_from = horizon, values_from = rmse,
                       names_prefix = "h")))

cmp <- res |>
  dplyr::filter(is.finite(cond), is.finite(uncond)) |>
  dplyr::group_by(horizon) |>
  dplyr::summarise(
    n = dplyr::n(),
    rmse_uncond = sqrt(mean((actual - uncond)^2)),
    rmse_cond   = sqrt(mean((actual - cond)^2)),
    pct_change  = 100 * (rmse_cond / rmse_uncond - 1),
    dm_p = tryCatch(forecast::dm.test(actual - cond, actual - uncond,
                                      h = horizon[1], power = 2)$p.value,
                    error = function(e) NA_real_),
    .groups = "drop")

cat("\n=== Conditioning on the ARIMA inflation path: effect on the policy rate ===\n")
cat("    (negative pct_change = conditioning HELPS)\n")
print(as.data.frame(cmp |> dplyr::mutate(
  dplyr::across(c(rmse_uncond, rmse_cond), ~ round(., 4)),
  pct_change = round(pct_change, 2), dm_p = round(dm_p, 4))))

# 6.0.0 VERDICT ----
cat("\n=== VERDICT ===\n")
chk("conditioning significantly improves the policy-rate forecast",
    any(cmp$dm_p < 0.05 & cmp$pct_change < 0, na.rm = TRUE),
    sprintf("best %.1f%% at h=%d, DM p=%.3f",
            min(cmp$pct_change), cmp$horizon[which.min(cmp$pct_change)],
            cmp$dm_p[which.min(cmp$pct_change)]))
cat("\nA2 stays UNCONDITIONAL. The published inflation number may still be the\n",
    "ARIMA one (it is ~31% better); it is simply not fed back into the system,\n",
    "so the app must label the two paths distinctly.\n", sep = "")

p_cond <- res |>
  tidyr::pivot_longer(c("uncond", "cond"), names_to = "model", values_to = "fc") |>
  dplyr::filter(is.finite(fc)) |>
  ggplot2::ggplot(ggplot2::aes(actual, fc, colour = model)) +
  ggplot2::geom_abline(slope = 1, intercept = 0, colour = "grey50", linetype = 2) +
  ggplot2::geom_point(alpha = 0.6) +
  ggplot2::facet_wrap(~ horizon, labeller = ggplot2::label_both) +
  ggplot2::labs(x = "realised policy rate", y = "forecast",
                title = "A2: unconditional vs ARIMA-conditioned policy-rate path") +
  ggplot2::theme_minimal(base_size = 12)

cat("\nView `p_cond` for the forecast-vs-realised scatter.\n")
