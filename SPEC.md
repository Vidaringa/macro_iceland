# SPEC.md — Analytical Specification

> **What this is.** This is the *functional / analytical* specification — what the platform
> computes and what every number means. It is the companion to `PROJECT.md`: that document
> says *how the system is wired* (layers, stack, Postgres-as-source-of-truth, Shiny rules);
> this one says *what analysis is carried out*, module by module, with inputs, method,
> outputs, conventions, and the legal scenario perturbations for each.
>
> **Who reads it.** A quant validating the methodology; a salesperson understanding what they
> sell; you, deciding whether a feature is in scope. None of them should need to read R to
> understand what the product does. No code lives here — only specifications.
>
> **How it's organised.** Part A specifies the **analytical spine** module by module, in
> computation-flow order (each module's outputs feed the next). Part B maps modules onto the
> **two product surfaces**. Part C is cross-cutting conventions. Part D is the scope ledger
> (what is explicitly in / out for launch).

---

## How to read a module

Every module in Part A is specified with the same fixed fields, so the document is scannable
and nothing important is left implicit:

- **Purpose** — the question this module answers, in one or two sentences.
- **Inputs** — which canonical Postgres series / upstream module outputs it consumes.
- **Method** — the model or calculation, described functionally (not as code).
- **Outputs** — what is written back to Postgres for the app to read (table-level).
- **Conventions & assumptions** — the decisions that change the numbers; the things a quant
  must agree with before trusting the output.
- **Scenario levers** — what an AM-tier user may perturb on this module. Per the
  fixed-model rule, users perturb *inputs and exogenous paths only* — never model
  specification. Modules with no user-facing lever say so.

---

# PART A — THE ANALYTICAL SPINE

The spine, as stated in `PROJECT.md`:

```
heat index  →  rate path  →  curve  →  bond returns
                                          ├→ relative value
                                          └→ portfolio analytics
              (parallel: equity / FX / external layer)
```

Computation flows left to right. The heat index reads the real economy and feeds the
policy-rate path; the rate path anchors the fitted curves; the curves drive per-bond return
forecasts; bond returns feed relative value and portfolio analytics. The equity/FX/external
layer runs alongside and shares macro inputs but is not on the critical path to bond returns.

---

## A1 — Heat index (coincident state of the economy)

**Purpose.** A single coincident read of how hot or cold the Icelandic real economy is right
now, distilled from many mixed-frequency indicators into one comparable index plus a
decomposition showing what is driving it. It is the macro tier's headline and the first link
in the rate-path chain.

**Inputs.** The heat-index input family in Postgres — the monthly/quarterly real-activity and
demand series: card turnover (domestic / abroad / foreign-in-Iceland), new mortgage lending,
bank lending to firms, VAT turnover by sector, consumer- and investment-goods imports (the
latter ex ships/aircraft), marine and aluminium export values/volumes, hotel overnight stays
and Keflavík passengers, LFS and registered unemployment / vacancies, house-price index and
purchase agreements, new company registrations and insolvencies, new car registrations
(private vs corporate/rental), cement sales, consumer and corporate confidence, and the
quarterly national-accounts series (GDP, domestic demand). All as stored canonical series.

**Method.** A dynamic factor model with a Kalman filter extracts a common coincident factor
from the standardised indicators. The model is built to tolerate the ragged edge — series
arrive on irregular schedules and the filter handles missing tails without breaking. The
extracted factor is normalised to an interpretable scale (mean/scale stated as a convention
below) and signed so that higher = hotter. A decomposition attributes the current index level
and its recent change to indicator groups (consumption, labour, housing, external, sentiment),
so the headline number is explainable rather than a black box.

**Outputs.** The heat-index series itself (level over time); the contribution/decomposition
series by indicator group; and the per-indicator standardised inputs as filtered (so the app
can show which series are running hot or cold). Written to the heat-index output tables.

**Conventions & assumptions.** Standardisation window and the index's normalised scale must be
fixed once and held constant, or the level is not comparable across vintages. Ex-ships/aircraft
adjustment on investment-goods imports is applied before the series enters the model. Vintages
are respected — re-running does not silently overwrite history. The index is *coincident*, not
a forecast: it states where the economy is, not where it is going.

**Scenario levers.** None directly. The heat index is an estimate of the current state; users
do not perturb the present. Its role downstream is as a conditioning input to the rate path,
which is where scenario levers attach.

---

## A2 — Policy-rate path (the rate forecast)

**Purpose.** A forward path of the Central Bank policy rate with uncertainty — the single most
important forecast in the product. It drives the short end of the curve, feeds every bond
return, and underlies the cost-of-capital scenarios the macro tier sells.

**Inputs.** The policy-rate series and its components (7-day term deposit headline, current-
account, overnight, collateralised lending). The heat-index factor (A1). Inflation (CPI and
core subindices), the wage index, FX (ISK trade-weighted and bilateral), output-gap estimate,
and the external rate anchors (Fed funds, ECB depo, US/Bund yields). Market-implied
expectations from the curve where available.

**Method.** A Bayesian VAR is the primary engine: it produces a density forecast of the policy
rate (a fan, not a point), conditioned on the macro state. Two complementary readings sit
alongside it — a market-implied path backed out of the money-market / short curve, and a
reaction-function path from an ordered-probit model of MPC decisions (the probability of
hike / hold / cut at coming meetings given the macro state). The three are presented together
so a user sees model, market, and rule-based views side by side. Posterior draws from the BVAR
are persisted so scenarios can re-weight them without re-fitting.

**Outputs.** The policy-rate density forecast (central path + bands over horizon); MPC decision
probabilities per upcoming meeting (the three readings: market-implied, BVAR-density,
reaction-function); and the persisted posterior draws for scenario re-weighting. Written to the
rate-path and MPC-probability output tables.

**Conventions & assumptions.** The model is fixed and validated — users never re-specify priors,
lags, or variables (that would void the track record and shift forecasting liability onto user
error). The forecast is a distribution; the central path is a summary of it, never the whole
story. Horizon and band definitions (which percentiles) fixed once.

**Scenario levers.** This is the primary scenario surface. A user sets an exogenous path or
shock — *MPC cuts faster than the model expects*, *inflation runs hotter*, *ISK depreciates
10%* — and the engine re-weights / filters the existing posterior draws to show the resulting
rate path. Fast, server-side, no re-estimation. The legal levers are exogenous input paths and
shocks; the illegal ones are anything that changes the model itself.

---

## A3 — Yield curves: nominal, real, and breakeven

**Purpose.** Smooth fitted term structures for the ISK government market — a nominal curve from
the RIKB series and a real curve from the RIKS series — plus the breakeven-inflation curve that
falls out of their difference. The curves turn a sparse scatter of individual bond yields into
continuous functions of maturity, which is what every downstream calculation needs.

**Inputs.** Daily closing yields for every outstanding RIKB (nominal) and RIKS (indexed) series
(`bonds_daily`), their static attributes (`bond_attributes` — coupon, maturity, day count,
indexation), T-bill (ríkisvíxlar) rates to anchor the short end, and the policy rate as the
front anchor. The RIKS additionally need base index, indexation lag, and any deflation floor
from attributes.

**Method.** A parametric curve (Nelson-Siegel, or Svensson where the extra factor is warranted)
is fitted to the RIKB yields for the nominal curve and, separately, to the RIKS yields for the
real curve. The fits yield interpretable level / slope / curvature factors (these feed back as
inputs the BVAR can use). The short end is anchored with T-bill rates because the bond sample
is thin there. The **breakeven-inflation term structure** is the difference between the fitted
nominal and fitted real curves — a primary output, not a byproduct — with the headline 2-year
breakeven derived from it. Each bond's deviation from its fitted curve (the residual) is the
rich/cheap signal consumed by A5.

**Outputs.** Fitted nominal curve, fitted real curve, and breakeven curve (each as a set of
points / parameters over the maturity grid, daily); the level/slope/curvature factors; per-bond
fitted-yield and residual (rich/cheap) series. Written to the curve output tables. The derived
2-year breakeven is computed downstream of the daily pull, not scraped.

**Conventions & assumptions.** Thin market: with only a handful of RIKB and RIKS series, the fit
is data-light, especially at the short end — hence the T-bill anchor, which must be decided and
held. Stale / illiquid prices distort a parametric fit badly; a stale-price flag (from the
ingestion layer) must gate which points enter the fit. RIKS yields are *real* yields and are
never compared directly against nominal RIKB yields — the gap *is* breakeven inflation. Choice
of Nelson-Siegel vs Svensson per curve fixed once and validated.

**Scenario levers.** Indirect. Users do not hand-fit curves. A scenario set on the rate path
(A2) re-anchors the curve front end and reshapes it through the model linkage; the reshaped
curve is what flows into bond returns. Direct curve-shape shocks (e.g. *bear-steepening +50bp
at the long end*) are a candidate lever — see D for scope.

---

## A4 — Per-bond analytics: cash flows, pricing, risk, carry & roll

**Purpose.** For every outstanding bond, reconstruct its exact cash flows and compute its price,
risk sensitivities, and the return it earns from time and curve movement. This is the table-
stakes layer — correct here or nothing downstream is trustworthy — and the bridge from a curve
forecast to a per-bond return forecast.

**Inputs.** `bond_attributes` (coupon rate and frequency, issue/maturity dates, day count,
redemption value, embedded-option flags, indexation parameters), `bonds_daily` (price/yield),
the fitted curves (A3), CPI for RIKS indexation uplift, and the settlement convention.

**Method.**
- *Cash-flow reconstruction.* From attributes, build each bond's coupon schedule and redemption.
  Apply the day-count convention (actual/actual ICMA for the government bonds) and the
  settlement date to compute accrued interest and the clean-vs-dirty price split. For RIKS,
  apply the indexation uplift from the base index and the indexation lag, honouring any
  deflation floor at redemption.
- *Risk sensitivities.* Modified duration, convexity, DV01, and key-rate durations (sensitivity
  to movements at specific points on the curve, not just a parallel shift).
- *Carry & roll-down.* The return a bond earns purely from aging down a static curve over a
  horizon — carry (coupon + pull-to-par) plus roll-down (re-pricing at the shorter maturity
  point on an unchanged curve). In a steep curve this is a large share of expected return and
  AM clients expect it explicitly.
- *Per-bond return forecast.* Combine the forecast curve (A3, itself driven by the rate path
  A2) with each bond's sensitivities to produce a forecast total return / yield per bond over
  the horizon — the output the AM tier trades on.

**Outputs.** Per bond, per day: clean/dirty price, accrued interest, reconstructed cash-flow
schedule, modified duration, convexity, DV01, key-rate durations, carry, roll-down, and the
horizon return forecast. Written to the per-bond analytics output tables.

**Conventions & assumptions.** Settlement convention (T+1 / T+2) confirmed once and applied
uniformly. Day count is actual/actual ICMA for the government series; never assume — read it
from attributes per series, as RIKB and RIKS label it differently. Indexation lag and base
index are per-RIKS-series and must come from attributes, not a global constant. A single
mispriced input bond corrupts the curve and therefore every bond's forecast — the stale-price
gate from A3 applies.

**Scenario levers.** Inherited from A2/A3 — a rate-path or curve scenario reshapes the forecast
curve, and these per-bond numbers re-compute against it. No independent lever at the bond level
beyond choosing the horizon.

---

## A5 — Relative value (rich / cheap)

**Purpose.** Identify which bonds are trading rich or cheap relative to the rest of the curve
and relative to history — the desk's "what should I buy / sell" signal.

**Inputs.** Per-bond fitted-yield residuals from A3 (the deviation of each bond's actual yield
from the fitted curve), the historical residual series, and the breakeven curve (for RIKB-vs-
RIKS / breakeven relative value).

**Method.** A bond's residual to the fitted curve is its cross-sectional rich/cheap measure
(positive residual = cheap, trading at higher yield than the curve implies, and vice versa).
That residual is then placed in historical context — a z-score or percentile of the bond's own
residual history — so "cheap" means cheap versus its own norm, not just versus today's curve.
Breakeven relative value compares the market breakeven (A3) against its history and against the
model's inflation read, framing RIKB-vs-RIKS as a position (is breakeven itself rich or cheap).

**Outputs.** Per bond: current residual, residual z-score / percentile, and a rich/cheap
ranking across the curve. Breakeven percentile / z-score series. Written to the relative-value
output tables.

**Conventions & assumptions.** The history window for z-scores fixed once. Residuals are only
meaningful relative to a clean fit, so this module inherits A3's stale-price discipline.
Signals are descriptive analytics, not trade recommendations — framing matters for liability.

**Scenario levers.** None directly; relative value is a read on current and historical pricing.

---

## A6 — Portfolio / holdings analytics

**Purpose.** Lift the per-bond analytics to the level of an actual book: a user loads their
holdings and sees aggregate risk, scenario P&L on the real portfolio, and performance relative
to a benchmark. This is the single biggest recurring task an ISK fixed-income manager does by
hand in Excel, and the bridge from "great curve terminal" to "the tool I run my book on."

**Inputs.** A user-supplied holdings set (bond identifiers + nominal/market weights), the
per-bond analytics (A4), the forecast curves and scenarios (A2/A3), and a benchmark definition
(a recognised ISK government bond index or a user-defined custom index).

**Method.**
- *Aggregation.* Weight per-bond metrics up to portfolio level — portfolio duration, convexity,
  DV01, key-rate duration profile, yield, and breakeven-inflation exposure (the indexed share).
- *Scenario P&L on the book.* Push a rate-path / curve scenario (A2/A3) through the actual
  holdings and report the portfolio P&L surface — what the book is worth under each shock, not
  just a single bond.
- *Benchmark-relative.* Active duration, over/underweight by series and by curve segment, and
  tracking error versus the chosen benchmark.

**Outputs.** Portfolio-level aggregate risk metrics, the scenario-P&L surface for the book, and
benchmark-relative metrics (active positions, tracking error). These are user-session outputs
driven by user-supplied holdings — see the conventions note on persistence.

**Conventions & assumptions.** Holdings are user data, not canonical market series — the spec
must decide whether a book is persisted per user or held only for the session (a privacy and
data-ownership decision, flagged for resolution). Benchmark definition must be fixed and
documented or active/tracking numbers are meaningless. The indexed (RIKS) share of a book is
itself a breakeven-inflation position and is surfaced as such.

**Scenario levers.** Full inheritance of the A2/A3 scenario levers, now applied to the user's
own book rather than to single bonds — this is the lever set's most valuable expression for the
AM tier.

---

## A7 — Equity / FX / external layer (parallel)

**Purpose.** The breadth of market and external-balance analytics that round out the AM tier
and feed parts of the macro tier — equity market internals, FX, and the external position.
Runs alongside the bond spine, sharing macro inputs, but is not on the critical path to bond
returns.

**Inputs.** OMXI and all Icelandic listed closes / volume / turnover; S&P 500 level and
constituents (for breadth), forward P/E and CAPE, UCITS ETF closes; ISK bilateral and trade-
weighted rates and FX forwards; reserves, FX intervention, current account, terms of trade,
foreign ownership of government bonds, pension-system foreign-asset share vs ceiling. Insider
filings and the domestic earnings calendar as published.

**Method.**
- *Equity breadth & concentration.* Market-internals measures — how broad a move is (advancers
  vs decliners, share above moving averages) and how concentrated the index is — for both the
  domestic market and the S&P benchmark.
- *FX.* Trade-weighted and bilateral ISK tracking, implied/realised volatility, and the forward
  curve; Brent-in-ISK as a derived series (computed downstream, not scraped).
- *External.* Reserves adequacy, intervention, current account and terms of trade, and the
  pension-system foreign-asset headroom against its ceiling (a structural ISK-flow driver).

**Outputs.** Equity breadth / concentration metrics, FX vol and forward series, Brent-in-ISK,
and the external-balance series. Written to the respective output tables.

**Conventions & assumptions.** Brent-in-ISK and other derived crosses are computed after the
daily pull, never scraped. Breadth needs the full constituent set, not just the index level.

**Scenario levers.** The ISK FX shock is shared with A2 (an FX depreciation scenario conditions
the rate path). Equity/external are largely descriptive at launch.

---

# PART B — PRODUCT SURFACES (modules → what the user sees)

Two products, one engine. Both run off the spine above; they differ in which module outputs are
surfaced and at what depth.

**Macro tier** — *firms exposed to the cycle* (developers, corporate CFO/treasury). Surfaces
the conclusions and cost-of-capital implications, not the tradeable detail:
- Heat index and its decomposition (A1)
- Policy-rate path and MPC probabilities (A2)
- Krona / FX read and external context (A7, FX/external portions)
- GDP / cycle read (A1 + national accounts)
- Cost-of-capital scenarios (A2 applied to a borrowing cost, via the scenario engine)

**Asset-management tier** — *firms that trade the cycle* (bank AM desks, pension funds, union
funds, insurers). Everything in the macro tier **plus** the tradeable layer:
- Per-bond yield / return forecasts (A4)
- Scenario P&L (A2/A3 → A4, and at book level A6)
- Relative value (A5)
- Portfolio / holdings analytics (A6)
- Equity breadth / concentration suite and FX vol / forwards (A7)
- Forecast-data export, methodology and track-record pages

**One-off "buy report" PDF.** A snapshot of the latest research (heat index, rate path, curve,
breakeven, headline relative value) for buyers who want the quarterly view without a
subscription — and a likely third, cheaper shape for report-buyers who are not platform-buyers.

**The strategic note that the spec must not let drift:** the macro tier is the volume layer and
lead generator (more buyers, lower stakes, easier to approximate by others); the AM terminal is
the moat (the BVAR / curve / per-bond work is hard to replicate). The volume tier must fund, not
starve, the moat. Feature decisions should be tested against that.

---

# PART C — CROSS-CUTTING CONVENTIONS

These apply to every module and exist to keep outputs comparable and trustworthy. They restate,
in analytical terms, the rules `PROJECT.md` states in engineering terms.

- **Fixed, validated models; perturb inputs only.** No module lets a user change model
  specification. Scenario mode sets exogenous paths/shocks and re-weights existing posterior
  draws. This protects the track record and keeps forecasting liability off user error.
- **Forecasts are distributions.** Where a module forecasts (A2, and A4 returns derived from
  it), the object is a density / fan. A central path is a summary, never the whole answer; bands
  are defined by fixed percentiles.
- **Derived vs pulled.** Breakeven inflation and Brent-in-ISK (and any cross) are *computed*
  downstream of the daily pull, never scraped. The spec treats them as model outputs.
- **Real vs nominal must never be silently mixed.** RIKS yields are real; RIKB yields are
  nominal; their difference is breakeven. No table, chart, or comparison places them on the same
  axis without that framing.
- **Thin-market discipline.** Few series, illiquid points. Every curve-dependent module inherits
  one rule: stale / illiquid prices are flagged at ingestion and gated out of fits, and the
  short end is anchored with T-bills. A single bad point is assumed able to corrupt the curve and
  everything downstream.
- **Vintages respected.** Ragged-edge series update irregularly; re-running appends the tail and
  never silently overwrites history, so the DFM and BVAR see consistent vintages.
- **Conventions fixed once.** Standardisation windows, z-score history windows, forecast
  horizons and band percentiles, curve family per curve, settlement convention, benchmark
  definition — each is decided once, documented here, and held constant, or cross-vintage
  comparison breaks.

---

# PART D — SCOPE LEDGER

What is in and out for launch, stated plainly so a reader never has to guess whether an obvious
feature is missing by oversight or by decision.

**In scope for launch.**
- Full spine A1–A5 and A7 as specified.
- Portfolio / holdings analytics (A6) — aggregate risk, scenario P&L on the book, benchmark-
  relative metrics.
- Scenario engine on the rate path (A2) and its propagation through curve, bonds, and book.
- Both product surfaces (Part B) and the buy-report PDF.

**To be resolved (decisions this spec surfaces but does not yet fix).**
- *Holdings persistence (A6):* are user books stored per user, or session-only? Privacy and
  data-ownership decision.
- *Direct curve-shape shocks (A3):* is a user allowed to impose a curve-shape scenario (e.g.
  bear-steepening) independent of the rate-path lever, or only rate-path-driven reshaping?
- *Benchmark (A6):* which ISK government index is the default benchmark, and is custom-benchmark
  definition a launch feature?
- *Report-buyer tier:* is the buy-report a one-off PDF only, or a third cheaper subscription
  shape for firms that want the quarterly view but not the platform?

**Out of scope for launch (deferred).**
- "Power mode" model-tinkering (editing priors/variables/lags) — possible year-two feature for a
  proven paying client; explicitly excluded now to protect the track record.

---

*Companion document: `PROJECT.md` (architecture, stack, storage, Shiny rules). This spec is the
"what we build"; PROJECT.md is the "how it's wired".*