# A2b — Inflation forecast (ARIMA on the deep CPI history) ----
#
# The published headline inflation forecast. Writes to `forecast_macro` as
# variable = "infl", source = "arima", alongside A2's own BVAR inflation path
# (source = "bvar"), which is NOT removed — see the note on the two paths below.
#
# WHY A SEPARATE MODEL FOR A VARIABLE A2 ALREADY FORECASTS. A2 is a joint BVAR
# fit to produce the POLICY RATE; its other five variables are byproducts. On
# inflation that byproduct is not competitive. Over 72 rolling origins
# (inflation_forecast_race.R), RMSE relative to a random walk:
#            h=1    h=3    h=6   h=12
#   arima   0.743  0.759  0.848  1.003
#   ets     0.973  0.945  0.922  0.977
#   bvar    1.175  1.327  1.297  1.207
# The BVAR loses to a random walk at EVERY horizon; ARIMA beats it by 25-43% at
# h=1-6 and clears Diebold-Mariano at h=1 (p=0.011), borderline at h=3 (p=0.052).
#
# WHY ARIMA WINS: the deep sample. It is fit on CPI back to 1989 (~450 months),
# where the BVAR is confined to 2009- because the heat index and the
# post-redenomination policy regime do not reach further back. That is not an
# unfair comparison, it is the reason — and section 6 of the race shows ARIMA on
# the SHORT sample still beats every BVAR, so the deep history is an addition to
# the win rather than the whole of it.
#
# NOTE ON h=12. ARIMA ties the random walk there (rel 1.003). The app must not
# claim skill at a year out on this model; the honest 12-month statement is "no
# better than today's rate carried forward".
#
# THE TWO INFLATION PATHS ARE BOTH PUBLISHED, ON PURPOSE. A2 is a JOINT system:
# its policy-rate path and its inflation path come out of one fit and are
# internally consistent with each other. Swapping this ARIMA path in as A2's
# input would break that link, and conditioning A2 on it does not help — measured
# at -1.3%/-8.9%/-5.3%/+10.9% on policy-rate RMSE at h=1/3/6/12, no horizon
# significant (conditional_inflation_check.R). So the site shows BOTH and labels
# them: this one as the inflation forecast, A2's as "the inflation path underlying
# the policy-rate forecast". The gap between them is information, not an error.
#
# Sourced by run_models.R (provides `con`; tidyverse attached; DB helpers
# sourced). The filename sorts BEFORE policy_rate_path.R, which is harmless —
# this module reads only `cpi` and shares no state with A2. Target table:
#   forecast_macro (origin_date, horizon, variable, quantile) — source = "arima"

MODEL_VERSION  <- "A2b-infl-v1"
INFL_HORIZON   <- 18L                              # matches A2's fan length
INFL_QUANTILES <- c(0.05, 0.16, 0.50, 0.84, 0.95)  # frozen band, as A2/A6

# 1.0.0 PULL ----
# YoY inflation is rebuilt from CPI_index rather than read from CPI_change_A so
# that the deep history and the modelled definition are guaranteed identical —
# the same construction inflation_forecast_race.R scores.
infl_cpi <- dplyr::tbl(con, "cpi") |>
  dplyr::filter(.data$series == "CPI_index") |>
  dplyr::select("date", "value") |>
  dplyr::collect() |>
  dplyr::transmute(date = lubridate::floor_date(.data$date, "month"),
                   cpi = .data$value) |>
  dplyr::arrange(.data$date) |>
  dplyr::mutate(infl = 100 * (.data$cpi / dplyr::lag(.data$cpi, 12) - 1)) |>
  dplyr::filter(is.finite(.data$infl))

infl_origin <- max(infl_cpi$date)
infl_now    <- Sys.time()

# 2.0.0 FIT + FORECAST ----
# auto.arima picks the order; the race scored exactly this call, so pinning an
# order here would publish a different model from the one that was measured.
infl_fit <- forecast::auto.arima(infl_cpi$infl)
infl_fc  <- forecast::forecast(infl_fit, h = INFL_HORIZON,
                               level = c(68, 90))

# The forecast object carries 68/90 intervals; the repo's frozen quantile set is
# 5/16/50/84/95, so the bands are rebuilt from the interval half-widths rather
# than re-derived from sigma — this keeps the published quantiles identical in
# definition to A2's and A6's.
infl_sd <- (as.numeric(infl_fc$upper[, 2]) - as.numeric(infl_fc$mean)) /
  stats::qnorm(0.95)

infl_tbl <- tidyr::expand_grid(horizon = seq_len(INFL_HORIZON),
                               quantile = INFL_QUANTILES) |>
  dplyr::mutate(
    value         = as.numeric(infl_fc$mean)[.data$horizon] +
      stats::qnorm(.data$quantile) * infl_sd[.data$horizon],
    variable      = "infl",
    source        = "arima",
    origin_date   = infl_origin,
    forecast_date = lubridate::`%m+%`(infl_origin, months(.data$horizon)),
    horizon       = as.integer(.data$horizon),
    model_version = MODEL_VERSION,
    computed_at   = infl_now) |>
  dplyr::select("origin_date", "horizon", "forecast_date", "variable", "source",
                "quantile", "value", "model_version", "computed_at")

# 3.0.0 WRITE ----
# forecast_macro is created by policy_rate_path.R with this exact shape;
# db_ensure_table is idempotent, so declaring it here too means this module does
# not depend on A2 having run first.
db_ensure_table(con, "forecast_macro",
                cols = c(origin_date = "DATE", horizon = "INTEGER",
                         forecast_date = "DATE", variable = "TEXT",
                         source = "TEXT", quantile = "DOUBLE PRECISION",
                         value = "DOUBLE PRECISION", model_version = "TEXT",
                         computed_at = "TIMESTAMPTZ"),
                pk = c("origin_date", "horizon", "variable", "quantile"))

# The PK does not include `source`, so this upsert would COLLIDE with A2's own
# infl rows at a shared origin and silently overwrite whichever ran last. Both
# paths must coexist, so the key is widened to include source. ALTER is skipped
# when the constraint already carries source (a re-run), and is safe on the
# existing table because (origin_date, horizon, variable, quantile) is unique
# within each source.
infl_pk <- DBI::dbGetQuery(con, "
  SELECT string_agg(a.attname, ',' ORDER BY k.ord) AS cols
  FROM pg_constraint c
  JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON TRUE
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
  WHERE c.conrelid = 'forecast_macro'::regclass AND c.contype = 'p'
  GROUP BY c.oid")$cols

if (length(infl_pk) == 1 && !grepl("source", infl_pk, fixed = TRUE)) {
  DBI::dbExecute(con, "ALTER TABLE forecast_macro DROP CONSTRAINT forecast_macro_pkey")
  DBI::dbExecute(con, "ALTER TABLE forecast_macro ADD PRIMARY KEY
                       (origin_date, horizon, variable, source, quantile)")
}

db_upsert(con, "forecast_macro", infl_tbl,
          conflict_cols = c("origin_date", "horizon", "variable", "source",
                            "quantile"))
