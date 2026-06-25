# UNRESOLVED_SOURCES.md — sources that need manual resolution

> Every series from `data_sources.md` that could not be pulled (unverifiable
> TimeSeriesID / PX-Web path / FRED code / download URL, a scrape that failed or
> returned the wrong-looking data, no stable endpoint found) is logged here with
> enough detail to resolve it manually. Per `INGEST_TASK.md §0`: a logged gap is
> cheap; a silently-wrong series is expensive. This file is the agenda for the
> manual resolution session — keep it current as ingestion is built out, don't
> batch it to the end.

Format per entry:

```
## <series name> (<cadence>) — <source>
- Access mode attempted: package / scrape / excel
- What I tried: <package + series id, or URL + query, or download URL>
- What happened: <error / wrong-looking data / no stable URL / ID unverifiable>
- What I need from you: <the specific missing piece>
```

---

## ✅ Resolved (wired + verified in the DB) — no longer blocking

- **Pension-system foreign-asset share** → table `pension_foreign_assets`,
  `R/ingest/monthly/pension_foreign_assets.R`. The CBI pension balance sheet
  (gagnabanki report `MARKETS.PENSIONFUNDS.OVERVIEW.TABLE`, blob-hook download):
  total assets (row 4, *Eignir samtals*) and foreign assets (row 28, *Erlendar
  eignir*), stored as two component levels so the share — and the gap to the
  statutory 50% ceiling — derives downstream (≈41% as of 2026-04). M.kr.,
  **monthly** 1997-01→2026-04 (was logged as quarterly; the CBI series is
  monthly).
- **Terms of trade — goods+services** → table `terms_of_trade`,
  `R/ingest/quarterly/terms_of_trade.R`. The goods-only PX-Web table UTA07002 is
  dead at 2021; instead **derived from national accounts THJ01601** as export
  deflator ÷ import deflator (current prices ÷ chain-linked volume), quarterly
  1995-Q1→2026-Q1. Skipting codes read from the table metadata, not guessed:
  total exports = `"8"`, total imports = `"11"` (a web summary's "6/7" were
  wrong — those are inventory changes / domestic demand). Stores
  `EXPORT_DEFLATOR_GS`, `IMPORT_DEFLATOR_GS`, `TERMS_OF_TRADE_GS` (≈100-based).
- **Treasury bills (ríkisvíxlar) rates** → table `tbill_auctions`,
  `R/ingest/monthly/tbill_auctions.R`. There is **no daily secondary-market
  quote** for T-bills anywhere (confirmed: the lanamal.is landing page and
  `/markadsyfirlit/` render only RIKB/RIKS; no RIKV order book). T-bill rates
  exist **only as auction results**, published per auction (~monthly) as a
  lanamal.is news article; this scrapes the RIKV result articles for the
  weighted-average accepted yield, bid-to-cover and accepted amount. Event-driven
  data, **polled monthly and accreted forward** (see depth caveat below).
- **Output-gap estimate** → table `output_gap`,
  `R/ingest/quarterly/output_gap.R`. Not on any feed — it's the QMM model's `GAP`
  variable in the CBI macro-forecast (efnahagsspá) database workbook. The `.xlsx`
  link (a rotating library `itemid`, JS-rendered page) is resolved live as the
  single `type=xlsx` anchor; `GAP` is found by name in the header row (it drifts
  between vintages) against the col-A "YYYYQq" quarter; stored ×100 as % of
  potential output. Quarterly 1992-Q1→2025-Q4, revised each vintage (upsert keeps
  latest). NB an adjacent `GAPAV` (smoothed gap) column exists if ever preferred.
- **Reserves-adequacy components** → table `reserves_adequacy`,
  `R/ingest/quarterly/reserves_adequacy.R`. The IMF-style adequacy ratios from the
  Financial Stability report chart "Gjaldeyrisforði Seðlabanka Íslands": reserves
  as % of the IMF composite metric (`Samsett forðaviðmið AGS`) and as % of
  short-term external debt. Resolved live across three hops (publications page →
  latest FS report → "gögn úr köflum" workbook → chart located by CONTENT, not
  number). Quarterly, ~6-yr rolling window (2020-Q1→2025-Q4); semi-annual refresh.
  The reserve LEVEL is not duplicated here (it's in `reserves`).
- **Card turnover / New mortgage lending / Bank lending to firms** — were already
  wired (commit `7faa127`): `card_turnover.R`, `bank_new_mortgages.R`,
  `bank_loans_sector.R`. The earlier entries here were stale.
- **Foreign ownership of government bonds** — resolved earlier
  (`govt_bond_owners`, gagnabanki `securities`).
- **Current account / greiðslujöfnuður** — resolved earlier (`current_account`,
  SDDS feed; see rolling-window note below).

---

## ⛔ Still unresolved — genuinely not published as a pullable series

I pulled the CBI data portal's full catalog (`gagnabanki.is/api/config` +
`/api/translation/is`) to settle it — it is authoritative, and the one below is
not in it.

### FX forwards (daily) — Seðlabankinn
- Access mode attempted: scrape / catalog inspection.
- What I tried: the gagnabanki portal catalog and the FX-market reports.
- What happened: the only FX-market reports are `FXMARKET.RATES` (spot open/close
  EURISK) and `FXMARKET.TURNOVER` (interbank **spot** turnover). There is no
  forward / swap / *framvirk* report anywhere on the feed or the portal. Iceland's
  forward FX market is thin OTC; no public daily forward-rate series is published.
- What I need from you: confirmation of exactly which "FX forwards" quantity you
  want (forward points / outright forward rate? forward-market turnover? the
  banks' net forward FX position from the Financial Stability report?) and a
  source if you have one. Otherwise this stays parked.

---

## ⚠️ Awareness notes (the live pulls work; these are depth / robustness caveats)

### A cleaner CBI backend exists (SDMX) but is firewalled from our network
The gagnabanki portal is backed by a real **SDMX v2 API**:
`https://fr.sedlabanki.is/sdmx/v2/table/IS2_EXT/<TABLE>/1.0?format=xlsx` —
stable, direct download URLs (e.g. `LIF_BALANCE_SHEETS_TOTAL`,
`FINSTATS.MONETARY.*`) that would replace the headless-Chrome `createObjectURL`
blob-hook for **every** gagnabanki-based source (pension, bank lending, card
turnover, govt-bond owners). But `fr.sedlabanki.is` **refuses connections from
this environment** (port 443 times out; `sdmx.centbank.is` does not resolve), so
it is unusable here and nothing was changed. If the scheduled job ever runs from
a network that can reach it (e.g. inside Iceland), those sources can be
simplified to plain `httr2` downloads. Logged so it isn't forgotten.

### Treasury-bill auction history accretes forward only
The lanamal.is auction-results listing exposes only the latest ~handful of RIKV
auctions and has no plain-GET pagination (it's a React listing whose "load more"
is not a simple query param), so `tbill_auctions` starts shallow and accretes
forward on each monthly run. A one-time deep backfill would need the listing's
load-more endpoint — point me at it (or a bulk auction-history file) if deep
history is needed for training.

### Seðlabankinn SDDS/NSDP series (group 30) — rolling-window backfill limit
- Affects: current account (id 83), reserves (id 130), and any other group-30
  NSDP.* series wired from the CBI xmltimeseries feed.
- What happens: this feed serves only a rolling ~last-12-months window for SDDS
  series, regardless of the DagsFra date requested. So a single run backfills
  only ~1 year; deeper history is NOT available from this endpoint. The wired
  sources are correct and accrete history forward via upsert on each scheduled
  run — but they start shallow.
- What I need from you (optional): if a DEEP backfill of current account /
  reserves is needed for model training, point me at a CBI release that carries
  full history (e.g. an Excel/CSV statistics download), and I'll add a one-time
  backfill source. Otherwise this is just an awareness note — the live pulls work.
