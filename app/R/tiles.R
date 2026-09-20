# Stat tiles, sparklines and number formatting ----
#
# A single current value is a tile, not a one-bar chart. The hero variant is the
# one number the app leads with (the policy rate) — same sans as everything
# else, never a display or serif face, and proportional figures: tabular-nums
# makes a large standalone number look loose and belongs only in table columns.

# Icelandic number formatting: decimal comma, thin space as the thousands
# separator, unit after a thin space, em dash for a missing value.
fmt_num <- function(x, digits = 1, unit = "") {
  if (length(x) == 0 || is.na(x)) return("—")
  s <- formatC(x, format = "f", digits = digits, big.mark = " ",
               decimal.mark = ",")
  if (nzchar(unit)) paste0(s, " ", unit) else s
}

# A 12-point sparkline as inline SVG. Built here rather than pulled from a
# charting library because a tile trend is decoration on a number — it should
# cost nothing and carry no axis, tooltip or interaction.
spark_svg <- function(values, width = 96, height = 28) {
  v <- values[!is.na(values)]
  if (length(v) < 2) return(NULL)
  rng <- range(v)
  span <- if (diff(rng) == 0) 1 else diff(rng)
  pad <- 3
  xs <- seq(pad, width - pad, length.out = length(v))
  ys <- height - pad - (v - rng[1]) / span * (height - 2 * pad)
  pts <- paste(sprintf("%.1f,%.1f", xs, ys), collapse = " ")

  htmltools::HTML(sprintf(
    paste0('<svg class="spark" width="%d" height="%d" viewBox="0 0 %d %d" ',
           'aria-hidden="true" focusable="false">',
           '<polyline points="%s" fill="none" stroke="%s" stroke-width="1.5" ',
           'stroke-linejoin="round" stroke-linecap="round"/>',
           '<circle cx="%.1f" cy="%.1f" r="2.5" fill="%s"/></svg>'),
    width, height, width, height, pts, TOK$deemph,
    xs[length(xs)], ys[length(ys)], TOK$accent))
}

# label  what the number is
# value  pre-formatted string (callers use fmt_num so units stay consistent)
# delta  signed change, already formatted; shown with a direction arrow in
#        NEUTRAL ink — a rising policy rate is neither good nor bad, so status
#        colours would assert something the data does not say
stat_tile <- function(label, value, unit = NULL, delta = NULL,
                      delta_label = NULL, spark = NULL, hero = FALSE,
                      note = NULL) {
  arrow <- NULL
  if (!is.null(delta) && !is.na(delta) && is.numeric(delta)) {
    arrow <- if (delta > 0) "▲" else if (delta < 0) "▼" else "–"
    delta <- fmt_num(abs(delta), 2)
  }

  htmltools::tags$div(
    class = if (hero) "tile tile--hero" else "tile",
    htmltools::tags$p(class = "tile__label", label),
    htmltools::tags$p(
      class = "tile__value", value,
      if (!is.null(unit)) htmltools::tags$span(class = "tile__unit", unit)
    ),
    if (!is.null(arrow)) htmltools::tags$p(
      class = "tile__delta",
      htmltools::tags$span(class = "tile__arrow", arrow), " ", delta,
      if (!is.null(delta_label)) htmltools::tags$span(
        class = "tile__deltalab", paste0(" ", delta_label))
    ),
    if (!is.null(spark)) htmltools::tags$div(class = "tile__spark", spark),
    if (!is.null(note)) htmltools::tags$p(class = "tile__note", note)
  )
}

# Latest value of a series in a tidy (date, series, value) tibble, plus the
# change over `lag_days` and a monthly sparkline series. Used by every tile, so
# the extraction lives here rather than being repeated per page.
tile_stats <- function(df, code = NULL, lag_days = 30, n_spark = 12) {
  d <- if (is.null(code)) df else dplyr::filter(df, .data$series == code)
  d <- dplyr::arrange(d, .data$date)
  if (!nrow(d)) return(list(value = NA_real_, delta = NA_real_, spark = numeric()))

  last_val  <- dplyr::last(d$value)
  last_date <- dplyr::last(d$date)
  prior <- d$value[d$date <= last_date - lag_days]
  delta <- if (length(prior)) last_val - dplyr::last(prior) else NA_real_

  # One point per month keeps the sparkline readable whatever the frequency.
  spark <- d |>
    dplyr::mutate(m = lubridate::floor_date(.data$date, "month")) |>
    dplyr::group_by(.data$m) |>
    dplyr::summarise(v = dplyr::last(.data$value), .groups = "drop") |>
    dplyr::pull("v") |>
    utils::tail(n_spark)

  list(value = last_val, delta = delta, date = last_date, spark = spark)
}
