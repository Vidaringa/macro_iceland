# Shared BVAR helpers ----
#
# The pull/assemble/persist scaffolding that every BVAR module repeats. Factored
# out when the second one (A6, the FX path) was written: A2 already carried three
# near-identical copies of the month-end reduction inline, so each of these is
# used at least three times across the two modules today.
#
# Sourced by run_models.R alongside the DB helpers, before the model files.
# Requires tidyverse + zoo (zoo via ::) attached by the runner, and `con` open.

# Reduce a long (date, series, value) table to one month-end observation per
# month. The value prevailing at month close is the right monthly reading for a
# rate or a price: a month average would smear a policy decision across the month
# it was taken in.
#
# `series` is the series code to filter on; pass NULL for a wide table whose value
# lives in its own column (`value_col`), which is how rates_policy is shaped.
month_end_series <- function(con, tbl_name, series = NULL, out_col,
                             value_col = "value") {
  q <- dplyr::tbl(con, tbl_name)
  if (!is.null(series)) q <- dplyr::filter(q, .data$series == !!series)
  q |>
    dplyr::select("date", value = dplyr::all_of(value_col)) |>
    dplyr::collect() |>
    dplyr::mutate(m = lubridate::floor_date(.data$date, "month")) |>
    dplyr::group_by(.data$m) |>
    dplyr::slice_max(.data$date, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::transmute(date = .data$m, !!out_col := .data$value)
}

# Take an already-monthly long table to one row per month, no reduction needed.
monthly_series <- function(con, tbl_name, series, out_col, value_col = "value") {
  dplyr::tbl(con, tbl_name) |>
    dplyr::filter(.data$series == !!series) |>
    dplyr::select("date", value = dplyr::all_of(value_col)) |>
    dplyr::collect() |>
    dplyr::transmute(date = lubridate::floor_date(.data$date, "month"),
                     !!out_col := .data$value)
}

# Interpolate a quarterly series onto a monthly spine and carry the last value
# forward past its final quarter. The carry-forward is what lets the forecast
# origin sit at the freshest MONTHLY observation rather than being dragged back to
# the last published quarter — the ragged edge is a fact of the data, not an
# error. Only defensible for slow-moving quantities; see the note in A6 about what
# this does to a volatile quarterly series' apparent information content.
quarterly_to_monthly <- function(spine, q_tbl, col) {
  spine |>
    dplyr::left_join(q_tbl, by = "date") |>
    dplyr::mutate(!!col := zoo::na.approx(.data[[col]], na.rm = FALSE)) |>
    tidyr::fill(dplyr::all_of(col), .direction = "down")
}

# Predictive draws simulated directly from the posterior, returning the same
# draws x horizon x variable array shape as BVAR::predict().
#
# WHY NOT USE predict(). BVAR::predict() is over-dispersed by a factor of ~2.4 on
# this package version. Verified on synthetic data with a known error sd of 2.40:
# the FITTED sigma comes back correct (2.36), but predict() reports a one-step sd
# of 5.7-5.8, and the ratio does not shrink as the sample grows (n = 211, 1000,
# 5000 all give ~2.4x), so it is not parameter uncertainty — correct draws would
# converge on the truth. Simulating here recovers 2.34-2.36 against the same 2.40.
#
# This matters most for a near-white-noise target like the monthly FX change,
# where the forecast IS essentially the error distribution: a 2.4x band would
# claim +/-10% monthly moves against an observed sd of 2.4%, which is not a
# defensible thing to publish. A2's policy-rate fan is much less affected — a
# persistent level forecast is dominated by the VAR's dynamics, and its published
# bands are sane against the data — so A2 is deliberately left on predict() until
# it can be re-validated on its own terms.
#
# For each retained posterior draw: take that draw's coefficients and covariance
# and iterate the VAR forward with fresh Gaussian shocks.
bvar_simulate <- function(fit, Y, lags, horizon) {
  beta <- fit$beta; sigma <- fit$sigma
  n_draw <- dim(beta)[1]; k <- dim(beta)[3]
  out <- array(NA_real_, dim = c(n_draw, horizon, k))
  last <- Y[(nrow(Y) - lags + 1):nrow(Y), , drop = FALSE]   # oldest .. newest

  for (i in seq_len(n_draw)) {
    B <- beta[i, , ]
    C <- tryCatch(chol(sigma[i, , ]), error = function(e) NULL)
    if (is.null(C)) next          # skip a non-PD draw rather than fail the run
    hist <- last
    for (h in seq_len(horizon)) {
      # Regressor row: intercept, then lag 1 .. lag N (most recent lag first).
      x <- c(1, as.numeric(t(hist[rev(seq_len(lags)), , drop = FALSE])))
      y <- as.numeric(x %*% B) + as.numeric(stats::rnorm(k) %*% C)
      out[i, h, ] <- y
      hist <- rbind(hist[-1, , drop = FALSE], y)
    }
  }
  out
}

# One variable's draws out of a draws x horizon x variable array, as a long
# tibble. The rep()/as.numeric() pairing relies on R filling the draw x horizon
# matrix column-major, which holds for any single slice.
bvar_draws_long <- function(fcast, var_index, horizon) {
  d <- fcast[, , var_index]
  tibble::tibble(
    draw    = rep(seq_len(nrow(d)), times = horizon),
    horizon = rep(seq_len(horizon), each = nrow(d)),
    value   = as.numeric(d)
  )
}

# Collapse draws to the fixed quantile bands, dated forward from the origin.
# Quantiles are a frozen band definition per CLAUDE.md — changing them breaks
# cross-vintage comparison, so they are passed in from the module's constant.
bvar_bands <- function(draws_long, origin_date, quantiles) {
  draws_long |>
    dplyr::group_by(.data$horizon) |>
    dplyr::reframe(quantile = quantiles,
                   value = stats::quantile(.data$value, quantiles)) |>
    dplyr::mutate(
      origin_date   = origin_date,
      forecast_date = lubridate::`%m+%`(origin_date, months(.data$horizon))
    )
}
