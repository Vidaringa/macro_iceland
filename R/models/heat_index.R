# A1 — Heat index (coincident state of the economy) ----
#
# A dynamic factor model (DFM) + Kalman filter extracts a coincident factor from
# the mixed-frequency real-activity series (SPEC A1). TWO factors are estimated and
# combined (variance-weighted): a high-frequency activity factor and a more
# persistent confidence/financial-cycle factor, so the index reads BOTH a sharp
# real shock (COVID) and a persistent crisis (the GFC). Higher = hotter. The factor,
# a group decomposition, and the per-indicator standardised inputs are upserted to
# Postgres for the app to read.
#
# Sourced by run_models.R (provides `con`; tidyverse + dfms attached; DB helpers
# sourced). Target tables (date-keyed, upsert): heatindex_level,
# heatindex_contributions, heatindex_inputs_filtered, and heatindex_standardisation
# (series-keyed, frozen z-score / factor-norm params — insert-if-absent).
#
# Mixed frequency: dfms::DFM handles quarterly series natively via `quarterly.vars`
# (Mariano-Murasawa state augmentation) — name them, place them to the RIGHT of the
# monthly columns, observe them every 3rd month. The Banbura-Modugno EM (auto-
# selected when the panel has NAs) accounts for the ragged edge directly; a series
# that didn't update is just NA at the tail and the filter returns the optimal
# estimate. dfms drops fully-NA leading rows and records them in fit$rm.rows.
#
# Fixed-once conventions (cross-vintage comparability, SPEC / CLAUDE.md): the
# standardisation window and the factor normalisation are computed ONCE over a fixed
# reference window and frozen in heatindex_standardisation; later runs read and reuse
# them, so the index level is comparable across vintages.

MODEL_VERSION <- "A1-v3"
STD_REF_START <- as.Date("2010-01-01")   # post-GFC, pre-COVID reference decade:
STD_REF_END   <- as.Date("2019-12-31")   # extremes excluded so they don't inflate the scale
WINSOR_MAD    <- 4                        # clip standardised inputs to +/-4 robust-SD for the FIT
N_FACTORS     <- 2L                       # activity factor + persistent confidence/financial factor
FULL_PANEL_FROM <- as.Date("2004-01-01")  # before this only a handful of series exist; from 2004 the
                                          # deep-history block (confidence, house prices, FX, card,
                                          # labour, residential investment) is present and the GFC is
                                          # genuinely observable. Pre-2004 is flagged low-confidence.

# A1-v3 rework: two factors (variance-weighted) so a persistent crisis (GFC) and a sharp
# real shock (COVID) both register. Added Gallup consumer confidence (level) — the keystone
# crisis signal that collapsed ~85% in 2008 — plus deep-history house prices and residential
# investment. With these the GFC reads ~-3.9 and COVID ~-1.8 (both severe, GFC the worse).
# v2 -> v3 history: v2 introduced robust standardisation (median/MAD, not mean/SD) so a single
# synchronised shock doesn't dominate the scale, winsorised fit inputs, and FX depreciation.
# The frozen-params meaning is unchanged from v2 (median/MAD); MODEL_VERSION bumps so the
# __FACTOR__ normalisation re-baselines for the new two-factor combination (see 6.0.0).

# 1.0.0 REGISTRY ----
# Single source of truth for which series enter the model, how each is made
# stationary, its decomposition group, sign (oriented so higher = hotter), and
# frequency. Adding a future indicator (house prices, confidence, passengers, car
# regs) is a one-row change. Series codes are pinned to the live DB. national-
# accounts GDP is intentionally held OUT (validation anchor only, see checks);
# DOMESTIC_DEMAND_real is the quarterly input so one series doesn't dominate.
#
# transform: yoy_log  = log(x) - log(x lag 12)   (trend + NSA seasonality killer)
#            qoq_log   = log(x) - log(x lag 1)    (quarterly real level -> growth)
#            yoy_diff  = x - x lag 12             (for series already in %, e.g. rates)
#            level     = x                        (already a cycle reading, e.g. a
#                                                  confidence index — no differencing)
# `daily` flags a series stored at daily frequency (fx_daily) that must be reduced to
# month-end before transforming.
indicator_spec <- tibble::tribble(
  ~table,                     ~series,                            ~group,        ~transform, ~sign, ~freq, ~daily,
  "card_turnover",            "CARD_TURNOVER_HH_DOMESTIC",        "consumption", "yoy_log",   1,    "M",   FALSE,
  "card_turnover",            "TOURIST_CONSUMPTION",              "external",    "yoy_log",   1,    "M",   FALSE,
  "vat_turnover",             "VAT_TURNOVER_TOTAL",               "consumption", "yoy_log",   1,    "M",   FALSE,
  "trade_imports",            "CONSUMER_IMPORTS",                 "consumption", "yoy_log",   1,    "M",   FALSE,
  "trade_imports",            "INVEST_IMPORTS_EX_SHIPS_AIRCRAFT", "consumption", "yoy_log",   1,    "M",   FALSE,
  "bank_new_mortgages",       "BANK_NEW_MORTGAGE_HH_TOTAL",       "housing",     "yoy_log",   1,    "M",   FALSE,
  "bank_loans_sector",        "BANK_LOANS_CORPORATES",            "housing",     "yoy_log",   1,    "M",   FALSE,
  # deep-history housing signals (from 2000 / 1995) — the GFC housing crash, which
  # the late-starting trade/VAT series miss entirely (added from thjodhagslikan).
  "house_prices",             "HOUSE_PRICE_INDEX",                "housing",     "yoy_log",   1,    "M",   FALSE,
  "residential_investment",   "RESIDENTIAL_INVESTMENT",           "housing",     "qoq_log",   1,    "Q",   FALSE,
  "hotel_nights",             "HOTEL_NIGHTS",                     "external",    "yoy_log",   1,    "M",   FALSE,
  "exports_marine_aluminium", "MARINE_EXPORT_VALUE",              "external",    "yoy_log",   1,    "M",   FALSE,
  "exports_marine_aluminium", "ALUMINIUM_EXPORT_TONS",            "external",    "yoy_log",   1,    "M",   FALSE,
  "lfs",                      "LFS_EMPLOYED",                     "labour",      "yoy_log",   1,    "M",   FALSE,
  "lfs",                      "LFS_HOURS",                        "labour",      "yoy_log",   1,    "M",   FALSE,
  "lfs",                      "LFS_UNEMPLOYMENT",                 "labour",      "yoy_diff", -1,    "M",   FALSE,
  "company_registrations",    "NEW_REGISTRATIONS",                "sentiment",   "yoy_log",   1,    "M",   FALSE,
  "company_registrations",    "BANKRUPTCIES",                     "sentiment",   "yoy_log",  -1,    "M",   FALSE,
  # Gallup household confidence enters as a LEVEL (the index is already a cycle/
  # balance reading, not a flow) — the persistent crisis signal that anchors the
  # confidence/financial factor and lets the GFC read at full force.
  "consumer_confidence",      "CONSUMER_CONFIDENCE",              "sentiment",   "level",     1,    "M",   FALSE,
  # FX trade-weighted index: depreciation (TWI up) = financial stress, so yoy_log with sign -1.
  # The deepest GFC signal we have (ISK fell ~50% in 2008); daily, reduced to month-end.
  "fx_daily",                 "TWI",                              "financial",   "yoy_log",  -1,    "M",   TRUE,
  "national_accounts",        "DOMESTIC_DEMAND_real",             "consumption", "qoq_log",   1,    "Q",   FALSE
)

# 2.0.0 PULL ----
# One collect() per input table; bind long. A registry series absent from the DB
# is simply not returned and drops out below (ragged-edge-by-design at the
# indicator level too). Daily series (fx_daily) are reduced to the month-end value
# before entering the monthly frame.
daily_series <- indicator_spec$series[indicator_spec$daily]

heatindex_raw <- indicator_spec |>
  dplyr::distinct(table) |>
  dplyr::pull(table) |>
  purrr::map(function(.tab) {
    wanted <- indicator_spec$series[indicator_spec$table == .tab]
    dplyr::tbl(con, .tab) |>
      dplyr::filter(series %in% wanted) |>
      dplyr::select(date, series, value) |>
      dplyr::collect()
  }) |>
  purrr::list_rbind() |>
  dplyr::mutate(m = lubridate::floor_date(date, "month")) |>
  # for daily series keep the last (month-end) observation per month; monthly series
  # already have one row per month
  dplyr::group_by(series, m) |>
  dplyr::filter(!(series %in% daily_series) | date == max(date)) |>
  dplyr::ungroup() |>
  dplyr::transmute(date = m, series, value)

# 3.0.0 TRANSFORM + STANDARDISE ----
# Per-series stationarity transform (by registry), oriented by sign, then ROBUST-
# standardised (centre = median, scale = MAD) with params FROZEN over the fixed
# reference window. Robust stats so one synchronised shock (COVID) does not blow up
# the scale and flatten every other event. log1p guards sparse counts against log(0).
heatindex_trans <- heatindex_raw |>
  dplyr::left_join(dplyr::select(indicator_spec, series, group, transform, sign, freq),
                   by = "series") |>
  dplyr::arrange(series, date) |>
  dplyr::group_by(series) |>
  dplyr::mutate(
    .l = dplyr::if_else(transform %in% c("yoy_diff", "level"), value,
                        log1p(pmax(value, 0))),
    x  = dplyr::case_when(
      transform == "yoy_log"  ~ .l - dplyr::lag(.l, 12),
      transform == "qoq_log"  ~ .l - dplyr::lag(.l, 1),
      transform == "yoy_diff" ~ value - dplyr::lag(value, 12),
      transform == "level"    ~ value
    ) * sign
  ) |>
  dplyr::ungroup() |>
  dplyr::filter(is.finite(x)) |>
  dplyr::select(date, series, group, x)

# Freeze (or read) standardisation params, version-aware: insert-if-absent so a
# re-run never recomputes existing params (the fixed-window guarantee), but params
# from a different model_version (e.g. the v1 mean/sd params) are re-baselined.
# `mu` holds the median and `sigma` the MAD under v2. heatindex_standardisation
# also holds the reserved __FACTOR__ row (written in 6.0.0).
db_ensure_table(con, "heatindex_standardisation",
                cols = c(series = "TEXT", transform = "TEXT",
                         mu = "DOUBLE PRECISION", sigma = "DOUBLE PRECISION",
                         sign = "INTEGER", ref_start = "DATE", ref_end = "DATE",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("series"))
# add model_version to a pre-v2 table if missing, then drop any non-v2 params so
# they re-baseline under the robust definition.
if (!"model_version" %in% DBI::dbListFields(con, "heatindex_standardisation")) {
  DBI::dbExecute(con, "ALTER TABLE heatindex_standardisation ADD COLUMN model_version TEXT")
}
DBI::dbExecute(con, "DELETE FROM heatindex_standardisation WHERE model_version IS DISTINCT FROM $1",
               params = list(MODEL_VERSION))

std_existing <- dplyr::tbl(con, "heatindex_standardisation") |>
  dplyr::filter(series != "__FACTOR__") |>
  dplyr::select(series, mu, sigma) |>
  dplyr::collect()

std_new <- heatindex_trans |>
  dplyr::filter(!series %in% std_existing$series,
                date >= STD_REF_START, date <= STD_REF_END) |>
  dplyr::group_by(series) |>
  dplyr::summarise(mu = stats::median(x), sigma = stats::mad(x), .groups = "drop") |>
  dplyr::left_join(dplyr::select(indicator_spec, series, transform, sign), by = "series") |>
  dplyr::transmute(series, transform, mu, sigma, sign,
                   ref_start = STD_REF_START, ref_end = STD_REF_END,
                   model_version = MODEL_VERSION, computed_at = Sys.time())
db_upsert(con, "heatindex_standardisation", std_new, conflict_cols = c("series"))

std_params <- dplyr::bind_rows(std_existing, dplyr::select(std_new, series, mu, sigma))

heatindex_std <- heatindex_trans |>
  dplyr::inner_join(std_params, by = "series") |>
  dplyr::mutate(value_std = (x - mu) / sigma) |>
  dplyr::select(date, series, group, value_std)

# 4.0.0 SPINE + RESHAPE ----
# Common monthly spine; complete() makes gaps/tails explicit NA. Quarterly growth
# already sits on quarter-end months (NA between) from the lag-1 transform — no
# interpolation. Monthly columns first, quarterly last (dfms requirement).
spine <- tibble::tibble(
  date = seq(min(heatindex_std$date), max(heatindex_std$date), by = "month")
)
q_series <- indicator_spec$series[indicator_spec$freq == "Q"]
m_series <- setdiff(intersect(indicator_spec$series, heatindex_std$series), q_series)
ordered_series <- c(intersect(m_series, unique(heatindex_std$series)),
                    intersect(q_series, unique(heatindex_std$series)))

wide <- heatindex_std |>
  dplyr::select(date, series, value_std) |>
  tidyr::pivot_wider(names_from = series, values_from = value_std) |>
  dplyr::right_join(spine, by = "date") |>
  dplyr::arrange(date) |>
  dplyr::select(date, dplyr::all_of(ordered_series))

# Winsorise the standardised inputs to +/-WINSOR_MAD before the fit so a violent
# synchronised shock (COVID) informs the loadings without driving them. The
# un-winsorised `wide` is kept for the decomposition (7.0.0) so contributions
# reflect the true signal.
X_mat <- as.matrix(dplyr::select(wide, -date))
X_fit <- pmax(pmin(X_mat, WINSOR_MAD), -WINSOR_MAD)

# 5.0.0 FIT ----
# Two factors, VAR(2) dynamics; quarterly vars handled natively; BM EM via "auto"
# (panel has NAs). The factors separate into a high-frequency activity factor and a
# more persistent confidence/financial-cycle factor; combining them lets the index
# read both a sharp real shock (COVID, activity factor) and a persistent crisis
# (GFC, confidence factor). Each factor is oriented to rise with employment, then
# combined by its share of explained variance into one `factor_raw` series. The
# combined per-series loading (w1*C1 + w2*C2) keeps the 7.0.0 decomposition additive.
fit <- dfms::DFM(X_fit, r = N_FACTORS, p = 2,
                 quarterly.vars = intersect(q_series, ordered_series),
                 em.method = "auto", pos.corr = TRUE)

kept_dates <- if (length(fit$rm.rows)) wide$date[-fit$rm.rows] else wide$date

# Orient each factor to employment (a clean hot/cold anchor), so a higher factor
# means a hotter economy before they are combined.
emp_std <- heatindex_std |>
  dplyr::filter(series == "LFS_EMPLOYED") |>
  dplyr::select(date, emp = value_std)
F_mat   <- as.matrix(fit$F_qml)[, seq_len(N_FACTORS), drop = FALSE]
C_mat   <- as.matrix(fit$C)[, seq_len(N_FACTORS), drop = FALSE]
emp_vec <- emp_std$emp[match(kept_dates, emp_std$date)]
factor_signs <- vapply(seq_len(N_FACTORS), function(k) {
  s <- sign(stats::cor(F_mat[, k], emp_vec, use = "complete.obs"))
  if (!is.finite(s) || s == 0) 1 else s
}, numeric(1))
F_mat <- sweep(F_mat, 2, factor_signs, `*`)
C_mat <- sweep(C_mat, 2, factor_signs, `*`)

# Combine by share of explained variance (leading eigenvalues from the PCA init).
factor_weights <- fit$eigen$values[seq_len(N_FACTORS)]
factor_weights <- factor_weights / sum(factor_weights)
factor_raw <- as.numeric(F_mat %*% factor_weights)
# Effective loading of each series on the combined factor (for the decomposition).
combined_loading <- as.numeric(C_mat %*% factor_weights)

# 6.0.0 NORMALISE ----
# Pin the combined factor's scale ROBUSTLY (median/MAD) over the SAME fixed
# reference window, frozen in heatindex_standardisation under __FACTOR__ so the
# index level is stable across vintages. The factors were already oriented to
# employment in 5.0.0, so the combined factor rises with the economy (sign +1);
# the stored sign is a guard. index = robust z; index100 = 50 + 10*index.
factor_tbl <- tibble::tibble(date = kept_dates, factor_raw = factor_raw)

factor_params <- dplyr::tbl(con, "heatindex_standardisation") |>
  dplyr::filter(series == "__FACTOR__") |>
  dplyr::collect()

if (nrow(factor_params) == 0) {
  ref <- dplyr::filter(factor_tbl, date >= STD_REF_START, date <= STD_REF_END)
  mu_f <- stats::median(ref$factor_raw); sigma_f <- stats::mad(ref$factor_raw)
  sign_f <- 1L  # combined factor already oriented to employment in 5.0.0
  db_upsert(con, "heatindex_standardisation",
            tibble::tibble(series = "__FACTOR__", transform = MODEL_VERSION,
                           mu = mu_f, sigma = sigma_f, sign = as.integer(sign_f),
                           ref_start = STD_REF_START, ref_end = STD_REF_END,
                           model_version = MODEL_VERSION, computed_at = Sys.time()),
            conflict_cols = c("series"))
} else {
  mu_f <- factor_params$mu; sigma_f <- factor_params$sigma; sign_f <- factor_params$sign
}

factor_tbl <- factor_tbl |>
  dplyr::mutate(index = sign_f * (factor_raw - mu_f) / sigma_f,
                index100 = 50 + 10 * index)

# 7.0.0 DECOMPOSE ----
# Additive loadings x standardised-inputs attribution. Each indicator's raw signal
# is sign_f * loading_i * value_std_i (0 where unobserved) — its oriented share of
# the common factor. The raw shares sum to an approximation of the factor, not to
# `index` exactly (F_qml is the smoothed state, not a pure contemporaneous linear
# combination), so they are rescaled PER DATE to sum exactly to `index`. This makes
# the decomposition exactly additive (the standard explainability layer for a
# coincident index), honestly a linear approximation of the factor rather than a
# structural variance decomposition. Banbura-Modugno news decomposition
# (contribution_change) is a v1.1 add via dfms::news().
loadings <- tibble::tibble(series = ordered_series,
                           loading = combined_loading)

inputs_filtered <- wide |>
  dplyr::filter(date %in% kept_dates) |>
  tidyr::pivot_longer(-date, names_to = "series", values_to = "value_std") |>
  dplyr::left_join(loadings, by = "series") |>
  dplyr::left_join(dplyr::distinct(indicator_spec, series, group), by = "series") |>
  dplyr::mutate(
    observed = !is.na(value_std),
    raw      = sign_f * loading * dplyr::coalesce(value_std, 0)
  ) |>
  # rescale each date's raw shares so they sum exactly to that date's index level
  dplyr::left_join(dplyr::select(factor_tbl, date, index), by = "date") |>
  dplyr::group_by(date) |>
  dplyr::mutate(
    .raw_sum     = sum(raw),
    contribution = dplyr::if_else(.raw_sum == 0, 0, raw * index / .raw_sum)
  ) |>
  dplyr::ungroup() |>
  dplyr::select(date, series, group, value_std, loading, contribution, observed)

contributions <- inputs_filtered |>
  dplyr::group_by(date, group) |>
  dplyr::summarise(contribution = sum(contribution), .groups = "drop")

# 8.0.0 WRITE ----
now <- Sys.time()

# Per-date count of observed indicators — drives the low-confidence flag. Before
# FULL_PANEL_FROM the panel is thin (most trade/VAT/mortgage series start 2013-2016),
# so the index there is a sparse-data estimate, not a confident read; the GFC in
# particular is only partially observable. `low_confidence` lets the app grey it.
obs_share <- inputs_filtered |>
  dplyr::group_by(date) |>
  dplyr::summarise(n_observed = sum(observed),
                   n_total = dplyr::n(), .groups = "drop")

# heatindex_level — headline series. F_qml is the QML (smoothed) estimate; flagged
# `smoothed`. (A `filtered` real-time variant can be added later from fit$F_2s.)
# v2 adds n_observed/n_total/low_confidence columns; if an older table without them
# exists, drop it so db_ensure_table recreates it with the current schema.
if (DBI::dbExistsTable(con, "heatindex_level") &&
    !"low_confidence" %in% DBI::dbListFields(con, "heatindex_level")) {
  DBI::dbRemoveTable(con, "heatindex_level")
}
heatindex_level_tbl <- factor_tbl |>
  dplyr::left_join(obs_share, by = "date") |>
  dplyr::transmute(date, estimate_kind = "smoothed",
                   index, index100, factor_raw,
                   n_observed, n_total,
                   low_confidence = date < FULL_PANEL_FROM,
                   model_version = MODEL_VERSION, computed_at = now)
db_ensure_table(con, "heatindex_level",
                cols = c(date = "DATE", estimate_kind = "TEXT",
                         index = "DOUBLE PRECISION", index100 = "DOUBLE PRECISION",
                         factor_raw = "DOUBLE PRECISION",
                         n_observed = "INTEGER", n_total = "INTEGER",
                         low_confidence = "BOOLEAN", model_version = "TEXT",
                         computed_at = "TIMESTAMPTZ"),
                pk = c("date", "estimate_kind"))
db_upsert(con, "heatindex_level", heatindex_level_tbl,
          conflict_cols = c("date", "estimate_kind"))

heatindex_contributions_tbl <- contributions |>
  dplyr::transmute(date, group, contribution,
                   contribution_change = NA_real_,
                   model_version = MODEL_VERSION, computed_at = now)
db_ensure_table(con, "heatindex_contributions",
                cols = c(date = "DATE", group = "TEXT",
                         contribution = "DOUBLE PRECISION",
                         contribution_change = "DOUBLE PRECISION",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("date", "group"))
db_upsert(con, "heatindex_contributions", heatindex_contributions_tbl,
          conflict_cols = c("date", "group"))

heatindex_inputs_filtered_tbl <- inputs_filtered |>
  dplyr::transmute(date, series, group, value_std, loading, contribution, observed,
                   model_version = MODEL_VERSION, computed_at = now)
db_ensure_table(con, "heatindex_inputs_filtered",
                cols = c(date = "DATE", series = "TEXT", group = "TEXT",
                         value_std = "DOUBLE PRECISION", loading = "DOUBLE PRECISION",
                         contribution = "DOUBLE PRECISION", observed = "BOOLEAN",
                         model_version = "TEXT", computed_at = "TIMESTAMPTZ"),
                pk = c("date", "series"))
db_upsert(con, "heatindex_inputs_filtered", heatindex_inputs_filtered_tbl,
          conflict_cols = c("date", "series"))
