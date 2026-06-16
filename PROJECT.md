# PROJECT.md — Icelandic Fixed-Income & Macro Intelligence Platform

> This is the **vision + architecture reference**. It is NOT the file Claude Code loads
> automatically every session — that is `CLAUDE.md` (lean operating rules; see end of this
> document for what belongs there vs here). Point Claude Code at this file when a task needs
> the bigger picture.

---

## 1. What this is

A fixed-income and macro intelligence platform for the Icelandic (ISK) market. It automates
what a bank asset-management team presents manually each quarter — yield-curve forecasts,
breakeven inflation decomposition, policy-rate path probabilities, Taylor-rule scenarios,
per-bond forecasts, a coincident "heat index" of the economy, plus an equity/FX/external layer.

The macro models are the engine room; the user-facing product is the storefront.

### Two products, one engine

| Product | Buyer | Surfaces |
|---|---|---|
| **Macro tier** | Firms *exposed to* the cycle (developers like Festir/Reykjastræti, CFO/treasury at firms like Ölgerðin) | Policy-rate path, MPC probabilities, heat index, krona analysis, GDP/cycle read, cost-of-capital scenarios |
| **Asset-management tier** | Firms that *trade* the cycle (bank AM desks, pension funds, unions with funds, insurers) | Everything above **plus** per-bond yield forecasts, scenario P&L, relative value, equity breadth/concentration suite, FX vol/forwards, forecast data export, methodology/track-record pages |

Both run off the same spine: **heat index → rate path → curve → bond returns**.
A one-off **"buy report" PDF** of the latest research serves buyers who want the quarterly view
without a subscription.

Customer zero is **VR** (workers' union), free during testing, internal sponsor = CEO.

---

## 2. The non-negotiable architecture rule

**Computation, storage, and presentation are three separate layers. They communicate only
through Postgres.** This separation is what lets the front end change (Shiny now, possibly
Next.js later) without touching the models, and lets the models change without touching the app.

```
  ┌─────────────────────────┐
  │  R MODEL / INGESTION     │   Scheduled scripts. Pull → clean → wrangle (dplyr) → fit.
  │  SCRIPTS (R, tidyverse)  │   All wrangling in dplyr/tidyr.
  └───────────┬─────────────┘
              │ writes canonical series + model outputs
              ▼
  ┌─────────────────────────┐
  │  POSTGRES                │   THE single source of truth. Canonical cleaned series +
  │  (serving database)      │   all model outputs (forecasts, curves, probabilities,
  │                          │   heat index, posterior draws). Everything the app reads.
  └───────────┬─────────────┘
              │ reads
              ▼
  ┌─────────────────────────┐
  │  R SHINY APP             │   Reads from Postgres. Plots, tables, scenario controls.
  │  (presentation)          │   Pure Shiny, hand-authored HTML/CSS. No model code inline.
  └─────────────────────────┘
```

---

## 3. Storage: what goes where

### Postgres — the serving database (source of truth)

Everything the **app reads** and everything that must **persist** lives here:

- **Canonical cleaned series** — every pulled-and-cleaned daily/monthly/quarterly series
  (policy rate, RIKB/RIKS yields, CPI, FX, heat-index inputs, etc.). One table family per
  domain (e.g. `rates_policy`, `bonds_rikb`, `bonds_riks`, `fx_rates`, `cpi`, `heatindex_inputs`).
- **Model outputs** — fitted curves, yield forecasts, policy-rate path, MPC probabilities
  (market-implied / BVAR-density / reaction-function), Taylor-rule scenarios, the heat-index
  series, scenario P&L results, equity breadth metrics.
- **Posterior draws** needed for fast scenario re-weighting (so scenarios don't re-fit the BVAR live).

Writes are **upserts keyed on date** (append the tail, don't rewrite history) so DFM vintages
are respected and history isn't silently overwritten.

### DuckDB — not used

Not part of this stack. All wrangling is done in dplyr/tidyr in R. (Data volumes for the
Icelandic market are small enough that dplyr handles all mixed-frequency joins comfortably;
adding a separate compute engine would be unnecessary complexity. Reconsider only if some
future wrangling step becomes genuinely painful in dplyr — unlikely at this data size.)

### Why Postgres serves (and nothing else)

Postgres uses MVCC: readers see a consistent snapshot while a write is in progress, so the
scheduled job can write while users read, with no blocking. A single-writer file store
(DuckDB file, `.rds`) would let the daily ingestion job block or break app reads — exactly the
case to avoid for a served product.

### `.rds` / CSV — NOT a data layer

- `.rds` is acceptable only as a transient cache **within a single script run**.
- Never the handoff between ingestion and app, never a shared store. No data files committed to git.

### The rule, stated plainly for Claude Code

> Every ingestion function ends by writing its cleaned tibble to a Postgres table (upsert on
> date). All wrangling is dplyr/tidyr in R. No `.rds`/CSV file is ever the source of truth.
> The app reads exclusively from Postgres.

**Worked example.** `get_cbi_policy_rate()` returns `policy_rate_tbl`. It is upserted into a
Postgres table `rates_policy (date, policy_rate, ...)`. The **app** reads `rates_policy` to plot
it; the **BVAR script** reads `rates_policy` (with other series) as a model input, wrangles in
dplyr, fits, and writes `forecast_policy_rate` + `mpc_probabilities` back to Postgres for the
app to read.

---

## 4. The stack

| Layer | Choice | Notes |
|---|---|---|
| Language | **R only** | tidyverse idioms throughout. No base-R-isms where a tidyverse equivalent exists; no data.table; no pandas-style habits. |
| Ingestion | R (`rvest`, `xml2`, `chromote`, `httr2`) | Scheduled. Each source = its own function. |
| Wrangling | dplyr/tidyr | All mixed-frequency joins handled in dplyr. No separate compute engine. |
| Storage / serving | **Postgres** | Single source of truth. App + models both read here. |
| Models | R — **BVAR** (policy-rate path, primary), DFM/Kalman (heat index), Nelson-Siegel/Svensson (curves), ordered probit (MPC reaction fn), NHITS (daily yield horse race) | Models are **fixed and validated**. Users get scenario inputs, never model re-specification. |
| App | **Pure R Shiny** | Hand-authored HTML/CSS/JS for 100% UI control. |
| Reports | PDF generation from R | The "buy report" one-off deliverable. |

### Scheduling

Ingestion + model fitting run on a schedule (cron / scheduled R jobs), write results to Postgres.
The app never triggers a model fit on page load — it reads pre-computed results. Scenario mode
re-weights existing posterior draws (cheap, sub-second), it does NOT re-estimate.

### Working split between me (human) and Claude Code

I author and maintain the **data-pulling R script** myself — each source gets its own function
that returns a cleaned tibble (e.g. `get_cbi_policy_rate()` → `policy_rate_tbl`). I hand the
script to Claude Code and its job is to **add all the Postgres writes**: for each cleaned tibble,
upsert it into the appropriate Postgres table, keyed on `date`, appending the tail rather than
rewriting history. Claude Code should:
- Add a single shared DB connection helper, not a new connection per function.
- Map each tibble to a clearly named table (English snake_case).
- Use upsert-on-`date` semantics so re-running the daily job updates new rows without
  overwriting existing history (DFM vintages must be respected).
- Not alter my pulling/cleaning logic — only add the write layer (and flag, not silently fix,
  anything in the pull that looks wrong).

---

## 5. Shiny UI rules (full control, no imposed look)

A Shiny UI *is* HTML/CSS underneath. We author it by hand and keep only Shiny's input/output
binding plumbing.

- **Pure Shiny only.** No `shinydashboard`, `bs4Dash`, `flexdashboard`, or any layout-imposing
  wrapper package.
- UI built from `tags$*` / `htmlTemplate()`. All layout and styling hand-authored.
- Custom CSS/JS lives in `www/`, loaded via `tags$head(tags$link(...))` / `includeCSS()`.
- Shiny owns the **input/output binding layer only**: inputs need a Shiny `inputId`, outputs need
  an `outputId` + matching `render*`. Appearance of those elements is 100% ours.
- Charts styled to the design system: `ggplot2` (static) or `plotly`/`echarts4r`/`highcharter`
  (interactive). State palette + fonts once and apply consistently.

### DECISION TO LOCK BEFORE ANY UI IS WRITTEN
**Bootstrap base (`bslib`) vs zero-Bootstrap (pure custom CSS)?**
`bslib` is NOT in the same category as `shinydashboard` — it's the modern theming layer with
CSS-variable control and no dashboard chrome. Pick one:
- `bslib` base → branded-but-conventional, less CSS to write.
- zero-Bootstrap → full pixel authority, write all CSS from scratch, no Bootstrap reset/grid.
Write the choice here once decided: **[ TODO: choose ]**

---

## 6. Scenario engine (the AM-tier interactive feature)

Advanced users do **not** modify the model (no editing priors, variables, lags — that turns the
product into a hosted econometrics IDE, destroys the track-record page, and makes us liable for
user-broken forecasts). Instead they get **scenario inputs on a fixed, validated model**:

- User sets an exogenous path / shock (e.g. "MPC cuts faster", "inflation runs hotter",
  "ISK depreciates 10%").
- We push it through *our* BVAR and show the resulting rate path / curve / bond P&L.
- Implemented by re-weighting / filtering already-computed posterior draws — fast, server-side,
  no re-estimation.

A "power mode" for genuine model-tinkering is a possible year-two feature for a proven paying
client. Not a launch requirement.

---

## 7. Icelandic-specific conventions

- **Encoding: UTF-8 everywhere.** `þ ð æ ö` appear in scraped data and source column names —
  a predictable source of silent breakage when scraping Hagstofa / Seðlabankinn.
- **Database layer is English snake_case** for all table and column names (`rates_policy`,
  `date`, `policy_rate`, `deposit_7d`). Icelandic strings only where they're genuine display
  labels in the app.
- **Dates: ISO format, `Date` type**, named `date`.
- **Ragged edge tolerance:** monthly/bi-monthly series update on irregular schedules. A scheduled
  job must treat "series didn't update" as logged-missing, not a failure. The DFM is built to
  handle gaps — the pipeline must feed gaps gracefully rather than break.
- **Ex-ships/aircraft adjustment** on investment-goods imports matters enormously — apply it.
- **Derived, not pulled:** 2y breakeven inflation (from our fitted RIKB/RIKS curves) and
  Brent-in-ISK are computed downstream of the daily pull, not scraped.

---

## 8. Data sources (scraper map)

Pulled series, by cadence. (Endpoint quirks — PX-Web query format, Seðlabankinn TimeSeriesIDs,
rate limits — belong in `CLAUDE.md` as they're hit, since the agent needs them every session.)

**Daily:** policy-rate components (Seðlabankinn), all RIKB + RIKS yields, T-bill rates, REIBOR
(Nasdaq Iceland / Lánamál); ISK vs USD/EUR/GBP + trade-weighted index, FX forwards (Seðlabankinn);
Fed funds, US Treasury 2y/10y, ECB depo, Bund 2y/10y (FRED/ECB); Brent, aluminium (public);
S&P 500 level + constituents for breadth, forward P/E + CAPE, UCITS ETF closes; OMXI + all
Icelandic listed closes/volume/turnover (Nasdaq Iceland).

**Monthly:** card turnover (domestic / abroad / foreign-in-Iceland), new mortgage lending, bank
lending to firms, foreign ownership of govt bonds, reserves, FX intervention (Seðlabankinn);
CPI + core subindices, wage index, VAT turnover by sector (bi-monthly), consumer-goods imports,
investment-goods imports ex ships/aircraft, marine export values, marine price index, aluminium
export volumes, hotel overnight stays, monthly LFS, new company registrations, insolvencies
(Hagstofa); registered unemployment + register level + vacancies (Vinnumálastofnun); house price
index + purchase agreements + time-on-market (HMS); new foreign domicile registrations (Þjóðskrá);
Keflavík passengers (Isavia/Ferðamálastofa); new car registrations private vs corporate/rental
(Samgöngustofa); cement sales, Alfreð job listings, Gallup consumer confidence, Google Trends
(scraped/non-API).

**Quarterly:** real GDP / domestic demand, current account, terms of trade (Hagstofa); output-gap
estimate, pension-system foreign asset share vs ceiling, reserves-adequacy components
(Seðlabankinn); Gallup corporate sentiment / hiring intentions; trading-partner GDP / euro-area
composite (OECD/Eurostat).

**Event-driven (as published):** auction calendar + results + bid-to-cover (Lánamál); insider
filings, domestic earnings calendar + reported fundamentals (Nasdaq Iceland).

---

## 9. What belongs in CLAUDE.md instead of here

`CLAUDE.md` is loaded into context every session, so keep it lean (~150 lines max) — rules and
facts the agent needs to not make mistakes, not vision/prose. Put there:

- The hard stack rules (R only, tidyverse not base/data.table, Postgres serves / no `.rds`
  data layer, pure Shiny no wrappers).
- Repo geography (one short map of where ingestion / models / scrapers / app / outputs live).
- Commands (run the pipeline, refresh a source, run tests, launch the app — exact incantations).
- Data-source facts as they're hit (PX-Web query format, Seðlabankinn TimeSeriesIDs, rate
  limits, the ex-ships adjustment).
- Conventions/gotchas (UTF-8 + þ/ð/æ/ö, English snake_case DB columns, ISO dates, ragged-edge
  handling, DFM vintages).
- A pointer line: "Project vision and architecture: see PROJECT.md".

Treat `CLAUDE.md` as a living config: each time Claude Code does something you have to correct,
add the rule that would have prevented it.