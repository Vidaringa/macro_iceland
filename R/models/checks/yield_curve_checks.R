# A3 yield curves — verification checks (run interactively, never scheduled) ----
#
# Checks the fitted curves against the bonds they came from and against economic
# sense. Run from the repo root AFTER R/run_models.R:
#   Rscript -e "source('R/models/checks/yield_curve_checks.R')"
# Each check prints PASS/FAIL; plot objects stay in memory, never saved to disk.

library(tidyverse)
library(DBI)
library(RPostgres)

con <- DBI::dbConnect(RPostgres::Postgres())

params <- dplyr::tbl(con, "curve_params") |> dplyr::collect()
points <- dplyr::tbl(con, "curve_points") |> dplyr::collect()
resid  <- dplyr::tbl(con, "curve_residuals") |> dplyr::collect()
cpi    <- dplyr::tbl(con, "cpi") |> dplyr::filter(series == "CPI_change_A") |>
  dplyr::collect()

chk <- function(label, pass, detail = "") {
  cat(sprintf("[%s] %s%s\n", if (pass) "PASS" else "FAIL", label,
              if (nzchar(detail)) paste0(" — ", detail) else ""))
}

as_of <- max(points$date)
latest <- dplyr::filter(points, date == as_of)
lr     <- dplyr::filter(resid, date == as_of)

# 1.0.0 FIT QUALITY ----
# A parametric curve on 5-8 bonds should track them closely; a large residual
# means the shape is wrong or a price is stale, and either way the curve is not
# describing the market.
rmse <- lr |>
  dplyr::group_by(curve) |>
  dplyr::summarise(rmse_bp = sqrt(mean(residual^2)) * 100,
                   max_bp = max(abs(residual)) * 100, .groups = "drop")
for (i in seq_len(nrow(rmse))) {
  chk(sprintf("%s fit is tight (RMSE < 10bp)", rmse$curve[i]),
      rmse$rmse_bp[i] < 10,
      sprintf("RMSE=%.1fbp max=%.1fbp", rmse$rmse_bp[i], rmse$max_bp[i]))
}

# 2.0.0 RESIDUALS ARE CENTRED ----
# Least squares forces the mean to zero by construction; this catches a write or
# join bug rather than a modelling one.
chk("residuals centred at zero",
    abs(mean(lr$residual)) < 1e-8,
    sprintf("mean=%.2e", mean(lr$residual)))

# 3.0.0 CURVE SHAPE ----
# The ISK curve is currently inverted (policy tightening), so monotone DECREASING
# is the expected shape. The check is that it is monotone in one direction, not
# that it slopes a particular way — an upward curve is not an error.
for (cv in c("nominal", "real")) {
  y <- latest |> dplyr::filter(curve == cv) |> dplyr::arrange(maturity)
  d <- diff(y$yield)
  chk(sprintf("%s curve is monotone", cv),
      all(d <= 1e-9) || all(d >= -1e-9),
      sprintf("%d points, %s", nrow(y),
              if (all(d <= 1e-9)) "downward" else "upward/mixed"))
}

# 4.0.0 NO EXTRAPOLATION BELOW THE DATA ----
# The real curve's shortest bond is ~3y. Below its own data a Nelson-Siegel is
# unconstrained — the fitted 1y real yield moves from 0.9% to 4.6% on lambda
# alone — so publishing a point there would be inventing a number.
for (cv in c("nominal", "real")) {
  tau_min <- params |>
    dplyr::filter(date == as_of, curve == cv, parameter == "tau_min") |>
    dplyr::pull(value)
  pts <- latest |> dplyr::filter(curve == cv)
  chk(sprintf("%s curve published only within its data", cv),
      length(tau_min) == 1 && min(pts$maturity) >= tau_min - 1e-9,
      sprintf("shortest bond %.2fy, shortest published point %.2fy",
              tau_min, min(pts$maturity)))
}

# 5.0.0 BREAKEVEN = NOMINAL - REAL ----
be <- latest |>
  tidyr::pivot_wider(names_from = curve, values_from = yield) |>
  dplyr::filter(!is.na(breakeven))
chk("breakeven equals nominal minus real",
    max(abs(be$breakeven - (be$nominal - be$real))) < 1e-9,
    sprintf("max diff=%.2e over %d maturities",
            max(abs(be$breakeven - (be$nominal - be$real))), nrow(be)))

chk("breakeven published only where BOTH curves exist",
    all(!is.na(be$nominal) & !is.na(be$real)),
    sprintf("%d maturities", nrow(be)))

# 6.0.0 BREAKEVEN IS ECONOMICALLY SANE ----
# A breakeven is a priced inflation expectation. Outside 0-10% it is not an
# expectation, it is a bug — a sign flip, a unit error, or the real and nominal
# curves crossed.
be_rng <- range(be$breakeven)
chk("breakeven in a plausible range (0-10%)",
    be_rng[1] > 0 && be_rng[2] < 10,
    sprintf("%.2f%% to %.2f%%", be_rng[1], be_rng[2]))

# It should also sit in the neighbourhood of realised inflation and the target —
# far outside both would mean the curves are not measuring what we think.
infl_now <- cpi |> dplyr::arrange(date) |> dplyr::pull(value) |> dplyr::last()
be5 <- be$breakeven[which.min(abs(be$maturity - 5))]
chk("5y breakeven is within 5pp of realised inflation",
    abs(be5 - infl_now) < 5,
    sprintf("breakeven=%.2f%%, CPI y/y=%.1f%%, CBI target=2.5%%", be5, infl_now))

# 7.0.0 LAMBDA IS FIXED ACROSS DAYS ----
# The whole point of fixing it: a curve whose shape parameter wanders cannot be
# compared day to day.
lam <- params |> dplyr::filter(parameter == "lambda") |>
  dplyr::group_by(curve) |> dplyr::summarise(n = dplyr::n_distinct(value), .groups = "drop")
chk("lambda constant within each curve",
    all(lam$n == 1),
    paste(sprintf("%s:%d", lam$curve, lam$n), collapse = " "))

# 8.0.0 STALE-DAY EXCLUSION ----
chk("no weekend days in the curve history",
    all(!lubridate::wday(unique(points$date), week_start = 1) %in% c(6, 7)),
    sprintf("%d days from %s to %s", dplyr::n_distinct(points$date),
            format(min(points$date)), format(max(points$date))))

DBI::dbDisconnect(con)

# Left in memory for interactive viewing.
p_curves <- ggplot2::ggplot(
  dplyr::filter(latest, curve %in% c("nominal", "real")),
  ggplot2::aes(maturity, yield, colour = curve)) +
  ggplot2::geom_line(linewidth = 0.8) +
  ggplot2::geom_point(data = lr, ggplot2::aes(tau, yield, colour = curve), size = 2) +
  ggplot2::labs(title = paste("Fitted ISK curves,", format(as_of)),
                x = "maturity (years)", y = "yield (%)") +
  ggplot2::theme_minimal(base_size = 12)

cat("\nView `p_curves` for the fitted curves with the observed bonds.\n")
