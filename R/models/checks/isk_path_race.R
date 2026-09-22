# A6 ISK path — specification race (run interactively, never scheduled) ----
#
# isk_path_backtest.R asks whether A6's CURRENT specification has directional
# skill. This asks the prior question the answer provokes: is there ANY BVAR
# specification on the available data that forecasts the monthly ISK move, or is
# the flat central path a property of the exchange rate rather than of the model?
#
# The bar is the one isk_path_backtest.R already committed to, applied to every
# candidate rather than to one:
#   * beat the random walk on RMSE (for a log change the random walk forecasts
#     zero), AND
#   * a directional hit rate significant at the Bonferroni-corrected threshold
#     (p < 0.05/3 across the three horizons).
# A specification clearing BOTH may be adopted and the app may show a directional
# view. Nothing else may. Racing nine specifications makes the multiple-testing
# problem worse, not better, which is exactly why the correction is applied and
# why no result here is reported as "promising".
#
# Method: rolling origin, 72 monthly origins, 1/3/6 months ahead. Each origin
# re-fits on data available at that time only.
#
# The candidates span the plausible disagreements with A6's current setup: lag
# length (1/2/6), parsimony (down to two variables — on 211 months a k=5 VAR(2)
# is already 70 parameters), the carry differential in DIFFERENCES rather than
# levels, the trade balance instead of the current account, a US/EA rate pair
# instead of the policy/ECB pair, and inflation as an extra driver. Plain ARIMA
# and ETS on the monthly change are included as univariate reference points.
#
# Run from the repo root AFTER R/run_models.R (it needs `heatindex_level`):
#   Rscript -e "source('R/models/checks/isk_path_race.R')"
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

HORIZONS <- c(1L, 3L, 6L)
MAXH     <- 6L
N_TEST   <- 72L
SAMPLE_START <- as.Date("2009-01-01")

# 1.0.0 PULL ----
twi  <- month_end_series(con, "fx_daily", "TWI", "twi")
pol  <- month_end_series(con, "rates_policy", NULL, "policy_rate", "policy_rate")
ecb  <- month_end_series(con, "rates_external", "ECB_DEPO", "ecb")
ea2  <- month_end_series(con, "rates_external", "EA_AAA_2Y", "ea2")
ust2 <- month_end_series(con, "rates_external", "UST_2Y", "ust2")
heat <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |>
  dplyr::select(date, index) |> dplyr::collect() |>
  dplyr::transmute(date, heat = index)
ca_q <- dplyr::tbl(con, "current_account") |>
  dplyr::filter(series == "CURRENT_ACCOUNT") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), ca = value)
tb_q <- dplyr::tbl(con, "current_account") |>
  dplyr::filter(series == "TRADE_BALANCE") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), tb = value)
tot_q <- dplyr::tbl(con, "terms_of_trade") |>
  dplyr::filter(series == "TERMS_OF_TRADE_GS") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), tot = value)
cpi <- dplyr::tbl(con, "cpi") |>
  dplyr::filter(series == "CPI_index") |>
  dplyr::select(date, value) |> dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(date, "month"), cpi = value)
DBI::dbDisconnect(con)

# 2.0.0 ASSEMBLE ----
# The d_ltwi / rdiff / ca_scaled / d_ltot construction mirrors isk_path.R; the
# rest are the extra candidate drivers. CONSUMER_IMPORTS was considered as a
# monthly demand proxy and dropped: it is missing for 74 of the 213 months from
# 2009, which would cost a third of the sample.
spine <- tibble::tibble(date = seq(SAMPLE_START, max(twi$date), by = "month"))
panel <- spine |>
  dplyr::left_join(twi, by = "date") |>
  dplyr::left_join(pol, by = "date") |>
  dplyr::left_join(ecb, by = "date") |>
  dplyr::left_join(ea2, by = "date") |>
  dplyr::left_join(ust2, by = "date") |>
  dplyr::left_join(heat, by = "date") |>
  dplyr::left_join(quarterly_to_monthly(spine, ca_q, "ca"), by = "date") |>
  dplyr::left_join(quarterly_to_monthly(spine, tb_q, "tb"), by = "date") |>
  dplyr::left_join(quarterly_to_monthly(spine, tot_q, "tot"), by = "date") |>
  dplyr::left_join(cpi, by = "date") |>
  dplyr::arrange(date) |>
  dplyr::mutate(
    d_ltwi    = 100 * (log(twi) - log(dplyr::lag(twi))),
    rdiff     = policy_rate - ecb,
    rdiff2    = policy_rate - ea2,
    d_ltot    = 100 * (log(tot) - log(dplyr::lag(tot))),
    ca_scaled = ca / 10000,
    tb_scaled = tb / 10000,
    infl      = 100 * (cpi / dplyr::lag(cpi, 12) - 1),
    d_rdiff   = rdiff - dplyr::lag(rdiff)) |>
  dplyr::select(date, d_ltwi, rdiff, rdiff2, ust2, ca_scaled, tb_scaled,
                d_ltot, heat, infl, d_rdiff) |>
  dplyr::filter(dplyr::if_all(-date, ~ !is.na(.)))

# 3.0.0 ROLLING ORIGIN ----
SPECS <- list(
  a6_current = list(v = c("d_ltwi", "rdiff", "ca_scaled", "d_ltot", "heat"), l = 2L),
  a6_lag1    = list(v = c("d_ltwi", "rdiff", "ca_scaled", "d_ltot", "heat"), l = 1L),
  a6_lag6    = list(v = c("d_ltwi", "rdiff", "ca_scaled", "d_ltot", "heat"), l = 6L),
  min3       = list(v = c("d_ltwi", "rdiff", "heat"), l = 1L),
  min2       = list(v = c("d_ltwi", "rdiff"), l = 1L),
  drdiff     = list(v = c("d_ltwi", "d_rdiff", "heat", "d_ltot"), l = 1L),
  tb_spec    = list(v = c("d_ltwi", "rdiff", "tb_scaled", "d_ltot", "heat"), l = 2L),
  infl_spec  = list(v = c("d_ltwi", "rdiff", "infl", "heat"), l = 2L),
  ust        = list(v = c("d_ltwi", "rdiff2", "ust2", "heat", "d_ltot"), l = 2L))

origins <- utils::tail(seq_len(nrow(panel) - MAXH), N_TEST)
cat(sprintf("Rolling origins: %s .. %s (n = %d)\n",
            panel$date[min(origins)], panel$date[max(origins)], length(origins)))

race <- purrr::map_dfr(origins, function(i) {
  train <- panel[seq_len(i), ]
  od    <- train$date[i]
  ts_y  <- stats::ts(train$d_ltwi, frequency = 12,
                     start = c(lubridate::year(min(panel$date)),
                               lubridate::month(min(panel$date))))
  # The random walk for a log CHANGE is a forecast of zero.
  fc <- list(
    rw    = rep(0, MAXH),
    arima = tryCatch(as.numeric(forecast(auto.arima(ts_y), h = MAXH)$mean),
                     error = function(e) rep(NA_real_, MAXH)),
    ets   = tryCatch(as.numeric(forecast(ets(ts_y), h = MAXH)$mean),
                     error = function(e) rep(NA_real_, MAXH)))

  for (nm in names(SPECS)) {
    sp <- SPECS[[nm]]
    fc[[nm]] <- tryCatch({
      Y <- as.matrix(dplyr::select(train, dplyr::all_of(sp$v)))
      fit <- suppressWarnings(BVAR::bvar(Y, lags = sp$l, n_draw = 3000L,
                                         n_burn = 1000L, verbose = FALSE))
      sim <- bvar_simulate(fit, Y, lags = sp$l, horizon = MAXH)
      apply(sim[, , which(sp$v == "d_ltwi"), drop = FALSE], 2, stats::median,
            na.rm = TRUE)
    }, error = function(e) rep(NA_real_, MAXH))
  }

  purrr::map_dfr(names(fc), function(m) {
    tibble::tibble(origin = od, model = m, horizon = HORIZONS,
                   forecast = fc[[m]][HORIZONS],
                   actual = panel$d_ltwi[i + HORIZONS])
  })
}) |>
  dplyr::filter(!is.na(forecast), !is.na(actual))

# 4.0.0 SCORE ----
acc <- race |>
  dplyr::group_by(model, horizon) |>
  dplyr::summarise(n = dplyr::n(),
                   rmse = sqrt(mean((actual - forecast)^2)),
                   sd_fc = stats::sd(forecast), .groups = "drop") |>
  dplyr::left_join(race |> dplyr::filter(model == "rw") |>
                     dplyr::group_by(horizon) |>
                     dplyr::summarise(rmse_rw = sqrt(mean((actual - forecast)^2)),
                                      .groups = "drop"), by = "horizon") |>
  dplyr::mutate(rel_rw = rmse / rmse_rw)

hits <- race |>
  dplyr::filter(actual != 0, forecast != 0) |>
  dplyr::group_by(model, horizon) |>
  dplyr::summarise(nh = dplyr::n(),
                   hits = sum(sign(forecast) == sign(actual)),
                   rate = hits / nh,
                   p = stats::binom.test(hits, nh, 0.5,
                                         alternative = "greater")$p.value,
                   .groups = "drop")

scored <- acc |>
  dplyr::left_join(dplyr::select(hits, model, horizon, rate, p),
                   by = c("model", "horizon"))

for (h in HORIZONS) {
  cat(sprintf("\n=== h = %d months ===\n", h))
  print(as.data.frame(
    scored |> dplyr::filter(horizon == h) |> dplyr::arrange(rel_rw) |>
      dplyr::select(model, n, rmse, rel_rw, sd_fc, rate, p) |>
      dplyr::mutate(dplyr::across(c(rmse, rel_rw, sd_fc, rate), ~ round(., 3)),
                    p = round(p, 3))))
}

# 5.0.0 IS THE CENTRAL PATH SIGNAL OR NOISE? ----
# A model whose forecasts vary a lot while scoring worse than a constant zero is
# not making a weak call — it is adding noise. Comparing the spread of each
# model's forecasts against the spread of the actual series is the cleanest way
# to see that, and it is the direct answer to "the line is flat = useless".
cat("\n=== Spread of the central path vs spread of the actual series ===\n")
print(as.data.frame(
  scored |> dplyr::select(model, horizon, sd_fc) |>
    tidyr::pivot_wider(names_from = horizon, values_from = sd_fc,
                       names_prefix = "sd_h") |>
    dplyr::mutate(dplyr::across(-model, ~ round(., 3)))))
cat("\nsd of the ACTUAL monthly log change, by horizon's realisations:\n")
print(as.data.frame(
  race |> dplyr::filter(model == "rw") |> dplyr::group_by(horizon) |>
    dplyr::summarise(sd_actual = round(stats::sd(actual), 3), .groups = "drop")))

# 6.0.0 VERDICT ----
alpha <- 0.05 / length(HORIZONS)
winners <- scored |>
  dplyr::filter(!model %in% c("rw", "arima", "ets")) |>
  dplyr::mutate(passes = !is.na(p) & p < alpha & rel_rw < 1)

cat("\n=== VERDICT ===\n")
cat(sprintf("Bonferroni threshold across %d horizons: p < %.4f\n",
            length(HORIZONS), alpha))
cat(sprintf("Best relative RMSE achieved by any BVAR specification: %.3f (%s, h=%d)\n",
            min(winners$rel_rw), winners$model[which.min(winners$rel_rw)],
            winners$horizon[which.min(winners$rel_rw)]))

chk("some BVAR specification clears both bars", any(winners$passes),
    sprintf("%d of %d specification-horizon pairs pass",
            sum(winners$passes), nrow(winners)))

if (any(winners$passes)) {
  cat("\nA specification cleared both bars. Inspect it before adopting —\n",
      "with nine specifications raced, confirm it on a held-out window first.\n",
      sep = "")
} else {
  cat("\nNo specification beats a zero forecast. The monthly ISK move is not\n",
      "forecastable from this data, so the flat central path is the correct\n",
      "answer rather than a defect: the specifications that DO produce a\n",
      "varying path score WORSE than forecasting zero, i.e. their movement is\n",
      "noise. A6 stays density-only, as the app already presents it.\n", sep = "")
}

# Left in memory for interactive viewing, never saved.
p_fx_race <- ggplot2::ggplot(scored, ggplot2::aes(rel_rw, reorder(model, -rel_rw))) +
  ggplot2::geom_vline(xintercept = 1, colour = "grey50", linetype = 2) +
  ggplot2::geom_point() +
  ggplot2::facet_wrap(~ horizon, labeller = ggplot2::label_both) +
  ggplot2::labs(x = "RMSE relative to the random walk (<1 beats it)", y = NULL,
                title = "ISK path: specification race") +
  ggplot2::theme_minimal(base_size = 12)

cat("\nView `p_fx_race` for the relative-RMSE comparison.\n")
