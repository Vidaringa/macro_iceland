# Design tokens — the SINGLE source of truth for the app's look ----
#
# This file is the only place colours, type and chrome are defined. Everything
# downstream is generated from TOKENS: the CSS custom properties injected into
# the template head, the ECharts theme registered by www/js/app.js, the
# reactable theme, and the sparkline colours in tiles.R. There is deliberately
# no tokens.css — a second copy of these values would drift.
#
# Palette: the validated editorial instance (dataviz reference palette).
# Verified with scripts/validate_palette.js on the light surface #fcfcfb:
# ALL CHECKS PASS (adjacent CVD ΔE ≥ 8, normal-vision ΔE ≥ 15, chroma floor,
# lightness band). Three slots sit below 3:1 contrast on the light surface —
# the relief rule applies, and every figure ships a table twin (figure.R), so
# no value is reachable by colour alone. Re-run the validator before changing
# ANY hex here, and again for the dark set before the dark-mode flip.
#
# `dark` is a placeholder set kept structurally identical to `light` so dark
# mode is a token swap plus a validator run, never a rebuild.

TOKENS <- list(
  light = list(
    surface  = "#fcfcfb",  # chart surface
    page     = "#f9f9f7",  # page plane behind cards
    ink      = "#0b0b0b",  # primary text
    ink2     = "#52514e",  # secondary text
    muted    = "#898781",  # axis / labels
    grid     = "#e1e0d9",  # hairline gridline
    baseline = "#c3c2b7",  # axis / zero rule
    border   = "rgba(11,11,11,0.10)",
    accent   = "#2a78d6",  # categorical slot 1 — the one accent
    deemph   = "#b6b5ae",  # de-emphasis gray (emphasis form, pre-2004 segment)
    wash     = "#eef3fb",  # recession / markArea wash
    slots    = c("#2a78d6", "#eb6834", "#1baf7a", "#eda100",
                 "#e87ba4", "#008300", "#4a3aa7", "#e34948")
  ),
  # Placeholder — NOT yet validated against the dark surface. Do not ship.
  dark = list(
    surface  = "#1a1a19",
    page     = "#0d0d0d",
    ink      = "#ffffff",
    ink2     = "#c3c2b7",
    muted    = "#898781",
    grid     = "#2c2c2a",
    baseline = "#383835",
    border   = "rgba(255,255,255,0.10)",
    accent   = "#3987e5",
    deemph   = "#55544f",
    wash     = "#15202e",
    slots    = c("#3987e5", "#d95926", "#199e70", "#c98500",
                 "#d55181", "#008300", "#9085e9", "#e66767")
  )
)

# Active token set. Light only in v1; the dark flip swaps this and re-emits.
TOK <- TOKENS$light

# CSS custom properties for the template head. Written as :root{} so app.css is
# authored entirely against var(--…) and the dark flip touches one block.
TOKENS_CSS <- paste0(
  ":root{",
  "--surface:", TOK$surface, ";",
  "--page:", TOK$page, ";",
  "--ink:", TOK$ink, ";",
  "--ink2:", TOK$ink2, ";",
  "--muted:", TOK$muted, ";",
  "--grid:", TOK$grid, ";",
  "--baseline:", TOK$baseline, ";",
  "--border:", TOK$border, ";",
  "--accent:", TOK$accent, ";",
  "--deemph:", TOK$deemph, ";",
  "--wash:", TOK$wash, ";",
  paste0("--slot-", seq_along(TOK$slots), ":", TOK$slots, ";", collapse = ""),
  "--shiny-fade-opacity:.6;",
  "}"
)

# ECharts theme, registered client-side by app.js. echarts4r's e_theme() points
# at a themes/<name>.js inside the installed package, which does not exist for a
# custom name, so the theme is handed over as JSON and registered by our own
# script instead; charts then set e$x$theme directly (see charts.R).
# animation = FALSE is deliberate: the draw-in tween is what reads as a "flash"
# when a chart re-renders, which is exactly the cheap feeling to avoid.
ECHARTS_THEME <- list(
  color = unname(TOK$slots),
  backgroundColor = "transparent",
  animation = FALSE,
  textStyle = list(
    fontFamily = "Inter, system-ui, -apple-system, 'Segoe UI', sans-serif",
    color = TOK$ink2
  ),
  title = list(show = FALSE),
  legend = list(
    icon = "roundRect",
    itemWidth = 10, itemHeight = 10, itemGap = 18,
    textStyle = list(color = TOK$ink2, fontSize = 12)
  ),
  grid = list(containLabel = TRUE, left = 8, right = 16, top = 16, bottom = 8),
  categoryAxis = list(
    axisLine  = list(show = TRUE, lineStyle = list(color = TOK$baseline, width = 1)),
    axisTick  = list(show = FALSE),
    axisLabel = list(color = TOK$muted, fontSize = 11),
    splitLine = list(show = FALSE)
  ),
  valueAxis = list(
    axisLine  = list(show = FALSE),
    axisTick  = list(show = FALSE),
    axisLabel = list(color = TOK$muted, fontSize = 11),
    # Hairline, SOLID, one step off the surface. Never dashed: dashing reads as
    # "projection" or "threshold" when it is only a grid.
    splitLine = list(show = TRUE,
                     lineStyle = list(color = TOK$grid, width = 1, type = "solid"))
  ),
  timeAxis = list(
    axisLine  = list(show = TRUE, lineStyle = list(color = TOK$baseline, width = 1)),
    axisTick  = list(show = FALSE),
    axisLabel = list(color = TOK$muted, fontSize = 11),
    splitLine = list(show = FALSE)
  ),
  line = list(
    smooth = FALSE,
    symbol = "none",
    lineStyle = list(width = 2, cap = "round", join = "round")
  ),
  tooltip = list(
    backgroundColor = TOK$surface,
    borderColor = TOK$grid,
    borderWidth = 1,
    padding = c(8, 10),
    textStyle = list(color = TOK$ink, fontSize = 12),
    axisPointer = list(
      type = "cross",
      lineStyle = list(color = TOK$baseline, width = 1, type = "solid"),
      crossStyle = list(color = TOK$baseline, width = 1, type = "solid"),
      label = list(backgroundColor = TOK$ink2)
    )
  )
)

# Icelandic locale for ECharts axis/tooltip date formatting. Supplied explicitly
# because the container has no is_IS system locale — month names must never come
# from the OS.
ECHARTS_LOCALE_IS <- list(
  time = list(
    month = c("janúar", "febrúar", "mars", "apríl", "maí", "júní",
              "júlí", "ágúst", "september", "október", "nóvember", "desember"),
    monthAbbr = c("jan", "feb", "mar", "apr", "maí", "jún",
                  "júl", "ágú", "sep", "okt", "nóv", "des"),
    dayOfWeek = c("sunnudagur", "mánudagur", "þriðjudagur", "miðvikudagur",
                  "fimmtudagur", "föstudagur", "laugardagur"),
    dayOfWeekAbbr = c("sun", "mán", "þri", "mið", "fim", "fös", "lau")
  )
)

# reactable theme — the table twin must look like the same publication as the
# charts, not a default HTML table. Set once via options(reactable.theme=).
REACTABLE_THEME <- reactable::reactableTheme(
  color = TOK$ink,
  backgroundColor = TOK$surface,
  borderColor = TOK$grid,
  stripedColor = TOK$page,
  highlightColor = TOK$wash,
  cellPadding = "6px 10px",
  style = list(
    fontFamily = "Inter, system-ui, -apple-system, 'Segoe UI', sans-serif",
    fontSize = "13px",
    # Columns of numbers align vertically, so tabular figures belong here —
    # and only here (hero and tile values stay proportional).
    fontVariantNumeric = "tabular-nums"
  ),
  headerStyle = list(
    fontWeight = 600, fontSize = "11px", letterSpacing = "0.04em",
    textTransform = "uppercase", color = TOK$muted,
    borderBottom = paste0("1px solid ", TOK$baseline)
  )
)

REACTABLE_LANG <- reactable::reactableLang(
  noData = "Engin gögn",
  pageNext = "Næsta", pagePrevious = "Fyrri",
  pageNumbers = "{page} af {pages}",
  pageInfo = "{rowStart}–{rowEnd} af {rows}"
)

# Recession / crisis windows shaded on long-history charts. Icelandic dating:
# the 2008 banking collapse through the 2009 contraction, and the COVID stop.
RECESSIONS <- tibble::tibble(
  from = as.Date(c("2008-09-01", "2020-02-01")),
  to   = as.Date(c("2009-12-01", "2020-08-01"))
)

# A heat-index month with fewer than this share of its 19 indicators observed is
# drawn as a provisional tail (dashed, hollow marker) and annotated. The ragged
# edge is real and hiding it would be the dishonest choice.
PROVISIONAL_SHARE <- 0.5
