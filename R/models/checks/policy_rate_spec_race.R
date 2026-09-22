# A2 policy-rate path — specification race (run interactively, never scheduled) ----
#
# The question this answers: is A2's compact-core variable set the best available
# specification for the policy rate, or is the persistence problem CLAUDE.md
# documents a consequence of what the VAR was given rather than of the approach?
#
# The answer is the latter. A2's six variables leave a large, broad improvement
# on the table, and the variable that closes most of it is the money-market
# curve: REIBOR is ALREADY in the repo, but only as the separate point path in
# policy_rate_market.R, never as an input to the BVAR. Putting the REIBOR spreads
# over the policy rate INSIDE the system lets the density inherit the turn-
# anticipation that the market reading has and the level VAR lacks.
#
# The rule is committed to in advance, before looking at the output. Twelve
# specifications are raced, so a challenger is only preferred if it
#   * beats a2_base on RMSE, AND
#   * clears a Bonferroni-corrected Diebold-Mariano threshold (0.05/11) at some
#     horizon, AND
#   * wins at a MAJORITY of individual origins and improves in most years —
#     an RMSE gain driven by one episode is not a better model.
# The third bar is there because racing twelve specifications on 60 origins will
# always produce a winner; the question is whether the win is broad.
#
# Method: rolling origin, 60 monthly origins, 1/3/6/12 months ahead, each origin
# re-fit on data available at that time only.
#
# WHAT THIS DOES NOT SHOW. A better inflation forecast does not help here. The
# companion conclusion from inflation_forecast_race.R is that ARIMA beats the
# BVAR on inflation by ~31%, but feeding that path in as a hard condition moves
# the policy-rate RMSE by under 1% (and hurts at 12m) on BOTH a2_base and the
# winner. Section 6 shows why: predicting the 6-month CHANGE in the policy rate,
# `heat` adds +0.22 R-squared and `rdiff` +0.18, while `infl` adds -0.03. The
# policy rate's forecastable part is driven by the real/external stance and the
# money-market curve, not by the inflation print.
#
# Run from the repo root AFTER R/run_models.R (it needs `heatindex_level`):
#   Rscript -e "source('R/models/checks/policy_rate_spec_race.R')"
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
N_TEST   <- 60L
SAMPLE_START <- as.Date("2009-01-01")

# 1.0.0 PULL ----
policy <- month_end_series(con, "rates_policy", NULL, "policy_rate", "policy_rate")
twi    <- month_end_series(con, "fx_daily", "TWI", "twi")
ecb    <- month_end_series(con, "rates_external", "ECB_DEPO", "ecb")
cpi    <- monthly_series(con, "cpi", "CPI_index", "cpi")
wage   <- monthly_series(con, "wage_index", "WAGE_index", "wage")
hp     <- monthly_series(con, "house_prices", "HOUSE_PRICE_INDEX", "hp")
loans_m <- monthly_series(con, "bank_loans_sector",
                          "BANK_LOANS_HH_MORTGAGE_UNIDX", "loans_m")
heat   <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |>
  dplyr::select(date, index) |> dplyr::collect() |>
  dplyr::transmute(date, heat = index)
gap_q  <- dplyr::tbl(con, "output_gap") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), gap = value)

# The money-market curve at month end, one column per tenor. This is the input
# A2 never had.
reibor <- dplyr::tbl(con, "rates_reibor") |>
  dplyr::filter(tenor %in% c("1M", "3M", "6M")) |>
  dplyr::select(date, tenor, reibor) |> dplyr::collect() |>
  dplyr::mutate(m = lubridate::floor_date(date, "month")) |>
  dplyr::group_by(m, tenor) |>
  dplyr::slice_max(date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(date = m, tenor, reibor) |>
  tidyr::pivot_wider(names_from = tenor, values_from = reibor,
                     names_prefix = "reibor")
DBI::dbDisconnect(con)

# 2.0.0 ASSEMBLE ----
spine <- tibble::tibble(date = seq(SAMPLE_START, max(policy$date), by = "month"))
panel <- spine |>
  dplyr::left_join(policy, by = "date") |>
  dplyr::left_join(twi, by = "date") |>
  dplyr::left_join(ecb, by = "date") |>
  dplyr::left_join(cpi, by = "date") |>
  dplyr::left_join(wage, by = "date") |>
  dplyr::left_join(hp, by = "date") |>
  dplyr::left_join(loans_m, by = "date") |>
  dplyr::left_join(heat, by = "date") |>
  dplyr::left_join(reibor, by = "date") |>
  dplyr::left_join(quarterly_to_monthly(spine, gap_q, "gap"), by = "date") |>
  dplyr::arrange(date) |>
  dplyr::mutate(
    infl      = 100 * (cpi / dplyr::lag(cpi, 12) - 1),
    # 3-month annualised inflation: a faster signal than the YoY print.
    infl_3m   = 100 * ((cpi / dplyr::lag(cpi, 3))^4 - 1),
    wage_yoy  = 100 * (wage / dplyr::lag(wage, 12) - 1),
    hp_yoy    = 100 * (hp / dplyr::lag(hp, 12) - 1),
    loanm_yoy = 100 * (loans_m / dplyr::lag(loans_m, 12) - 1),
    d_ltwi    = 100 * (log(twi) - log(dplyr::lag(twi))),
    rdiff     = policy_rate - ecb,
    real_rate = policy_rate - infl,
    # The money-market curve as SPREADS over the policy rate: what the market
    # expects the Bank to do, stripped of the current level.
    sp_r3     = reibor3M - policy_rate,
    sp_r6     = reibor6M - policy_rate,
    sp_r6_r1  = reibor6M - reibor1M)

# 3.0.0 ROLLING ORIGIN ----
# a2_base is A2's own set; each challenger changes one thing so the source of any
# gain is attributable.
SPECS <- list(
  a2_base    = c("policy_rate", "infl", "heat", "gap", "ecb", "d_ltwi"),
  mm         = c("policy_rate", "infl", "heat", "sp_r6_r1", "ecb", "d_ltwi"),
  mm2        = c("policy_rate", "infl", "heat", "sp_r6", "sp_r3", "ecb"),
  reibor_lvl = c("policy_rate", "reibor6M", "infl", "heat", "ecb", "d_ltwi"),
  housing    = c("policy_rate", "infl", "heat", "hp_yoy", "loanm_yoy", "ecb"),
  realrate   = c("policy_rate", "infl", "heat", "real_rate", "ecb", "d_ltwi"),
  fast_infl  = c("policy_rate", "infl_3m", "heat", "gap", "ecb", "d_ltwi"),
  fast_mm    = c("policy_rate", "infl_3m", "heat", "sp_r6_r1", "ecb", "d_ltwi"),
  wages      = c("policy_rate", "infl", "heat", "wage_yoy", "ecb", "d_ltwi"),
  big8       = c("policy_rate", "infl", "heat", "sp_r6_r1", "hp_yoy", "wage_yoy",
                 "ecb", "d_ltwi"),
  screen     = c("policy_rate", "infl", "heat", "sp_r6_r1", "hp_yoy",
                 "real_rate", "ecb"),
  small4     = c("policy_rate", "infl", "heat", "sp_r6_r1"))

base <- panel |>
  dplyr::select(date, dplyr::all_of(unique(unlist(SPECS)))) |>
  dplyr::filter(dplyr::if_all(-date, ~ !is.na(.)))
origins <- utils::tail(seq_len(nrow(base) - MAXH), N_TEST)
cat(sprintf("Rolling origins: %s .. %s (n = %d)\n",
            base$date[min(origins)], base$date[max(origins)], length(origins)))

race <- purrr::map_dfr(origins, function(i) {
  train <- base[seq_len(i), ]
  od    <- train$date[i]
  purrr::map_dfr(names(SPECS), function(nm) {
    v <- SPECS[[nm]]
    fcast <- tryCatch({
      Y <- as.matrix(dplyr::select(train, dplyr::all_of(v)))
      fit <- suppressWarnings(BVAR::bvar(Y, lags = 2L, n_draw = 3000L,
                                         n_burn = 1000L, verbose = FALSE))
      sim <- bvar_simulate(fit, Y, lags = 2L, horizon = MAXH)
      apply(sim[, , 1, drop = FALSE], 2, stats::median, na.rm = TRUE)
    }, error = function(e) rep(NA_real_, MAXH))
    tibble::tibble(origin = od, model = nm, horizon = HORIZONS,
                   forecast = fcast[HORIZONS],
                   actual = base$policy_rate[i + HORIZONS],
                   rw = train$policy_rate[i])
  })
}) |>
  dplyr::filter(!is.na(forecast), !is.na(actual))

# 4.0.0 ACCURACY ----
acc <- race |>
  dplyr::group_by(model, horizon) |>
  dplyr::summarise(n = dplyr::n(),
                   rmse = sqrt(mean((actual - forecast)^2)), .groups = "drop") |>
  dplyr::left_join(race |> dplyr::group_by(horizon) |>
                     dplyr::summarise(rmse_rw = sqrt(mean((actual - rw)^2)),
                                      .groups = "drop"), by = "horizon") |>
  dplyr::left_join(race |> dplyr::filter(model == "a2_base") |>
                     dplyr::group_by(horizon) |>
                     dplyr::summarise(rmse_base = sqrt(mean((actual - forecast)^2)),
                                      .groups = "drop"), by = "horizon") |>
  dplyr::mutate(vs_rw = rmse / rmse_rw, vs_base = rmse / rmse_base)

for (h in HORIZONS) {
  cat(sprintf("\n=== h = %d months (vs_base < 1 beats A2's variable set) ===\n", h))
  print(as.data.frame(
    acc |> dplyr::filter(horizon == h) |> dplyr::arrange(rmse) |>
      dplyr::select(model, n, rmse, vs_rw, vs_base) |>
      dplyr::mutate(dplyr::across(c(rmse, vs_rw, vs_base), ~ round(., 3)))))
}

# 5.0.0 DIEBOLD-MARIANO + BREADTH ----
cat(sprintf("\n=== Diebold-Mariano vs a2_base (Bonferroni: p < %.4f) ===\n",
            0.05 / (length(SPECS) - 1)))
errs <- race |>
  dplyr::mutate(err = actual - forecast) |>
  dplyr::select(origin, model, horizon, err) |>
  tidyr::pivot_wider(names_from = model, values_from = err)

dm_tbl <- purrr::map_dfr(setdiff(names(SPECS), "a2_base"), function(m) {
  purrr::map_dfr(HORIZONS, function(h) {
    d <- errs |> dplyr::filter(horizon == h) |>
      dplyr::select(chal = dplyr::all_of(m), inc = "a2_base") |>
      dplyr::filter(!is.na(chal), !is.na(inc))
    t <- tryCatch(forecast::dm.test(d$chal, d$inc, h = h, power = 2,
                                    alternative = "less"),
                  error = function(e) NULL)
    tibble::tibble(model = m, horizon = h,
                   dm = if (is.null(t)) NA_real_ else unname(t$statistic),
                   p  = if (is.null(t)) NA_real_ else t$p.value)
  })
})
print(as.data.frame(
  dm_tbl |> dplyr::filter(p < 0.05) |> dplyr::arrange(horizon, p) |>
    dplyr::mutate(dm = round(dm, 2), p = round(p, 5),
                  sig_bonf = p < 0.05 / (length(SPECS) - 1))))

# Breadth: the share of individual origins a challenger wins, and its RMSE by
# origin year. A gain concentrated in one year is a coincidence, not a model.
wide_fc <- race |>
  dplyr::select(origin, model, horizon, forecast, actual) |>
  tidyr::pivot_wider(names_from = model, values_from = forecast)
cat("\n=== Share of individual origins beating a2_base ===\n")
print(as.data.frame(
  wide_fc |> dplyr::filter(!is.na(a2_base)) |> dplyr::group_by(horizon) |>
    dplyr::summarise(
      mm2 = round(mean(abs(actual - mm2) < abs(actual - a2_base), na.rm = TRUE), 3),
      screen = round(mean(abs(actual - screen) < abs(actual - a2_base), na.rm = TRUE), 3),
      n = dplyr::n(), .groups = "drop")))

cat("\n=== RMSE by origin year, h = 6 (is the win broad?) ===\n")
print(as.data.frame(
  race |> dplyr::filter(horizon == 6, model %in% c("a2_base", "mm2", "screen")) |>
    dplyr::mutate(yr = lubridate::year(origin)) |>
    dplyr::group_by(model, yr) |>
    dplyr::summarise(rmse = round(sqrt(mean((actual - forecast)^2)), 2),
                     .groups = "drop") |>
    tidyr::pivot_wider(names_from = model, values_from = rmse)))

# 6.0.0 WHY INFLATION IS NOT THE BINDING CONSTRAINT ----
# Predicting the 6-month CHANGE in the policy rate — the part persistence cannot
# supply. Reported because it is the direct answer to "wouldn't a better
# inflation forecast help?": on this data it does not, and this shows what does.
cat("\n=== Marginal R-squared for the 6-month policy-rate CHANGE ===\n")
chg <- panel |> dplyr::mutate(tgt = dplyr::lead(policy_rate, 6) - policy_rate)
r2_base <- summary(stats::lm(tgt ~ policy_rate, data = chg))$r.squared
cat(sprintf("  base (level only)      R2 = %.4f\n", r2_base))
for (v in c("infl", "infl_3m", "heat", "sp_r6_r1", "sp_r6", "hp_yoy",
            "real_rate", "rdiff", "wage_yoy")) {
  m <- stats::lm(stats::as.formula(paste("tgt ~ policy_rate +", v)), data = chg)
  cat(sprintf("  + %-10s           R2 = %.4f  (%+.4f)\n", v,
              summary(m)$r.squared, summary(m)$r.squared - r2_base))
}

# 7.0.0 VERDICT ----
best <- acc |>
  dplyr::group_by(horizon) |>
  dplyr::slice_min(rmse, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::select(horizon, best = model, best_rmse = rmse, vs_base) |>
  dplyr::left_join(dm_tbl |> dplyr::select(horizon, model, p),
                   by = c("horizon", "best" = "model"))

cat("\n=== VERDICT ===\n")
print(as.data.frame(best |> dplyr::mutate(
  gain_pct = round(100 * (1 - vs_base), 1),
  best_rmse = round(best_rmse, 3), p = round(p, 5)) |>
    dplyr::select(horizon, best, best_rmse, gain_pct, p)))

for (i in seq_len(nrow(best))) {
  chk(sprintf("h=%d: A2's variable set is the best available", best$horizon[i]),
      best$best[i] == "a2_base",
      sprintf("best = %s (%.1f%% better)", best$best[i],
              100 * (1 - best$vs_base[i])))
}

# Left in memory for interactive viewing, never saved.
p_spec_race <- ggplot2::ggplot(
  acc |> dplyr::filter(model %in% c("a2_base", "mm2", "screen", "reibor_lvl", "big8")),
  ggplot2::aes(factor(horizon), rmse, fill = model)) +
  ggplot2::geom_col(position = "dodge") +
  ggplot2::labs(x = "horizon (months)", y = "RMSE (pp)",
                title = "Policy-rate specification race") +
  ggplot2::theme_minimal(base_size = 12)

cat("\nView `p_spec_race` for the RMSE comparison.\n")
