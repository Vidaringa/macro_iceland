# DATA_SOURCES.md — Data inventory

> Every series the platform pulls, by cadence and source. This is the scraper map from
> `PROJECT.md §8`, broken out as a standalone reference for the IDE. Endpoint quirks (PX-Web
> query format, Seðlabankinn TimeSeriesIDs, rate limits) live in `CLAUDE.md` as they're hit;
> this file is *what* is pulled, not *how*.
>
> **Conventions** (per `PROJECT.md §7`): UTF-8 throughout (þ ð æ ö in scraped labels);
> English snake_case DB columns; ISO dates as `Date` named `date`; ragged-edge series log
> missing rather than fail; ex-ships/aircraft adjustment applied to investment-goods imports;
> breakeven inflation and Brent-in-ISK are **derived downstream, not pulled**.
>
> **Status legend** (the `S` column): ✅ pulled — wired, verified, written to the named
> Postgres table; ⛔ unresolved — attempted but not pullable, logged in
> `UNRESOLVED_SOURCES.md` with details; ⬜ todo — not yet attempted; ➖ derived downstream
> (not pulled). The DB table for each pulled series is noted after the source.

---

## Daily

| S | Series | Source | DB table |
|---|---|---|---|
| ✅ | Policy-rate components — 7-day deposit (headline), current account, overnight, collateralised lending | Seðlabankinn | `rates_policy` (headline) + `rates_policy_components` (all 4) |
| ✅ | All RIKB (nominal) government bond yields/prices, every outstanding series | Nasdaq Iceland / Lánamál | `bonds_daily` |
| ✅ | All RIKS (indexed) government bond yields/prices, every outstanding series | Nasdaq Iceland / Lánamál | `bonds_daily` |
| ⛔ | Treasury bill (ríkisvíxlar) rates, all maturities | Nasdaq Iceland / Lánamál | — not on landing page |
| ✅ | REIBOR fixings — O/N, 1m, 3m, 6m | Nasdaq Iceland / Lánamál | `rates_reibor` |
| ✅ | ISK vs USD / EUR / GBP + trade-weighted index | Seðlabankinn | `fx_daily` |
| ⬜ | FX forwards | Seðlabankinn | |
| ✅ | Fed funds rate | FRED | `rates_external` |
| ✅ | US Treasury 2y / 10y | FRED | `rates_external` |
| ✅ | ECB deposit rate | ECB | `rates_external` |
| ✅ | Bund 2y / 10y (stored as EA AAA-government curve) | ECB | `rates_external` |
| ✅ | Brent crude | public (quantmod/Yahoo) | `commodities_daily` |
| ✅ | Aluminium | public (quantmod/Yahoo) | `commodities_daily` |
| ⬜ | S&P 500 level + constituents (for breadth) | (market data) | |
| ⬜ | Forward P/E + CAPE | (market data) | |
| ⬜ | UCITS ETF closes | (market data) | |
| ⬜ | OMXI + all Icelandic listed closes / volume / turnover | Nasdaq Iceland | |

---

## Monthly

| S | Series | Source | DB table |
|---|---|---|---|
| ⬜ | Card turnover — domestic / abroad / foreign-in-Iceland | Seðlabankinn | |
| ⬜ | New mortgage lending | Seðlabankinn | |
| ⬜ | Bank lending to firms | Seðlabankinn | |
| ⬜ | Foreign ownership of government bonds | Seðlabankinn | |
| ✅ | Reserves (total, USD millions) | Seðlabankinn | `reserves` † |
| ✅ | FX intervention (CBI buy/sell of FX) | Seðlabankinn | `fx_intervention` |
| ✅ | CPI + core subindices (CPI, CPI ex-housing; index + YoY) | Hagstofa | `cpi` |
| ✅ | Wage index | Hagstofa | `wage_index` |
| ✅ | VAT turnover (bi-monthly; economy-wide total) | Hagstofa | `vat_turnover` |
| ✅ | Consumer-goods imports | Hagstofa | `trade_imports` |
| ✅ | Investment-goods imports, ex ships/aircraft | Hagstofa | `trade_imports` |
| ✅ | Marine export values | Hagstofa | `exports_marine_aluminium` |
| ✅ | Marine price index | Hagstofa | `marine_price_index` |
| ✅ | Aluminium export volumes (SITC 68 non-ferrous proxy) | Hagstofa | `exports_marine_aluminium` |
| ✅ | Hotel overnight stays | Hagstofa | `hotel_nights` |
| ✅ | Monthly LFS (labour force survey) | Hagstofa | `lfs` |
| ✅ | New company registrations | Hagstofa | `company_registrations` |
| ✅ | Insolvencies (bankruptcies) | Hagstofa | `company_registrations` |
| ⬜ | Registered unemployment + register level + vacancies | Vinnumálastofnun | |
| ⬜ | House price index + purchase agreements + time-on-market | HMS | |
| ⬜ | New foreign domicile registrations | Þjóðskrá | |
| ⬜ | Keflavík passengers | Isavia / Ferðamálastofa | |
| ⬜ | New car registrations — private vs corporate/rental | Samgöngustofa | |
| ⬜ | Cement sales | (public) | |
| ⬜ | Alfreð job listings | Alfreð (scraped) | |
| ⬜ | Gallup consumer confidence | Gallup | |
| ⬜ | Google Trends | scraped / non-API | |

---

## Quarterly

| S | Series | Source | DB table |
|---|---|---|---|
| ✅ | Real GDP / domestic demand (+ private consumption, investment; real + YoY) | Hagstofa | `national_accounts` |
| ✅ | Current account (BoP) | Seðlabankinn (SDDS feed) | `current_account` † |
| ⛔ | Terms of trade | Hagstofa | — PX-Web table stale at 2021 |
| ⬜ | Output-gap estimate | Seðlabankinn | |
| ⬜ | Pension-system foreign asset share vs ceiling | Seðlabankinn | |
| ⬜ | Reserves-adequacy components | Seðlabankinn | |
| ⬜ | Gallup corporate sentiment / hiring intentions | Gallup | |
| ⬜ | Trading-partner GDP / euro-area composite | OECD / Eurostat | |

> **† Rolling-window note:** the Seðlabankinn SDDS/NSDP feed (current account,
> reserves) serves only the last ~12 months, so these tables start shallow and
> **accrete history forward** via upsert on each scheduled run — there is no deep
> backfill from this endpoint. See `UNRESOLVED_SOURCES.md`.

---

## Event-driven (as published)

| S | Series | Source |
|---|---|---|
| ⬜ | Auction calendar + results + bid-to-cover | Lánamál |
| ⬜ | Insider filings | Nasdaq Iceland |
| ⬜ | Domestic earnings calendar + reported fundamentals | Nasdaq Iceland |

---

## Derived (computed downstream, never scraped)

| S | Series | Computed from |
|---|---|---|
| ➖ | Breakeven inflation (incl. 2y headline) | fitted RIKB nominal curve − fitted RIKS real curve |
| ➖ | Brent-in-ISK | Brent crude × ISK/USD |