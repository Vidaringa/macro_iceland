# A3 — Yield curves: nominal, real, and breakeven inflation ----
#
# Fits a Nelson-Siegel term structure to the nominal (RIKB) and indexed (RIKS)
# government bonds each day, and takes their difference as the breakeven-inflation
# curve. The breakeven is the headline output, not a byproduct: it is the market's
# priced inflation expectation and nothing else published in Iceland shows it as a
# term structure.
#
# Sourced by run_models.R (provides `con`; tidyverse attached; DB helpers sourced).
# Target tables (upsert):
#   curve_params    (date, curve, parameter)          — b0/b1/b2/lambda per fit
#   curve_points    (date, curve, maturity, yield)    — the fitted grid, incl. breakeven
#   curve_residuals (date, orderbookid)               — per-bond rich/cheap, feeds A5
#
# MODEL CHOICE: Nelson-Siegel, not Svensson. Svensson's six parameters against
# seven usable nominal bonds (and five real) leaves one degree of freedom, which
# is not a fit. NS has four and leaves three. With this few bonds the honest
# ceiling is a three-factor curve.
#
# LAMBDA IS FIXED, not re-estimated daily. Grid-searching it per day lowers that
# day's RSS but makes the curve jitter: over the current sample the free lambda
# moves with sd 1.4 (nominal) and 2.5 (real), and that instability propagates into
# the level factor (sd 0.17 vs 0.11 when fixed). A curve whose shape parameter
# wanders is useless for comparing one day to the next, which is the whole point
# of storing a daily series. The values below are the best FIXED lambda over the
# sample, rounded — and, like the other fixed-once conventions in this repo, they
# must not be re-tuned casually.
#
# SHORT-END EXCLUSION: bonds inside MIN_TAU are dropped. A bond weeks from
# redemption trades on its own idiosyncratic supply, not the curve: RIKB 26 1015
# at 0.07y quoted 9.04% while the fitted curve said 8.55%, and its yield had
# drifted 8.61 -> 9.04 over a fortnight as it pulled to par. Including it took the
# nominal RMSE from 2.2bp to 21.6bp while moving the 5y and 10y points by under
# 2bp — all noise, no information.
#
# T-BILLS ARE NOT USED as a short-end anchor, despite SPEC A3 proposing it. The
# tbill_auctions table holds AUCTION results on auction dates (13 rows, most
# recent 2026-09-16), not daily marks. Splicing a two-day-old auction print into a
# daily curve fit added 5bp of RMSE and pulled the 1y point around by 12bp.
# Revisit if a daily T-bill mark ever becomes available.

MODEL_VERSION <- "A3-v1"
CURVE_LAMBDA  <- c(nominal = 2.0, real = 3.0)  # fixed-once; see above
MIN_TAU       <- 0.25                          # years; exclude near-redemption stubs
MIN_BONDS     <- 4L                            # NS needs 4+ points to be identified
CURVE_GRID    <- c(0.25, 0.5, 1, 2, 3, 4, 5, 7, 10, 15, 20, 25, 30)

# Nelson-Siegel spot rate. `lambda` in years sets where the curvature hump sits.
ns_yield <- function(tau, b0, b1, b2, lambda) {
  x <- tau / lambda
  f <- (1 - exp(-x)) / x
  b0 + b1 * f + b2 * (f - exp(-x))
}

# Conditional on lambda the model is linear in the three factors, so the fit is a
# least-squares solve rather than an optimiser — fast, and it cannot fail to
# converge, which matters for something running unattended every day.
ns_fit <- function(tau, y, lambda) {
  x <- tau / lambda
  f <- (1 - exp(-x)) / x
  X <- cbind(1, f, f - exp(-x))
  cf <- tryCatch(stats::lm.fit(X, y)$coefficients, error = function(e) NULL)
  if (is.null(cf) || anyNA(cf)) return(NULL)
  list(b0 = cf[1], b1 = cf[2], b2 = cf[3],
       fitted = as.numeric(X %*% cf), resid = y - as.numeric(X %*% cf))
}

# 1.0.0 PULL ----
# Live trading days only: the scrape runs seven days a week and re-stores the last
# close on days the market was shut, so weekends and holidays appear as duplicate
# cross-sections. A stale day would otherwise enter the curve history as if it
# were a real observation.
curve_bonds <- DBI::dbGetQuery(con, "
  WITH d AS (
    SELECT date, string_agg(bond_code || ':' || kaup || '/' || krafa, ','
                            ORDER BY bond_code) AS sig
    FROM bonds_daily GROUP BY date),
  live AS (
    SELECT date FROM (
      SELECT date, sig, lag(sig) OVER (ORDER BY date) AS prev FROM d) t
    WHERE prev IS NULL OR sig <> prev)
  SELECT b.date, b.orderbookid, b.bond_code, b.krafa AS yield
  FROM bonds_daily b JOIN live USING (date)
  WHERE EXTRACT(ISODOW FROM b.date) <= 5 AND b.krafa IS NOT NULL
  ORDER BY b.date, b.orderbookid") |> tibble::as_tibble()

curve_attrs <- DBI::dbGetQuery(con, "
  SELECT orderbookid,
         bool_or(value_raw = 'Já') FILTER (WHERE attribute = 'indexed') AS indexed,
         max(value_date) FILTER (WHERE attribute = 'maturity_date') AS maturity
  FROM bond_attributes GROUP BY orderbookid") |> tibble::as_tibble()

# 2.0.0 ASSEMBLE ----
curve_panel <- curve_bonds |>
  dplyr::inner_join(curve_attrs, by = "orderbookid") |>
  dplyr::filter(!is.na(.data$indexed), !is.na(.data$maturity)) |>
  dplyr::mutate(
    tau   = as.numeric(.data$maturity - .data$date) / 365.25,
    curve = ifelse(.data$indexed, "real", "nominal")) |>
  dplyr::filter(.data$tau >= MIN_TAU)

# 3.0.0 FIT ----
# One fit per (date, curve). A day with too few bonds is skipped rather than fitted
# badly — the ragged edge is logged-missing, not forced.
curve_fits <- curve_panel |>
  dplyr::group_by(.data$date, .data$curve) |>
  dplyr::group_split() |>
  purrr::map(function(g) {
    if (nrow(g) < MIN_BONDS) return(NULL)
    lam <- CURVE_LAMBDA[[g$curve[1]]]
    f <- ns_fit(g$tau, g$yield, lam)
    if (is.null(f)) return(NULL)
    list(
      date = g$date[1], curve = g$curve[1], lambda = lam,
      b0 = f$b0, b1 = f$b1, b2 = f$b2,
      tau_min = min(g$tau), tau_max = max(g$tau), n_bonds = nrow(g),
      resid = tibble::tibble(
        date = g$date, curve = g$curve, orderbookid = g$orderbookid,
        bond_code = g$bond_code, tau = g$tau, yield = g$yield,
        fitted = f$fitted, residual = f$resid)
    )
  }) |>
  purrr::compact()

# 4.0.0 DERIVE ----
curve_params_tbl <- purrr::map_dfr(curve_fits, function(f) {
  tibble::tibble(
    date = f$date, curve = f$curve,
    parameter = c("b0", "b1", "b2", "lambda", "n_bonds", "tau_min", "tau_max"),
    value = c(f$b0, f$b1, f$b2, f$lambda, f$n_bonds, f$tau_min, f$tau_max))
})

# The fitted grid. Points SHORTER than that day's shortest bond are dropped: the
# real curve's nearest observation is three years out, and extrapolating a
# Nelson-Siegel below its data is where the shape is least constrained — at one
# year the fitted real yield swings from 0.9% to 4.6% depending only on lambda.
# Publishing a number there would be inventing it.
curve_points_tbl <- purrr::map_dfr(curve_fits, function(f) {
  g <- CURVE_GRID[CURVE_GRID >= f$tau_min & CURVE_GRID <= f$tau_max]
  if (!length(g)) return(NULL)
  tibble::tibble(
    date = f$date, curve = f$curve, maturity = g,
    yield = ns_yield(g, f$b0, f$b1, f$b2, f$lambda))
})

# Breakeven inflation = nominal minus real, on the maturities where BOTH curves
# are observed rather than extrapolated. This is the module's headline output.
curve_breakeven_tbl <- curve_points_tbl |>
  tidyr::pivot_wider(names_from = "curve", values_from = "yield") |>
  dplyr::filter(!is.na(.data$nominal), !is.na(.data$real)) |>
  dplyr::transmute(date = .data$date, curve = "breakeven",
                   maturity = .data$maturity,
                   yield = .data$nominal - .data$real)

curve_points_all <- dplyr::bind_rows(curve_points_tbl, curve_breakeven_tbl) |>
  dplyr::arrange(.data$date, .data$curve, .data$maturity)

# Per-bond residual: positive means the bond yields MORE than the curve says, i.e.
# it is cheap. Consumed by A5 (relative value) when that lands.
curve_resid_tbl <- purrr::map_dfr(curve_fits, "resid")

# 5.0.0 WRITE ----
curve_now <- Sys.time()

db_ensure_table(con, "curve_params",
                cols = c(date = "DATE", curve = "TEXT", parameter = "TEXT",
                         value = "DOUBLE PRECISION", model_version = "TEXT",
                         computed_at = "TIMESTAMPTZ"),
                pk = c("date", "curve", "parameter"))
db_upsert(con, "curve_params",
          dplyr::mutate(curve_params_tbl, model_version = MODEL_VERSION,
                        computed_at = curve_now),
          conflict_cols = c("date", "curve", "parameter"))

db_ensure_table(con, "curve_points",
                cols = c(date = "DATE", curve = "TEXT",
                         maturity = "DOUBLE PRECISION", yield = "DOUBLE PRECISION",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("date", "curve", "maturity"))
db_upsert(con, "curve_points",
          dplyr::mutate(curve_points_all, model_version = MODEL_VERSION,
                        computed_at = curve_now),
          conflict_cols = c("date", "curve", "maturity"))

db_ensure_table(con, "curve_residuals",
                cols = c(date = "DATE", curve = "TEXT", orderbookid = "TEXT",
                         bond_code = "TEXT", tau = "DOUBLE PRECISION",
                         yield = "DOUBLE PRECISION", fitted = "DOUBLE PRECISION",
                         residual = "DOUBLE PRECISION", model_version = "TEXT",
                         computed_at = "TIMESTAMPTZ"),
                pk = c("date", "orderbookid"))
db_upsert(con, "curve_residuals",
          dplyr::mutate(curve_resid_tbl, model_version = MODEL_VERSION,
                        computed_at = curve_now),
          conflict_cols = c("date", "orderbookid"))
