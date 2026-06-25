# A2 policy-rate path — verification checks (run interactively, never scheduled) ----
#
# Confirms the BVAR density forecast landed in Postgres and is well-formed. Run
# from the repo root AFTER R/run_models.R:
#   source("R/models/checks/policy_rate_path_checks.R")
# Each check prints PASS/FAIL; `p_fan` is left as an in-memory ggplot (the fan
# chart) to view interactively, not saved to disk.

library(tidyverse)
library(DBI)
library(RPostgres)

con <- DBI::dbConnect(RPostgres::Postgres())

fc    <- dplyr::tbl(con, "forecast_policy_rate") |> dplyr::collect()
draws <- dplyr::tbl(con, "bvar_policy_draws") |> dplyr::collect()
last_actual <- dplyr::tbl(con, "rates_policy") |>
  dplyr::collect() |> dplyr::arrange(date) |> dplyr::slice_tail(n = 1)

chk <- function(label, pass, detail = "") {
  cat(sprintf("[%s] %s%s\n", if (pass) "PASS" else "FAIL", label,
              if (nzchar(detail)) paste0(" — ", detail) else ""))
}

origin <- max(fc$origin_date)
fc_o <- dplyr::filter(fc, origin_date == origin)

# 1.0.0 STRUCTURE ----
chk("18 horizons x 5 quantiles present",
    dplyr::n_distinct(fc_o$horizon) == 18 && dplyr::n_distinct(fc_o$quantile) == 5,
    sprintf("h=%d q=%d", dplyr::n_distinct(fc_o$horizon), dplyr::n_distinct(fc_o$quantile)))
chk("quantiles are the fixed set",
    setequal(unique(fc_o$quantile), c(0.05, 0.16, 0.50, 0.84, 0.95)))
chk("no NA in forecast values", !anyNA(fc_o$value))

# 2.0.0 BANDS WELL-ORDERED ----
band_ok <- fc_o |>
  dplyr::select(horizon, quantile, value) |>
  tidyr::pivot_wider(names_from = quantile, values_from = value) |>
  dplyr::summarise(ok = all(`0.05` <= `0.16` & `0.16` <= `0.5` &
                            `0.5` <= `0.84` & `0.84` <= `0.95`)) |>
  dplyr::pull(ok)
chk("bands monotone (p05<=p16<=p50<=p84<=p95) at every horizon", band_ok)

# Fan widens with horizon (uncertainty grows): 90% width at h18 > at h1.
width <- fc_o |>
  dplyr::filter(quantile %in% c(0.05, 0.95)) |>
  dplyr::group_by(horizon) |>
  dplyr::summarise(w = diff(range(value)), .groups = "drop")
chk("uncertainty grows with horizon (width h18 > h1)",
    width$w[width$horizon == 18] > width$w[width$horizon == 1],
    sprintf("w1=%.2f w18=%.2f", width$w[width$horizon == 1], width$w[width$horizon == 18]))

# 3.0.0 CONTINUITY WITH LAST ACTUAL ----
# The 1-month-ahead median should be within a plausible step of the last actual
# policy rate (no discontinuous jump). Allow ~1pp (a couple of MPC moves).
h1_med <- fc_o$value[fc_o$horizon == 1 & fc_o$quantile == 0.50]
chk("1m median near last actual rate (<=1pp gap)",
    abs(h1_med - last_actual$policy_rate) <= 1.0,
    sprintf("h1=%.2f vs actual=%.2f", h1_med, last_actual$policy_rate))

# 4.0.0 DRAWS COMPLETE ----
n_draw <- dplyr::n_distinct(draws$draw)
chk("draws form a complete draw x horizon grid",
    nrow(dplyr::filter(draws, origin_date == origin)) == n_draw * 18,
    sprintf("%d draws x 18 horizons", n_draw))
# Draw quantiles reconstruct the forecast table (draws and bands agree).
recon <- draws |>
  dplyr::filter(origin_date == origin, horizon == 12) |>
  dplyr::summarise(p50 = stats::quantile(rate, 0.5)) |> dplyr::pull(p50)
fc_p50_h12 <- fc_o$value[fc_o$horizon == 12 & fc_o$quantile == 0.50]
chk("persisted draws reconstruct the band table",
    abs(recon - fc_p50_h12) < 1e-6,
    sprintf("draw p50=%.3f vs table=%.3f", recon, fc_p50_h12))

# 5.0.0 FAN CHART (in-memory; view interactively) ----
hist <- dplyr::tbl(con, "rates_policy") |> dplyr::collect() |>
  dplyr::mutate(date = lubridate::floor_date(date, "month")) |>
  dplyr::group_by(date) |> dplyr::summarise(policy_rate = dplyr::last(policy_rate), .groups = "drop") |>
  dplyr::filter(date >= origin %m-% months(24))
fan <- fc_o |>
  dplyr::select(forecast_date, quantile, value) |>
  tidyr::pivot_wider(names_from = quantile, values_from = value,
                     names_prefix = "q")
p_fan <- ggplot2::ggplot() +
  ggplot2::geom_ribbon(data = fan,
                       ggplot2::aes(forecast_date, ymin = `q0.05`, ymax = `q0.95`),
                       fill = "#9ecae1", alpha = 0.5) +
  ggplot2::geom_ribbon(data = fan,
                       ggplot2::aes(forecast_date, ymin = `q0.16`, ymax = `q0.84`),
                       fill = "#4292c6", alpha = 0.5) +
  ggplot2::geom_line(data = fan, ggplot2::aes(forecast_date, `q0.5`),
                     colour = "#08306b", linewidth = 0.7) +
  ggplot2::geom_line(data = hist, ggplot2::aes(date, policy_rate), linewidth = 0.6) +
  ggplot2::labs(title = "A2 policy-rate path — BVAR density forecast",
                subtitle = sprintf("origin %s; median + 68%%/90%% bands; black = actual", origin),
                x = NULL, y = "policy rate (%)") +
  ggplot2::theme_minimal(base_size = 12) +
  ggplot2::theme(panel.grid.minor = ggplot2::element_blank(),
                 plot.title = ggplot2::element_text(face = "bold"))

DBI::dbDisconnect(con)
cat("\nView `p_fan` to inspect the forecast fan interactively.\n")
