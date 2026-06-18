# INGEST_TASK.md — Build out the data ingestion layer

> **This is a one-off task brief, not a permanent config.** It tells you how to build the
> ingestion layer for every series in `data_sources.md`. Read `PROJECT.md` (architecture),
> `SPEC.md` (what each series feeds), `data_sources.md` (the full list), and the two existing
> R files in `R/` before starting. When this task is done, this file can be deleted.

---

## 0. The single most important rule: never fabricate access details

You will not know every Seðlabankinn `TimeSeriesID`, every Hagstofa PX-Web table path, or
every package name from memory, and **guessing is worse than leaving a gap**. A plausible but
wrong TimeSeriesID returns the wrong series silently and corrupts everything downstream.

Therefore:

- If you can verify an access method (a documented API, a known R package, a scrape you can
  actually test against the live page), implement it.
- If you **cannot verify** an ID / endpoint / query string / package, **do not invent one.**
  Add the series to `UNRESOLVED_SOURCES.md` (see §6) and move on.
- Attempting a scraper blind is fine and expected — but if it fails, errors, or returns
  something that doesn't look like the described series, it goes in `UNRESOLVED_SOURCES.md`.
  Do not paper over a failed pull with a fabricated fallback.

When in doubt: a logged gap I review manually is cheap. A silently-wrong series is expensive.

---

## 1. Copy the existing pattern — do not invent a new one

`R/get_daily_data.R` already establishes the house style. Study it first and conform to it
exactly. In particular:

- **DB helpers already exist:** `db_connect()`, `db_upsert(con, table, tbl, conflict_cols)`,
  and `db_ensure_table(con, table, cols, pk)`. **Reuse them. Do not rewrite or duplicate
  them.** Your first step (§2) is to extract them into a shared file so every runner can
  source them.
- **One source = one function** returning a single cleaned tibble (e.g.
  `get_cbi_policy_rate()` → `policy_rate_tbl`). The function pulls and cleans only.
- **Each function's tibble is upserted** into a clearly named Postgres table, keyed on `date`
  (plus `series` / `tenor` / `bond_code` where a date alone isn't unique), appending the tail
  via `db_upsert`, never rewriting history.
- **One shared DB connection per run**, opened once at the top of a runner and disconnected at
  the very end — not one connection per function. See how `get_daily_data.R` does it.
- **For any table that doesn't exist yet, call `db_ensure_table` before the first upsert**, the
  way `rates_reibor`, `fx_daily` already do it. `db_upsert` does not create tables.

Do not introduce `data.table`, base-R idioms where a tidyverse equivalent exists, or any
non-tidyverse data manipulation. R only, tidyverse throughout. (See `PROJECT.md §4`.)

---

## 2. First step: extract the shared DB helpers

Right now `db_connect`, `db_upsert`, and `db_ensure_table` live inside `get_daily_data.R`.
Because monthly / quarterly / event runs will be separate files, move these three helpers
into a single shared file:

```
R/db/db_helpers.R
```

Then have `get_daily_data.R` (and every new runner) `source()` that file instead of defining
the helpers inline. Do this extraction **first**, confirm `get_daily_data.R` still runs
end-to-end after the change, and only then start adding new sources. Do not alter the helper
logic — only relocate it.

---

## 3. Target file structure

Build out this layout. Group by **cadence**, because cadence is what the scheduler and the
ragged-edge handling care about (`PROJECT.md §7`, `SPEC.md Part C`):

```
R/
  db/
    db_helpers.R          # db_connect / db_upsert / db_ensure_table (extracted in §2)
  ingest/
    daily/                # one file per source or tight source-group
    monthly/
    quarterly/
    event/
  run_daily.R             # sources every R/ingest/daily/*.R, opens one con, runs all, disconnects
  run_monthly.R
  run_quarterly.R
  run_event.R
```

Notes:

- The existing daily sources in `get_daily_data.R` (policy rate, RIKB/RIKS bonds, REIBOR, FX,
  plus the bond-attribute reconciliation) should be **migrated into `R/ingest/daily/`** as part
  of this work, one logical file per source group, so everything lives under the same
  structure. Keep `get_bond_attributes.R` as-is (it's a one-time backfill + shared helpers);
  just make sure the daily runner still sources it where the new-bond reconciliation needs it.
- Each `run_*.R` is a thin orchestrator: `source` the db helpers, open one connection, source
  and execute each ingest file in its cadence folder, disconnect last. No pulling/cleaning
  logic in the runners themselves.
- One file per source is the default. Group only when sources are genuinely the same
  fetch (e.g. several Seðlabankinn xmltimeseries IDs that differ only by ID, like the existing
  REIBOR and FX blocks).

---

## 4. Acquisition modes — what to do in each

`data_sources.md` lists every series. Sources fall into three access modes; handle each as
follows.

**(a) Available via an R package.** Prefer a maintained package over scraping when one exists
and you can confirm its name and usage:
- FRED series (Fed funds, US Treasury 2y/10y) → `fredr`.
- ECB series (depo rate, Bund 2y/10y) → an SDMX package (e.g. `ecb` / `rsdmx`) if you can
  confirm the flow/key.
- If you cannot confirm the exact series ID or the package's current interface, **do not guess
  the ID** — wire up as much as you can verify and put the rest in `UNRESOLVED_SOURCES.md`.

**(b) Scrape / API you can attempt blind.** Attempt these even without prior confirmation:
- Hagstofa PX-Web (CPI, wage index, national accounts, trade, LFS, etc.) has a documented
  JSON-stat API — attempt it.
- Other scrapes (HMS, Vinnumálastofnun, Lánamál pages, etc.) — attempt with the same
  `chromote` / `rvest` / `httr2` / `xml2` toolkit already in use.
- **If a blind attempt fails or returns something that doesn't match the described series,
  log it in `UNRESOLVED_SOURCES.md`.** Do not leave a broken scraper wired into a runner.

**(c) Excel-only Seðlabankinn sources.** Pull these **programmatically**: download the
spreadsheet with `httr2` (or `download.file`) and read it with `readxl`. Do not hand-convert.
If you can't locate a stable download URL, log it in `UNRESOLVED_SOURCES.md` rather than
guessing one.

For all three modes, the conventions in `PROJECT.md §7` apply: UTF-8 (`þ ð æ ö` in scraped
labels and column names), English snake_case DB columns, ISO `date` columns of `Date` type,
ragged-edge series log-missing rather than error, ex-ships/aircraft adjustment on
investment-goods imports, breakeven inflation and Brent-in-ISK are **derived downstream, not
pulled** (do not write scrapers for those).

---

## 5. Work order — one source group at a time, and STOP for review

**Do not attempt the whole list in one pass.** Work in small, reviewable increments:

1. Do §2 (extract DB helpers), confirm the daily run still works, then stop and report.
2. Migrate the existing daily sources into the new structure, then stop and report.
3. Then proceed **one cadence folder at a time**, and within a folder **one source (or tight
   source-group) at a time**. After each source: report what you pulled, the table name and
   schema you wrote to, a few sample rows, and whether it went into the DB or into
   `UNRESOLVED_SOURCES.md`. Then wait for my go-ahead before the next source.

This pace is deliberate. I review each scraper before the next is written. A 30-source
big-bang pass is not acceptable even if you think you can do it.

For each source, before writing code, state in one line: which access mode (a/b/c), what
you'll attempt, and the target table name. If I don't object, proceed.

---

## 6. The unresolved-sources deliverable

Maintain a file `UNRESOLVED_SOURCES.md` at repo root. Every series you could not pull goes
here, with enough detail that I can resolve it manually:

```
## <series name> (<cadence>) — <source>
- Access mode attempted: package / scrape / excel
- What I tried: <package + series id, or URL + query, or download URL>
- What happened: <error message / wrong-looking data / no stable URL found / ID unverifiable>
- What I need from you: <the specific missing piece — a TimeSeriesID, a confirmed URL, etc.>
```

Keep it current as you go — don't batch it to the end. When the whole list is exhausted,
this file is the agenda for our manual session.

---

## 7. What NOT to do

- Don't rewrite or duplicate the DB helpers.
- Don't invent TimeSeriesIDs, PX-Web paths, FRED/ECB series codes, or download URLs.
- Don't write scrapers for derived series (breakeven, Brent-in-ISK).
- Don't change the pulling/cleaning logic in the existing `get_bond_attributes.R` /
  `get_daily_data.R` beyond the migration in §2–3 — and flag, don't silently fix, anything in
  them that looks wrong.
- Don't barrel through the full list — stop for review after each source group (§5).
- Don't use `shinydashboard`, `data.table`, or any non-tidyverse data manipulation (not
  relevant to ingestion, but the stack rule holds repo-wide).