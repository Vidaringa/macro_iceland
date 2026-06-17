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

<!-- entries below, newest grouped by cadence -->

## Terms of trade / viðskiptakjör (quarterly) — Hagstofa
- Access mode attempted: scrape (PX-Web)
- What I tried: the only Hagstofa PX-Web terms-of-trade table is UTA07002.px
  ("Viðskiptakjör 2000-2021") under
  Efnahagur/utanrikisverslun/1_voruvidskipti/04_verdogmagnvisitolur. Also checked
  the national-accounts and short-term-indicator areas for a current replacement.
- What happened: UTA07002.px is DISCONTINUED — it ends in 2021 and was last
  updated 2022-05-11. Wiring it would yield a 4-year-stale series that silently
  stops. No current PX-Web terms-of-trade table was found in the obvious places.
- What I need from you: where the current terms-of-trade series now lives — it
  may have moved into the balance-of-payments / national-accounts framework
  (possibly a Seðlabankinn series), or be derivable from current export/import
  price indices. Confirm the source so it isn't silently stale.

## Current account / greiðslujöfnuður (quarterly) — listed as Hagstofa
- Access mode attempted: scrape (PX-Web) — navigation only
- What I tried: looked under Efnahagur/utanrikisverslun (only goods/services
  trade balances there, not the full balance-of-payments current account) and
  the national-accounts section.
- What happened: Hagstofa PX-Web publishes goods/services trade, but the full
  balance-of-payments CURRENT ACCOUNT in Iceland is a Seðlabankinn statistic, not
  an obvious Hagstofa PX-Web table. data_sources.md attributes it to Hagstofa.
- What I need from you: confirm the source. I will attempt the Seðlabankinn
  balance-of-payments release when I build the Seðlabankinn block; if you have a
  specific Hagstofa table id or a CB TimeSeriesID / Excel URL, that resolves it.

## Treasury bills / ríkisvíxlar rates, all maturities (daily) — Nasdaq Iceland / Lánamál
- Access mode attempted: scrape
- What I tried: (1) the JS-rendered lanamal.is landing page — the same page the
  RIKB/RIKS scraper uses. It renders only two price tables, "Óverðtryggt" (RIKB)
  and "Verðtryggt" (RIKS); the only orderbookid codes present are 8 RIKB + 5 RIKS
  series. No ríkisvíxlar / RIKV / T-bill table or codes appear on the page at all.
  (2) Probed plausible dedicated paths — lanamal.is/markadir/rikisvixlar,
  /markadsupplysingar/rikisvixlar, /utgafa/rikisvixlar, /markadir — all return 404.
- What happened: T-bills are not on the rendered landing page, and I will not
  fabricate a download/scrape URL. It is possible there are simply no outstanding
  ríkisvíxlar at the moment, or they are served from a different page / the Nasdaq
  Iceland order book rather than the lanamal.is landing page.
- What I need from you: the actual URL or order-book source where current
  ríkisvíxlar bid/yield are listed (or confirmation that there are none
  outstanding right now, in which case this can be parked until issuance resumes).

