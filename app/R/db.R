# Data layer — every Postgres read in the app happens here ----
#
# No reactive ever touches the database. `data_refresh()` opens ONE connection,
# runs every reader, stores the resulting tibbles in the DATA environment,
# disconnects, and reschedules itself. Renders then read in-memory tibbles, so a
# page paints in milliseconds and a visitor never waits on a query — which is
# what keeps the app free of the start-up spinner.
#
# A reader that throws keeps its PREVIOUS tibble (the same warn-and-continue
# contract the ingest runners use): one unavailable table degrades one figure,
# it does not take the app down. At boot with the DB unreachable every reader is
# absent and the figures render their empty state; the next cycle fills them in.
#
# Cadence: the models finish ~17:30, so a 5-minute poll picks new data up within
# minutes of it landing, at a cost of ~16 small queries per cycle.

DATA <- new.env(parent = emptyenv())

# Each entry: function(con) -> tibble. Names are how pages address the data.
READERS <- list(

  # --- policy rate and corridor ---------------------------------------------
  policy = function(con) {
    DBI::dbGetQuery(con, "
      SELECT date, policy_rate AS value
      FROM rates_policy ORDER BY date") |> tibble::as_tibble()
  },

  corridor = function(con) {
    DBI::dbGetQuery(con, "
      SELECT date, series, value
      FROM rates_policy_components
      WHERE date >= '2015-01-01' ORDER BY date, series") |> tibble::as_tibble()
  },

  # --- A1 heat index ---------------------------------------------------------
  # `provisional` marks the ragged EDGE only: the most recent months, where a
  # release has not yet landed for most indicators, are drawn dashed and
  # annotated rather than presented as settled. The thin pre-2004 panel is a
  # different thing entirely and is already carried by `low_confidence`, so the
  # flag is restricted to the trailing run of under-observed months — otherwise
  # it would also light up the sparse late-1990s history.
  heat_level = function(con) {
    d <- DBI::dbGetQuery(con, "
      SELECT date, index, index100, n_observed, n_total, low_confidence,
             model_version, computed_at
      FROM heatindex_level
      WHERE estimate_kind = 'smoothed' ORDER BY date") |> tibble::as_tibble()
    thin <- d$n_observed < PROVISIONAL_SHARE * d$n_total
    # TRUE only from the last settled month onward.
    edge <- if (any(!thin)) seq_len(nrow(d)) > max(which(!thin)) else !logical(nrow(d))
    dplyr::mutate(d, provisional = thin & edge)
  },

  # "group" is a reserved word in SQL — it must stay quoted.
  heat_groups = function(con) {
    DBI::dbGetQuery(con, '
      SELECT date, "group" AS series, contribution AS value
      FROM heatindex_contributions ORDER BY date, "group"') |> tibble::as_tibble()
  },

  # Latest cross-section of indicators, plus when each was last actually
  # observed — so the table can show which series are stale at the edge.
  heat_inputs = function(con) {
    DBI::dbGetQuery(con, '
      SELECT i.series, i."group", i.value_std, i.loading, i.contribution,
             i.observed, o.last_observed
      FROM heatindex_inputs_filtered i
      LEFT JOIN (SELECT series, max(date) AS last_observed
                 FROM heatindex_inputs_filtered
                 WHERE observed GROUP BY series) o USING (series)
      WHERE i.date = (SELECT max(date) FROM heatindex_inputs_filtered)
      ORDER BY i."group", i.series') |> tibble::as_tibble()
  },

  # Quarterly; the forecast is monthly, so the history line is a step between
  # published quarters rather than an interpolation the model invented.
  output_gap = function(con) {
    DBI::dbGetQuery(con, "
      SELECT date, value FROM output_gap ORDER BY date") |> tibble::as_tibble()
  },

  heat_std = function(con) {
    DBI::dbGetQuery(con, "
      SELECT series, transform, mu, sigma, sign, ref_start, ref_end
      FROM heatindex_standardisation
      WHERE series <> '__FACTOR__' ORDER BY series") |> tibble::as_tibble()
  },

  # --- A2 policy-rate forecasts ---------------------------------------------
  # Each source has its OWN latest origin (the BVAR runs off the heat-index
  # month, the market path off the latest REIBOR month), so the join is per
  # source — never a single max(origin_date) across all of them.
  forecasts = function(con) {
    DBI::dbGetQuery(con, "
      SELECT f.source, f.origin_date, f.horizon, f.forecast_date,
             f.quantile, f.value, f.model_version, f.computed_at
      FROM forecast_policy_rate f
      JOIN (SELECT source, max(origin_date) AS origin_date
            FROM forecast_policy_rate GROUP BY source) m
        USING (source, origin_date)
      ORDER BY f.source, f.horizon, f.quantile") |> tibble::as_tibble()
  },

  # The same BVAR fit's density for every modelled variable, not just the policy
  # rate. Latest origin only — older vintages stay in the table but the app shows
  # the current one.
  forecast_macro = function(con) {
    DBI::dbGetQuery(con, "
      SELECT variable, origin_date, horizon, forecast_date, quantile, value,
             model_version, computed_at
      FROM forecast_macro
      WHERE origin_date = (SELECT max(origin_date) FROM forecast_macro)
      ORDER BY variable, horizon, quantile") |> tibble::as_tibble()
  },

  # The A6 ISK density. Its origin is its own — the TWI is daily, so this model
  # can run fresher than the heat-index-tied A2.
  forecast_fx = function(con) {
    DBI::dbGetQuery(con, "
      SELECT series, origin_date, horizon, forecast_date, quantile, value,
             model_version, computed_at
      FROM forecast_fx
      WHERE origin_date = (SELECT max(origin_date) FROM forecast_fx)
      ORDER BY series, horizon, quantile") |> tibble::as_tibble()
  },

  # --- rates, FX, prices -----------------------------------------------------
  external = function(con) {
    DBI::dbGetQuery(con, "
      SELECT date, series, value
      FROM rates_external
      WHERE date >= '2015-01-01' ORDER BY date, series") |> tibble::as_tibble()
  },

  reibor = function(con) {
    DBI::dbGetQuery(con, "
      SELECT date, tenor AS series, reibor AS value
      FROM rates_reibor
      WHERE date >= '2015-01-01' ORDER BY date, tenor") |> tibble::as_tibble()
  },

  fx = function(con) {
    DBI::dbGetQuery(con, "
      SELECT date, series, value FROM fx_daily ORDER BY date, series") |>
      tibble::as_tibble()
  },

  cpi = function(con) {
    DBI::dbGetQuery(con, "
      SELECT date, series, value
      FROM cpi WHERE date >= '2000-01-01' ORDER BY date, series") |>
      tibble::as_tibble()
  },

  # --- bonds -----------------------------------------------------------------
  # The scrape runs seven days a week and re-stores the last close on days the
  # market was shut, so the table holds weekend rows AND holiday copies
  # (17-18 June, 3 August 2026 are byte-identical to the preceding day). Both
  # are dropped here: a date survives only if its full cross-section differs
  # from the previous stored date, and only on weekdays. Fixing the ingest is a
  # separate task; this reader stays defensive regardless.
  bonds = function(con) {
    DBI::dbGetQuery(con, "
      WITH d AS (
        SELECT date, string_agg(bond_code || ':' || kaup || '/' || krafa, ','
                                ORDER BY bond_code) AS sig
        FROM bonds_daily GROUP BY date),
      live AS (
        SELECT date FROM (
          SELECT date, sig, lag(sig) OVER (ORDER BY date) AS prev FROM d) t
        WHERE prev IS NULL OR sig <> prev)
      SELECT b.date, b.bond_code, b.orderbookid, b.kaup AS price, b.krafa AS yield
      FROM bonds_daily b JOIN live USING (date)
      WHERE EXTRACT(ISODOW FROM b.date) <= 5
      ORDER BY b.date, b.bond_code") |> tibble::as_tibble()
  },

  # bond_attributes is a long key/value table; pivoting in SQL keeps the reader
  # a single round trip and the app free of reshaping logic.
  bond_attrs = function(con) {
    DBI::dbGetQuery(con, "
      SELECT orderbookid,
             max(value_raw)  FILTER (WHERE attribute = 'name')            AS bond_code,
             max(value_raw)  FILTER (WHERE attribute = 'isin')            AS isin,
             bool_or(value_raw = 'Já') FILTER (WHERE attribute = 'indexed') AS indexed,
             max(value_num)  FILTER (WHERE attribute = 'coupon_rate')     AS coupon,
             max(value_date) FILTER (WHERE attribute = 'issue_date')      AS issue_date,
             max(value_date) FILTER (WHERE attribute = 'maturity_date')   AS maturity,
             max(value_num)  FILTER (WHERE attribute = 'issued_nominal')  AS issued_nominal
      FROM bond_attributes GROUP BY orderbookid ORDER BY orderbookid") |>
      tibble::as_tibble()
  },

  tbills = function(con) {
    DBI::dbGetQuery(con, "
      SELECT date, series, yield, bid_to_cover, accepted_mkr
      FROM tbill_auctions ORDER BY date DESC, series") |> tibble::as_tibble()
  },

  # --- cycle strip -----------------------------------------------------------
  # Year-on-year rates computed in SQL. card_turnover is stored month-END while
  # everything else is month-START, so it is floored to the month here to keep
  # the panels on one time axis.
  cycle = function(con) {
    DBI::dbGetQuery(con, "
      SELECT series, date, value FROM (
        SELECT 'HOUSE_PRICE_YOY' AS series, date,
               100 * (value / lag(value, 12) OVER (ORDER BY date) - 1) AS value
        FROM house_prices WHERE series = 'HOUSE_PRICE_INDEX') a
      UNION ALL
      SELECT series, date, value FROM (
        SELECT 'CARD_YOY' AS series, date_trunc('month', date)::date AS date,
               100 * (value / lag(value, 12) OVER (ORDER BY date) - 1) AS value
        FROM card_turnover WHERE series = 'CARD_TURNOVER_HH_DOMESTIC') b
      UNION ALL
      SELECT series, date, value FROM (
        SELECT 'HOTEL_YOY' AS series, date,
               100 * (value / lag(value, 12) OVER (ORDER BY date) - 1) AS value
        FROM hotel_nights WHERE series = 'HOTEL_NIGHTS') c
      UNION ALL
      SELECT 'GDP_yoy', date, value FROM national_accounts WHERE series = 'GDP_yoy'
      UNION ALL
      SELECT 'CPI_change_A', date, value FROM cpi WHERE series = 'CPI_change_A'
      UNION ALL
      SELECT 'LFS_UNEMPLOYMENT', date, value FROM lfs WHERE series = 'LFS_UNEMPLOYMENT'
      ORDER BY series, date") |> tibble::as_tibble()
  },

  # --- provenance ------------------------------------------------------------
  # Every figure carries "data to" and models carry "computed". Both come from
  # here so a vintage shown on screen is always the vintage in the database.
  vintages = function(con) {
    DBI::dbGetQuery(con, "
      SELECT 'rates_policy' AS tbl, max(date) AS data_to FROM rates_policy
      UNION ALL SELECT 'rates_reibor', max(date) FROM rates_reibor
      UNION ALL SELECT 'fx_daily', max(date) FROM fx_daily
      UNION ALL SELECT 'rates_external', max(date) FROM rates_external
      UNION ALL SELECT 'cpi', max(date) FROM cpi
      UNION ALL SELECT 'tbill_auctions', max(date) FROM tbill_auctions
      UNION ALL SELECT 'heatindex_level', max(date) FROM heatindex_level
      UNION ALL SELECT 'forecast_policy_rate', max(origin_date) FROM forecast_policy_rate
      UNION ALL SELECT 'forecast_macro', max(origin_date) FROM forecast_macro
      UNION ALL SELECT 'forecast_fx', max(origin_date) FROM forecast_fx
      UNION ALL SELECT 'current_account', max(date) FROM current_account
      UNION ALL SELECT 'bonds_daily', max(date) FROM bonds_daily
                WHERE EXTRACT(ISODOW FROM date) <= 5") |> tibble::as_tibble()
  },

  models = function(con) {
    DBI::dbGetQuery(con, "
      SELECT 'heat' AS module, model_version, max(computed_at) AS computed_at
      FROM heatindex_level GROUP BY 1, 2
      UNION ALL
      SELECT source, model_version, max(computed_at)
      FROM forecast_policy_rate GROUP BY 1, 2
      UNION ALL
      SELECT 'isk', model_version, max(computed_at) FROM forecast_fx GROUP BY 1, 2")  |>
      tibble::as_tibble()
  }
)

# Refresh every dataset, then reschedule. Called once synchronously at start-up
# (before the port binds, so the first visitor already gets warm data) and
# thereafter by `later` between httpuv events on the single R thread.
data_refresh <- function() {
  con <- tryCatch(db_connect(), error = function(e) NULL)
  if (!is.null(con)) {
    on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
    failed <- character()
    for (nm in names(READERS)) {
      ok <- tryCatch({
        assign(nm, READERS[[nm]](con), envir = DATA)
        TRUE
      }, error = function(e) FALSE)
      if (!ok) failed <- c(failed, nm)
    }
    DATA$failed <- failed
    DATA$refreshed_at <- Sys.time()
  }
  later::later(data_refresh, REFRESH_SECONDS)
  invisible(NULL)
}

# Accessor used by every page: returns the cached tibble, or an empty tibble
# when a reader has never succeeded. Pages pass the result to validate(need())
# so a missing table renders the empty state instead of an error.
dat <- function(name) {
  if (exists(name, envir = DATA, inherits = FALSE)) get(name, envir = DATA) else tibble::tibble()
}

# Latest stored date for a table, formatted for a provenance line.
vintage_of <- function(tbl) {
  v <- dat("vintages")
  if (!nrow(v)) return(NA_character_)
  d <- v$data_to[match(tbl, v$tbl)]
  if (length(d) == 0 || is.na(d)) NA_character_ else format(as.Date(d), "%Y-%m-%d")
}

# Latest computed_at for a model module ("heat", "bvar", "market").
computed_of <- function(module) {
  m <- dat("models")
  if (!nrow(m)) return(NA_character_)
  d <- m$computed_at[match(module, m$module)]
  if (length(d) == 0 || is.na(d)) NA_character_ else format(as.Date(d), "%Y-%m-%d")
}
