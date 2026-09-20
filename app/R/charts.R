# The chart constructor — every chart rule lives here ----
#
# One constructor serves all eleven line/area/step figures. Centralising it is
# what makes the rules hold by construction rather than by discipline: colour
# follows the entity (via LABELS$slot, never draw order), a legend appears
# exactly when there are two or more series, direct labels stay selective,
# gridlines stay solid hairlines, and every chart gets a crosshair tooltip.
#
# Deliberately NOT supported: a second y-axis. Two measures of different scale
# are two figures — the RIKB/RIKS separation the spec demands is the same rule.

# Series colour vector in the order the series will be drawn. Entities with a
# stored slot keep their colour whatever else is on screen; an `emphasis` series
# takes the accent and everything else recedes to gray.
#
# A single unnamed series (a bare value column such as "index") has no dictionary
# entry and takes the accent: it IS the subject of its chart, so the
# de-emphasis gray that unknown codes fall back to would be wrong.
chart_colours <- function(codes, emphasis = NULL) {
  if (!is.null(emphasis)) {
    return(ifelse(codes == emphasis, TOK$accent, TOK$deemph))
  }
  known <- codes %in% LABELS$code
  # Entities the dictionary does not carry — individual bonds, for instance —
  # still need stable, distinct colours. Fall back to the categorical slots in
  # the order the codes appear, which is fixed for a given chart.
  if (!all(known)) {
    out <- character(length(codes))
    out[known] <- unname(lbl_colour(codes[known]))
    n_unknown <- sum(!known)
    out[!known] <- TOK$slots[((seq_len(n_unknown) - 1L) %% length(TOK$slots)) + 1L]
    if (length(codes) == 1) return(TOK$accent)
    return(out)
  }
  unname(lbl_colour(codes))
}

chart_line <- function(df, y = "value", series = NULL, x = "date",
                       kind = c("line", "step", "area"),
                       x_type = c("time", "value"),
                       unit = "%", digits = 1, freq = c("day", "month", "quarter"),
                       emphasis = NULL,
                       end_labels = NULL,
                       markers = FALSE,
                       bands = NULL,
                       dashed = NULL,
                       deemph = NULL,
                       mark_areas = NULL,
                       baseline = NULL,
                       height = NULL) {
  kind   <- match.arg(kind)
  x_type <- match.arg(x_type)
  freq   <- match.arg(freq)

  codes <- if (is.null(series)) y else unique(df[[series]])
  # Draw in the dictionary's slot order so the legend and the stack never
  # reshuffle when a series is absent for part of the window.
  if (!is.null(series)) {
    ord <- order(match(codes, LABELS$code[!is.na(LABELS$slot)]), codes, na.last = TRUE)
    codes <- codes[ord]
  }
  cols <- chart_colours(codes, emphasis)

  # Wide by series so each becomes its own ECharts series. `dashed`/`deemph`
  # name flag columns in the SAME frame, so they are carried through only when
  # present rather than assumed.
  wide <- if (is.null(series)) {
    keep <- c(x, y, dashed, deemph)
    dplyr::select(df, dplyr::all_of(intersect(keep, names(df))))
  } else {
    df |>
      dplyr::select(dplyr::all_of(c(x, series, y))) |>
      tidyr::pivot_wider(names_from = dplyr::all_of(series),
                         values_from = dplyr::all_of(y))
  }
  wide <- dplyr::arrange(wide, .data[[x]])

  flags <- intersect(c(dashed, deemph), names(wide))
  val_cols <- setdiff(names(wide), c(x, flags))
  wide[val_cols] <- lapply(wide[val_cols], as.numeric)

  # The provisional/low-confidence overlays are drawn as extra series, so their
  # columns must exist BEFORE the frame is bound to the widget — e_charts_()
  # captures the data at construction and later columns are invisible to it.
  has_dashed <- !is.null(dashed) && dashed %in% names(wide)
  has_deemph <- !is.null(deemph) && deemph %in% names(wide)
  if (has_dashed) wide$.prov   <- ifelse(wide[[dashed]], wide[[y]], NA_real_)
  if (has_deemph) wide$.deemph <- ifelse(wide[[deemph]], wide[[y]], NA_real_)
  # The flags have done their job; they must not reach the widget or they turn
  # every row back into strings.
  wide <- wide[setdiff(names(wide), flags)]

  e <- echarts4r::e_charts_(wide, x, height = height)

  # Confidence bands: two washes of ONE hue (sequential), drawn first so the
  # median line sits on top. Built as a transparent lower bound plus a filled
  # ribbon, which is how ECharts stacks an interval without inventing a mark.
  if (!is.null(bands)) {
    for (i in seq_along(bands)) {
      b <- bands[[i]]
      e <- e |>
        echarts4r::e_line_(b[1], stack = paste0("band", i), symbol = "none",
                           lineStyle = list(opacity = 0), legend = FALSE,
                           silent = TRUE, areaStyle = list(opacity = 0),
                           tooltip = list(show = FALSE)) |>
        echarts4r::e_line_(b[2], stack = paste0("band", i), symbol = "none",
                           lineStyle = list(opacity = 0), legend = FALSE,
                           silent = TRUE,
                           areaStyle = list(color = TOK$accent,
                                            opacity = c(0.10, 0.18)[i]),
                           tooltip = list(show = FALSE))
    }
  }

  # Auto rule for direct labels: on for 2-4 series (they separate at the right
  # edge), off for a single series (the title names it) and for 5+ (labels
  # collide and the legend carries identity instead).
  n_ser <- length(codes)
  if (is.null(end_labels)) end_labels <- n_ser >= 2 && n_ser <= 4

  for (i in seq_along(codes)) {
    nm  <- codes[i]
    col <- cols[i]
    end_lab <- if (end_labels) {
      list(show = TRUE, formatter = lbl(nm), color = TOK$ink2,
           fontSize = 11, offset = c(4, 0))
    } else list(show = FALSE)
    sym <- if (markers) "circle" else "none"

    args <- list(
      e, nm,
      name = lbl(nm),
      symbol = sym, symbolSize = if (markers) 8 else 0,
      # 2px ring in the surface colour keeps overlapping markers legible.
      itemStyle = list(color = col, borderColor = TOK$surface, borderWidth = 2),
      lineStyle = list(color = col, width = 2),
      endLabel = end_lab,
      emphasis = list(focus = "series")
    )
    if (kind == "area") args$areaStyle <- list(color = col, opacity = 0.10)
    if (kind == "step") args$step <- "end"

    fn <- if (kind == "step") echarts4r::e_step_ else
          if (kind == "area") echarts4r::e_area_ else echarts4r::e_line_
    e <- do.call(fn, args)
  }

  # A dashed, hollow-marker tail for provisional values, and a gray segment for
  # low-confidence history. Both are drawn as extra series carrying only those
  # points, so the main line keeps one identity in the legend.
  if (has_dashed) {
    e <- echarts4r::e_line_(e, ".prov", name = lbl("provisional"), legend = FALSE,
                            symbol = "circle", symbolSize = 8,
                            itemStyle = list(color = TOK$surface,
                                             borderColor = TOK$accent, borderWidth = 2),
                            lineStyle = list(color = TOK$accent, width = 2, type = "dashed"),
                            tooltip = list(show = FALSE))
  }
  if (has_deemph) {
    e <- echarts4r::e_line_(e, ".deemph", legend = FALSE, symbol = "none",
                            lineStyle = list(color = TOK$deemph, width = 2),
                            tooltip = list(show = FALSE))
  }

  e <- e |>
    echarts4r::e_x_axis_(x, type = x_type, boundaryGap = FALSE,
                         axisLabel = list(hideOverlap = TRUE)) |>
    # e_charts_() seeds the x axis with a CATEGORY `data` array. Left in place
    # alongside type="time" it wins, and ECharts then cannot match the [date,
    # value] pairs to any category, so it draws the axes and nothing else — a
    # blank plot with an option object that inspects as perfectly correct.
    chart_drop_axis_data(x_type = x_type) |>
    # Ticks round to clean numbers; they carry the values that are not directly
    # labelled, so they should read as 6 and 4, not 6.00 and 4.00.
    echarts4r::e_y_axis(scale = TRUE,
                        axisLabel = list(formatter = htmlwidgets::JS(
                          "function(v){return APP.fmtAxis(v);}"))) |>
    echarts4r::e_tooltip(
      trigger = "axis",
      formatter = htmlwidgets::JS(sprintf(
        "function(p){return APP.tip(p, {unit:'%s', digits:%d, freq:'%s'});}",
        unit, digits, freq))) |>
    echarts4r::e_grid(left = 8, right = if (end_labels) 84 else 16,
                      top = 16, bottom = 8, containLabel = TRUE)

  # ISO date strings parse as UTC; without this, viewers west of UTC read every
  # point a day early.
  if (x_type == "time") e <- echarts4r::e_utc(e)

  # Legend exactly when identity is genuinely ambiguous.
  e <- if (n_ser >= 2) {
    # Icon shape comes from the registered theme; passing `icon` here would be
    # read as one-icon-per-item and errors when the counts differ.
    echarts4r::e_legend(e, top = 0, left = 0)
  } else echarts4r::e_legend(e, show = FALSE)

  if (!is.null(baseline)) {
    e <- echarts4r::e_mark_line(
      e, data = list(yAxis = baseline), silent = TRUE, symbol = "none",
      lineStyle = list(color = TOK$baseline, width = 1, type = "solid"),
      label = list(show = FALSE))
  }

  # Recession washes sit behind the data as areas, never as dashed rules.
  #
  # Set on the series directly rather than through e_mark_area(): that helper
  # wraps whatever it is given in another list, so a list of from/to PAIRS comes
  # out double-nested. ECharts then fails to read the markArea and abandons the
  # whole series — the line disappears while the axes still draw, which looks
  # like a styling bug rather than a malformed option.
  if (!is.null(mark_areas) && nrow(mark_areas)) {
    pairs <- lapply(seq_len(nrow(mark_areas)), function(i) list(
      list(xAxis = format(mark_areas$from[i], "%Y-%m-%d")),
      list(xAxis = format(mark_areas$to[i],   "%Y-%m-%d"))))
    e$x$opts$series[[1]]$markArea <- list(
      silent = TRUE, itemStyle = list(color = TOK$wash), data = pairs)
  }

  e$x$theme <- "editorial"
  e$x$mainOpts$locale <- "IS"
  chart_fix_values(e)
}

# Drop the category `data` array that e_charts_() seeds onto the x axis. A time
# (or value) axis derives its scale from the series points, and leaving the
# category list in place silently suppresses the marks.
chart_drop_axis_data <- function(e, x_type) {
  if (x_type == "category") return(e)
  e$x$opts$xAxis <- lapply(e$x$opts$xAxis, function(ax) { ax$data <- NULL; ax })
  e
}

# echarts4r serialises each point by pasting the row into a CHARACTER vector, so
# a y value reaches the browser as a string. ECharts copes with a short one
# ("1.25") but not with full double precision ("0.72010043") on a time axis: it
# resolves to no coordinate and the series is simply not drawn — a blank plot
# whose option object inspects as entirely correct, which makes this a
# particularly easy failure to misread as a styling problem.
#
# Converting each value back to a real JSON number removes the ambiguity, and
# rounding first keeps the payload small. `unbox` keeps a scalar scalar rather
# than a one-element array.
chart_fix_values <- function(e, digits = 6) {
  e$x$opts$series <- lapply(e$x$opts$series, function(s) {
    if (!is.null(s$data)) {
      s$data <- lapply(s$data, function(p) {
        v <- if (!is.null(p$value)) p$value else p
        if (length(v) >= 2) {
          num <- suppressWarnings(as.numeric(v[2]))
          p$value <- list(jsonlite::unbox(v[1]),
                          if (is.na(num)) NULL else jsonlite::unbox(round(num, digits)))
        }
        p
      })
    }
    s
  })
  e
}
