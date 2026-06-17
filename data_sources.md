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

---

## Daily

| Series | Source |
|---|---|
| Policy-rate components — 7-day term deposit (headline), current account, overnight, collateralised lending | Seðlabankinn |
| All RIKB (nominal) government bond yields/prices, every outstanding series | Nasdaq Iceland / Lánamál |
| All RIKS (indexed) government bond yields/prices, every outstanding series | Nasdaq Iceland / Lánamál |
| Treasury bill (ríkisvíxlar) rates, all maturities | Nasdaq Iceland / Lánamál |
| REIBOR fixings — O/N, 1m, 3m, 6m | Nasdaq Iceland / Lánamál |
| ISK vs USD / EUR / GBP + trade-weighted index | Seðlabankinn |
| FX forwards | Seðlabankinn |
| Fed funds rate | FRED |
| US Treasury 2y / 10y | FRED |
| ECB deposit rate | ECB |
| Bund 2y / 10y | ECB |
| Brent crude | public |
| Aluminium | public |
| S&P 500 level + constituents (for breadth) | (market data) |
| Forward P/E + CAPE | (market data) |
| UCITS ETF closes | (market data) |
| OMXI + all Icelandic listed closes / volume / turnover | Nasdaq Iceland |

---

## Monthly

| Series | Source |
|---|---|
| Card turnover — domestic / abroad / foreign-in-Iceland | Seðlabankinn |
| New mortgage lending | Seðlabankinn |
| Bank lending to firms | Seðlabankinn |
| Foreign ownership of government bonds | Seðlabankinn |
| Reserves | Seðlabankinn |
| FX intervention | Seðlabankinn |
| CPI + core subindices | Hagstofa |
| Wage index | Hagstofa |
| VAT turnover by sector (bi-monthly) | Hagstofa |
| Consumer-goods imports | Hagstofa |
| Investment-goods imports, ex ships/aircraft | Hagstofa |
| Marine export values | Hagstofa |
| Marine price index | Hagstofa |
| Aluminium export volumes | Hagstofa |
| Hotel overnight stays | Hagstofa |
| Monthly LFS (labour force survey) | Hagstofa |
| New company registrations | Hagstofa |
| Insolvencies | Hagstofa |
| Registered unemployment + register level + vacancies | Vinnumálastofnun |
| House price index + purchase agreements + time-on-market | HMS |
| New foreign domicile registrations | Þjóðskrá |
| Keflavík passengers | Isavia / Ferðamálastofa |
| New car registrations — private vs corporate/rental | Samgöngustofa |
| Cement sales | (public) |
| Alfreð job listings | Alfreð (scraped) |
| Gallup consumer confidence | Gallup |
| Google Trends | scraped / non-API |

---

## Quarterly

| Series | Source |
|---|---|
| Real GDP / domestic demand | Hagstofa |
| Current account | Hagstofa |
| Terms of trade | Hagstofa |
| Output-gap estimate | Seðlabankinn |
| Pension-system foreign asset share vs ceiling | Seðlabankinn |
| Reserves-adequacy components | Seðlabankinn |
| Gallup corporate sentiment / hiring intentions | Gallup |
| Trading-partner GDP / euro-area composite | OECD / Eurostat |

---

## Event-driven (as published)

| Series | Source |
|---|---|
| Auction calendar + results + bid-to-cover | Lánamál |
| Insider filings | Nasdaq Iceland |
| Domestic earnings calendar + reported fundamentals | Nasdaq Iceland |

---

## Derived (computed downstream, never scraped)

| Series | Computed from |
|---|---|
| Breakeven inflation (incl. 2y headline) | fitted RIKB nominal curve − fitted RIKS real curve |
| Brent-in-ISK | Brent crude × ISK/USD |