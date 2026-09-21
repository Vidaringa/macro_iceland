# CLAUDE.md — operating rules for this repo

Lean per-session rules and facts. Vision and architecture live in `PROJECT.md`;
the analytical spec (what each module computes) in `SPEC.md`; the data inventory
in `data_sources.md`; blocked sources in `UNRESOLVED_SOURCES.md`.

**Project vision and architecture: see `PROJECT.md`.**

---

## Stack rules (hard constraints)

- **R only**, tidyverse idioms throughout. No `data.table`, no base-R-isms where a
  tidyverse equivalent exists. `dplyr::`-qualify calls in scripts (matches existing code).
- **Postgres is the single source of truth.** Every ingest function and every model
  ends by upserting a cleaned tibble to a Postgres table. The Shiny app (not built
  yet) reads exclusively from Postgres.
- **No `.rds`/CSV data layer.** `.rds` is fine only as a transient cache inside one
  script run; never the handoff between layers, never committed. (`raw_data/*.csv` are
  one-time historical seeds, not a live data layer.)
- **No model code in the app; no app code in the models.** The three layers (ingest/
  models in R → Postgres → Shiny) communicate only through Postgres.
- **Pure Shiny** for the app: `tags$*` / `htmlTemplate()`, custom CSS/JS in `www/`. No
  `shinydashboard`/`bs4Dash`/`flexdashboard`. (bslib-vs-zero-Bootstrap: still TODO in
  `PROJECT.md §5` — not decided; no UI written yet.)

## Repo geography

```
R/
  db/db_helpers.R      db_connect() / db_ensure_table() / db_upsert() — the ONLY DB helpers; reuse, don't reinvent
  ingest/
    daily/  monthly/  quarterly/    one file per source: pull -> clean -> upsert against `con`
    ecb.R  hagstofa.R  sedlabanki.R shared pull helpers (SDMX / PX-Web / xmltimeseries + gagnabanki blob)
  seed/                one-time historical backfills
  models/              ANALYTICAL MODULES (A1-A7): read canonical series, compute, upsert model outputs
    checks/            manual verification scripts (run interactively; never schedule)
  run_daily.R  run_monthly.R  run_quarterly.R   ingest orchestrators
  run_models.R         model orchestrator (runs after ingest)
  schedule_tasks.R     registers Windows Scheduled Tasks (one per runner)
raw_data/              one-time seed CSVs only (not a live data layer)
```

## Commands

Run from the repo root (relative `source()` paths depend on it):

- Ingest: `Rscript R/run_daily.R` · `Rscript R/run_monthly.R` · `Rscript R/run_quarterly.R`
- Models: `Rscript R/run_models.R`
- Verify A1: `Rscript R/models/checks/heat_index_checks.R`
- (Re)register scheduled tasks: `Rscript R/schedule_tasks.R` (a system change — confirm first)

DB connection: `db_connect()` reads the standard libpq env vars (`PGHOST`, `PGPORT`,
`PGDATABASE`, `PGUSER`, `PGPASSWORD`) from the **repo** `.Renviron` (gitignored). The
HOME `.Renviron` points at a DIFFERENT database — never blanket-load it; lift only API
keys (e.g. `FRED_API_KEY`) from it if needed.

## Runner / module pattern

Each runner: attach libs → `source("R/db/db_helpers.R")` (+ shared helpers) → open ONE
`con` → loop `list.files(dir, "\\.R$") |> sort()`, each in `tryCatch(source(f, local=TRUE))`
(warn-and-continue) → disconnect → summarise failures. A sourced file assumes `con`
exists and ends with `db_ensure_table` + `db_upsert`. Use numbered `# x.0.0 SECTION ----`
headers.

## Model-output table convention (set by A1, follow for A2-A7)

`<module>_<object>`, tidy **long**, English snake_case, PK = `date` + any series/group
key. Created with `db_ensure_table`, written with `db_upsert` on the PK so re-runs append
the tail and respect vintages. Prefer long (key + `value`) over wide. Carry a
`model_version` constant and a `computed_at TIMESTAMPTZ`. Examples: `heatindex_level`,
`forecast_policy_rate (origin_date, horizon, source, quantile, value)`, `curve_nominal (date, maturity, yield)`.

Forecast tables in use:
- `forecast_policy_rate (origin_date, horizon, source, quantile)` — the policy rate's THREE
  readings; `source` means reading-METHOD. Don't broaden it: the ordered-probit reading is a
  pending occupant, and mixing quantities in would leave it dense in one cell, empty in ten.
- `forecast_macro (origin_date, horizon, variable, quantile)` — A2's joint fit for every
  modelled variable (inflation, heat, gap, ECB, FX). Units differ per `variable`, so none is
  stored; the app resolves them from `app/R/labels.R`. The policy rate appears here AND in
  `forecast_policy_rate` on purpose — they must agree exactly (a free cross-check).
- `forecast_fx (origin_date, horizon, series, quantile)` + `bvar_fx_draws` — A6. `series`,
  not `variable`, because the target is a canonical `fx_daily.series` code.
- `curve_params (date, curve, parameter)`, `curve_points (date, curve, maturity)`,
  `curve_residuals (date, orderbookid)` — A3. `curve` ∈ nominal | real | **breakeven**
  (nominal − real, the headline output). `curve_points` is never written below a curve's
  own shortest bond: the real curve starts ~3y and its fitted 1y swings 0.9%→4.6% on
  lambda alone, so a point there would be invented. `curve_residuals` is the rich/cheap
  signal A5 will consume.

## A3 curve conventions (fixed-once — do not re-tune casually)

Nelson-Siegel, NOT Svensson: 6 parameters against 7 usable nominal bonds leaves 1 df.
**Lambda is FIXED** (`nominal = 2.0`, `real = 3.0`) — a per-day grid search lowers that
day's RSS but makes the shape wander (free lambda sd 1.4/2.5), which destroys day-to-day
comparability. Bonds inside `MIN_TAU = 0.25y` are excluded (a near-redemption stub took
nominal RMSE from 2.2bp to 21.6bp while moving 5y/10y under 2bp). T-bills are NOT a
short-end anchor despite SPEC A3 proposing it: `tbill_auctions` holds auction prints on
auction dates, not daily marks.

## BVAR modules: shared helpers, and a package trap

- `R/models/helpers_bvar.R` holds the scaffolding every BVAR module repeats
  (`month_end_series`, `monthly_series`, `quarterly_to_monthly`, `bvar_simulate`,
  `bvar_draws_long`, `bvar_bands`). `run_models.R` sources it explicitly and EXCLUDES it
  from the model loop — it defines functions, it is not a module.
- **`BVAR::predict()` is over-dispersed ~2.4×** on this install. Verified on synthetic data
  with a known error sd of 2.40: fitted `sigma` is right (2.36) but `predict()` reports 5.7,
  and the ratio does NOT shrink at n = 1000 or 5000, so it is not parameter uncertainty.
  Use `bvar_simulate()` (simulates forward from each posterior draw) for anything where the
  band matters — it recovers 2.34–2.36. A2 still uses `predict()` because a persistent LEVEL
  forecast is dominated by the VAR dynamics and its bands check out; that is unverified for
  any new module.
- **Model files are sourced in sorted order**, so a module reading another's output must sort
  after it (`isk_path.R` after `heat_index.R`). Name files accordingly.

## A2 policy-rate forecast: two readings (SPEC wants three)

`forecast_policy_rate` holds multiple readings, distinguished by `source`:
- `bvar` (`policy_rate_path.R`) — the BVAR density (median + 5/16/50/84/95 bands), 18m. A level
  VAR on a ~0.93-AR rate: it's persistence-dominated and does NOT anticipate announced policy
  turns. Full posterior draws persisted to `bvar_policy_draws` (scenario-engine foundation).
- `market` (`policy_rate_market.R`) — the market-implied path from the REIBOR money-market curve,
  point path to 6m only (REIBOR doesn't inform further). This is the reading that prices turns
  the BVAR can't; term premia frozen over 2015-2019 in `market_term_premium`.
- Each source has its OWN origin (BVAR = heat-index month; market = latest REIBOR month) — don't
  assume one `max(origin_date)` across sources.
- Still to build: the ordered-probit reaction-function reading (P(cut/hold/hike) per meeting).

## Conventions / gotchas

- **UTF-8 everywhere** — `þ ð æ ö` appear in scraped Hagstofa/Seðlabankinn labels and
  source column names; a predictable source of silent breakage.
- **DB layer is English snake_case**; series codes are UPPERCASE (`CARD_TURNOVER_HH`,
  `GDP_real`). Icelandic strings only as genuine display labels.
- **Dates: ISO, `Date` type, named `date`.** Tables differ on month-start vs month-end
  (e.g. `card_turnover` stores month-end); floor to month-start when aligning across tables.
- **Series codes are built dynamically** in ingest files from Icelandic-label → code
  lookup vectors (`lfs_units`, `na_components`, …), not literal strings. To know what's in
  a table, query it: `SELECT DISTINCT series FROM <table>`.
- **Ragged edge:** monthly/bi-monthly/quarterly series update on irregular dates. A
  source/model not updating is logged-missing, not a pipeline failure. Models must feed
  gaps as `NA` (the DFM/Kalman filter handles them) rather than break.
- **Vintages respected:** upsert appends the tail; never silently overwrite history.
- **Ex-ships/aircraft** adjustment is already applied in the `trade_imports` ingest
  (`INVEST_IMPORTS_EX_SHIPS_AIRCRAFT`).
- **gagnabanki click race:** the report page's "Excel" button is enabled from the first
  paint, before the data loads, and an early click is a SILENT no-op (no Blob, no error) —
  the cause of the long-running intermittent `pension_*` / `bank_*` failures. There is no
  DOM readiness flag (the grid is virtualised: no rows, no spinner), so
  `gagnabanki_report_xlsx` clicks-polls-reclicks until the Blob appears. Never "fix" a
  gagnabanki flake by lengthening a `Sys.sleep()`.
- **Scraped portals move:** Seðlabankinn's publications page no longer lists individual
  Fjármálastöðugleiki issues — `reserves_adequacy` resolves the latest issue from the TAG
  ARCHIVE (`safnsida/?tag=ritið fjármálastöðugleiki`). Two report-slug styles coexist
  (`fjarmalastodugleiki-2026-1` and `2024-03-13-Fjarmalastodugleiki-2024-1`), so match
  case-insensitively and take the issue from the TRAILING `YYYY-N`.
- **Derived, not pulled:** 2y breakeven inflation (fitted RIKB − RIKS curves) and
  Brent-in-ISK are computed downstream, never scraped.
- **Fixed-once conventions:** standardisation/z-score windows, normalisation scales,
  forecast horizons/bands, curve family, settlement, benchmark — decided once and held
  constant, or cross-vintage comparison breaks. (A1 freezes its standardisation params in
  `heatindex_standardisation`, insert-if-absent, version-aware — recomputed only on a
  `model_version` bump, never on an ordinary re-run.)
- **A1 heat index (v3): two-factor + robust.** Robust standardisation (median/MAD, not
  mean/SD) and winsorised fit inputs so a synchronised shock (COVID) stays proportionate.
  TWO factors are estimated and variance-weighted (a high-frequency activity factor + a
  persistent confidence/financial-cycle factor) so both a sharp real shock (COVID, ~-4) and
  a persistent crisis (GFC, ~-2.6) register. The keystone GFC signal is **Gallup consumer
  confidence** (`consumer_confidence`, entered as a `level` not a YoY diff — it's already a
  cycle reading); deep-history **house prices** and **residential investment** reinforce it.
  These three were ported from hagdeild/thjodhagslikan. `heatindex_level.low_confidence`
  flags the thin pre-2004 panel. (Hagstofa exposes no deeper monthly trade — verified; the
  GFC is now carried by confidence/housing/FX, which have history back to 2000-2003.)

## Code style (global)

- Don't define a function unless its logic is used ≥3×; otherwise inline it.
- No `print`/`cat`/`message` for logging in code that stays (runners' warn-and-continue
  and run summaries are the sanctioned exception). No saving plots to image files — leave
  plot objects in memory for interactive viewing.
- Never do unrequested work — propose it and wait for the go-ahead.

When you have to correct Claude on something repeatable, add the rule here.
