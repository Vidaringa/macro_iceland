# Display labels — the ONLY place Icelandic strings live ----
#
# The database layer is English snake_case and series codes are UPPERCASE; this
# file maps those codes to what a reader sees. Keeping every string here is what
# makes an English UI a translation job later rather than a rewrite: add the
# `en` column values, flip APP_LANG, ship.
#
# Columns:
#   code   the DB value (series code, group, tenor, source) or a UI/page key
#   kind   page | series | group | tenor | source | ui   (namespaces the code)
#   is/en  display text
#   unit   axis/tooltip unit, "" when dimensionless
#   slot   FIXED categorical colour position for this entity, NA when not plotted.
#          Colour follows the entity, never its rank — a filter that drops a
#          series must never repaint the survivors, so the slot is stored here
#          rather than assigned at draw time.
#   slug   URL fragment for pages (Icelandic, EN-ready)

LABELS <- tibble::tribble(
  ~code,                    ~kind,     ~is,                              ~en,                          ~unit, ~slot, ~slug,

  # --- pages -----------------------------------------------------------------
  "overview",               "page",    "Yfirlit",                        "Overview",                   "",    NA,    "yfirlit",
  "heat",                   "page",    "Hitastig",                       "Heat index",                 "",    NA,    "hitastig",
  "policy",                 "page",    "Stýrivextir",                    "Policy rate",                "",    NA,    "styrivextir",
  "markets",                "page",    "Markaðir",                       "Markets",                    "",    NA,    "markadir",
  "forecasts",              "page",    "Spár",                           "Forecasts",                  "",    NA,    "spar",
  "about",                  "page",    "Aðferðafræði",                   "Methodology",                "",    NA,    "adferdafraedi",

  # --- heat-index groups (fixed order = fixed colours in the stack) ----------
  "consumption",            "group",   "Einkaneysla",                    "Consumption",                "",    1L,    NA,
  "labour",                 "group",   "Vinnumarkaður",                  "Labour market",              "",    2L,    NA,
  "housing",                "group",   "Húsnæði",                        "Housing",                    "",    3L,    NA,
  "external",               "group",   "Utanríkisviðskipti",             "External",                   "",    4L,    NA,
  "sentiment",              "group",   "Væntingar",                      "Sentiment",                  "",    5L,    NA,
  "financial",              "group",   "Fjármálaleg skilyrði",           "Financial conditions",       "",    6L,    NA,

  # --- forecast readings (a third source appears here when A2 gains it) ------
  "bvar",                   "source",  "BVAR-dreifispá",                 "BVAR density",               "%",   1L,    NA,
  "market",                 "source",  "Markaðsvænting",                 "Market-implied",             "%",   2L,    NA,
  "reaction",               "source",  "Viðbragðsfall",                  "Reaction function",          "%",   3L,    NA,

  # --- BVAR model variables (forecast_macro.variable / forecast_fx.series) ---
  # Units differ per variable, which is why forecast_macro stores none: the
  # dictionary is the single place that knows a heat factor is a z-score and an
  # output gap is a percentage of potential.
  "infl",                   "variable", "Verðbólga",                     "Inflation",                  "%",   1L,    NA,
  "heat",                   "variable", "Hitastig hagkerfisins",         "Heat index",                 "",    1L,    NA,
  "gap",                    "variable", "Framleiðsluspenna",             "Output gap",                 "%",   1L,    NA,
  "d_ltwi",                 "variable", "Gengisbreyting",                "ISK monthly change",         "%",   1L,    NA,
  "policy_rate",            "variable", "Stýrivextir",                   "Policy rate",                "%",   1L,    NA,
  "ecb",                    "variable", "Innlánsvextir ECB",             "ECB deposit rate",           "%",   1L,    NA,

  # --- REIBOR tenors ---------------------------------------------------------
  "O/N",                    "tenor",   "O/N",                            "O/N",                        "%",   1L,    NA,
  "1M",                     "tenor",   "1 mán.",                         "1M",                         "%",   2L,    NA,
  "3M",                     "tenor",   "3 mán.",                         "3M",                         "%",   3L,    NA,
  "6M",                     "tenor",   "6 mán.",                         "6M",                         "%",   4L,    NA,

  # --- policy-rate corridor (emphasis form: DEPOSIT_7D accent, rest gray) ----
  "DEPOSIT_7D",             "series",  "Innlánsvextir, 7 daga",          "7-day deposit rate",         "%",   1L,    NA,
  "COLLAT_LENDING_7D",      "series",  "Veðlán, 7 daga",                 "7-day collateralised loans", "%",   NA,    NA,
  "OVERNIGHT_LENDING",      "series",  "Daglán",                         "Overnight lending",          "%",   NA,    NA,
  "CURRENT_ACCOUNT",        "series",  "Viðskiptareikningar",            "Current accounts",           "%",   NA,    NA,

  # --- heat-index inputs (the 19 that reach the model) ----------------------
  "HOTEL_NIGHTS",           "series",  "Hótelgistinætur",                "Hotel nights",               "",    NA,    NA,
  "TOURIST_CONSUMPTION",    "series",  "Kortavelta ferðamanna",          "Tourist card turnover",      "",    NA,    NA,
  "CARD_TURNOVER_HH_DOMESTIC", "series", "Kortavelta heimila innanlands", "Household card turnover",   "",    NA,    NA,
  "LFS_EMPLOYED",           "series",  "Fjöldi starfandi",               "Employment",                 "",    NA,    NA,
  "LFS_UNEMPLOYMENT",       "series",  "Atvinnuleysi",                   "Unemployment",               "%",   NA,    NA,
  "LFS_PARTICIPATION",      "series",  "Atvinnuþátttaka",                "Participation rate",         "%",   NA,    NA,
  "VAT_TURNOVER_TOTAL",     "series",  "Velta skv. VSK-skýrslum",        "VAT turnover",               "",    NA,    NA,
  "HOUSE_PRICE_INDEX",      "series",  "Íbúðaverð",                      "House prices",               "",    NA,    NA,
  "RESIDENTIAL_INVESTMENT", "series",  "Íbúðafjárfesting",               "Residential investment",     "",    NA,    NA,
  "CONSUMER_CONFIDENCE",    "series",  "Væntingavísitala Gallup",        "Consumer confidence",        "",    NA,    NA,
  "TWI",                    "series",  "Gengisvísitala",                 "Trade-weighted index",       "",    NA,    NA,
  "INVEST_IMPORTS_EX_SHIPS_AIRCRAFT", "series", "Innflutningur fjárfestingarvara", "Investment goods imports", "", NA, NA,
  "CONSUMER_IMPORTS",       "series",  "Innflutningur neysluvara",       "Consumer goods imports",     "",    NA,    NA,
  "ALUMINIUM_EXPORT_TONS",  "series",  "Álútflutningur",                 "Aluminium exports",          "t",   NA,    NA,
  "MARINE_EXPORT_VALUE",    "series",  "Sjávarafurðaútflutningur",       "Marine exports",             "",    NA,    NA,
  "MARINE_PPI_index",       "series",  "Verð sjávarafurða",              "Marine product prices",      "",    NA,    NA,
  "NEW_REGISTRATIONS",      "series",  "Nýskráningar fyrirtækja",        "New company registrations",  "",    NA,    NA,
  "BANKRUPTCIES",           "series",  "Gjaldþrot",                      "Bankruptcies",               "",    NA,    NA,
  "BANK_LOANS_CORPORATES",  "series",  "Útlán til fyrirtækja",           "Corporate bank loans",       "",    NA,    NA,
  "BANK_NEW_MORTGAGE_HH_TOTAL", "series", "Ný íbúðalán",                 "New mortgages",              "",    NA,    NA,
  "DOMESTIC_DEMAND_real",   "series",  "Þjóðarútgjöld",                  "Domestic demand",            "",    NA,    NA,

  # --- macro series used on the cycle strip / tiles --------------------------
  "GDP_yoy",                "series",  "Landsframleiðsla",               "GDP",                        "%",   1L,    NA,
  "CPI_change_A",           "series",  "Verðbólga",                      "CPI inflation",              "%",   1L,    NA,
  "CPI_index",              "series",  "Vísitala neysluverðs",           "CPI index",                  "",    NA,    NA,
  "HOUSE_PRICE_YOY",        "series",  "Íbúðaverð",                      "House prices",               "%",   1L,    NA,
  "CARD_YOY",               "series",  "Kortavelta heimila",             "Household card turnover",    "%",   1L,    NA,
  "HOTEL_YOY",              "series",  "Hótelgistinætur",                "Hotel nights",               "%",   1L,    NA,

  # --- FX / external ---------------------------------------------------------
  "EUR",                    "series",  "EUR",                            "EUR",                        "kr.", 1L,    NA,
  "USD",                    "series",  "USD",                            "USD",                        "kr.", 2L,    NA,
  "GBP",                    "series",  "GBP",                            "GBP",                        "kr.", 3L,    NA,
  "ECB_DEPO",               "series",  "Innlánsvextir ECB",              "ECB deposit rate",           "%",   1L,    NA,
  "FED_FUNDS",              "series",  "Stýrivextir Fed",                "Fed funds rate",             "%",   2L,    NA,
  "UST_2Y",                 "series",  "Bandarísk ríkisbréf, 2 ára",     "UST 2y",                     "%",   3L,    NA,
  "UST_10Y",                "series",  "Bandarísk ríkisbréf, 10 ára",    "UST 10y",                    "%",   4L,    NA,

  # --- bond-ownership holders (table only in v1) -----------------------------
  "FOREIGN",                "series",  "Erlendir aðilar",                "Foreign",                    "",    NA,    NA,
  "PENSION_FUNDS",          "series",  "Lífeyrissjóðir",                 "Pension funds",              "",    NA,    NA,
  "BANKS",                  "series",  "Bankar",                         "Banks",                      "",    NA,    NA,
  "MUTUAL_FUNDS",           "series",  "Verðbréfasjóðir",                "Mutual funds",               "",    NA,    NA,
  "INSURERS",               "series",  "Tryggingafélög",                 "Insurers",                   "",    NA,    NA,
  "COMPANIES",              "series",  "Fyrirtæki",                      "Companies",                  "",    NA,    NA,
  "INDIVIDUALS",            "series",  "Einstaklingar",                  "Individuals",                "",    NA,    NA,
  "OTHERS",                 "series",  "Aðrir",                          "Others",                     "",    NA,    NA,

  # --- UI chrome -------------------------------------------------------------
  "site_tagline",           "ui",      "Greining á íslenskum skuldabréfa- og þjóðhagsmarkaði", "Icelandic fixed-income & macro analysis", "", NA, NA,
  "nav_label",              "ui",      "Aðalvalmynd",                    "Main navigation",            "",    NA,    NA,
  "source_prefix",          "ui",      "Heimild",                        "Source",                     "",    NA,    NA,
  "data_to",                "ui",      "Gögn til",                       "Data to",                    "",    NA,    NA,
  "computed_at",            "ui",      "Reiknað",                        "Computed",                   "",    NA,    NA,
  "table_toggle",           "ui",      "Tafla",                          "Table",                      "",    NA,    NA,
  "no_data",                "ui",      "Gögn ekki tiltæk",               "Data unavailable",           "",    NA,    NA,
  "provisional",            "ui",      "Bráðabirgðatölur",               "Provisional",                "",    NA,    NA,
  "date",                   "ui",      "Dagsetning",                     "Date",                       "",    NA,    NA,
  "value",                  "ui",      "Gildi",                          "Value",                      "",    NA,    NA,
  "disconnected",           "ui",      "Tenging rofnaði — reyni aftur…", "Connection lost — reconnecting…", "", NA, NA,
  "latest_strip",           "ui",      "Nýjustu gögn",                   "Latest data",                "",    NA,    NA,
  "disclaimer",             "ui",      "Efnið er lýsandi greining, ekki fjárfestingarráðgjöf.", "Descriptive analytics, not investment advice.", "", NA, NA
)

# Look up display text for a code. Vectorised; falls back to the code itself so
# a series that appears in the data before it appears here (a newly issued bond)
# renders as its code rather than NA.
lbl <- function(code, field = APP_LANG) {
  m <- match(code, LABELS$code)
  out <- LABELS[[field]][m]
  ifelse(is.na(out), as.character(code), out)
}

# Unit string for a code ("" when dimensionless). Same fallback contract.
lbl_unit <- function(code) {
  m <- match(code, LABELS$code)
  out <- LABELS$unit[m]
  ifelse(is.na(out), "", out)
}

# Fixed colour for an entity, by its stored slot. Entities without a slot fall
# back to the de-emphasis gray, which is what the emphasis form wants anyway.
lbl_colour <- function(code) {
  m <- match(code, LABELS$code)
  slot <- LABELS$slot[m]
  ifelse(is.na(slot), TOK$deemph, TOK$slots[pmin(pmax(slot, 1L), length(TOK$slots))])
}

# Page metadata, in nav order.
PAGES <- LABELS[LABELS$kind == "page", c("code", "is", "en", "slug")]
