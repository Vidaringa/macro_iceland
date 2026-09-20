# Spár — the BVAR density forecasts ----
#
# One fan per modelled variable, from the same joint fit that produces the
# policy-rate path. These are densities, not point forecasts: the band is the
# product, and the median is a summary of it rather than a prediction.

# History + fan for one variable, in the shape policy_path_chart already uses.
# `hist` is a tidy (date, value) tibble of the observed series; `variable` keys
# into forecast_macro. The fan is anchored at h = 0 to the last observed value so
# the bands attach to the history line instead of floating beside it.
forecast_frame <- function(hist, variable, years = 5) {
  fc <- dat("forecast_macro")
  if (!nrow(fc) || !nrow(hist)) return(tibble::tibble())

  f <- dplyr::filter(fc, .data$variable == !!variable)
  if (!nrow(f)) return(tibble::tibble())

  cutoff <- max(hist$date) - round(years * 365.25)
  h <- hist |>
    dplyr::filter(.data$date >= cutoff) |>
    dplyr::transmute(date = .data$date, actual = .data$value)

  w <- f |>
    dplyr::select("forecast_date", "quantile", "value") |>
    tidyr::pivot_wider(names_from = "quantile", values_from = "value") |>
    dplyr::rename_with(~ paste0("q", sub("^0\\.", "", .x)), -"forecast_date") |>
    dplyr::rename(date = "forecast_date")
  names(w) <- sub("^q5$", "q50", names(w))

  out <- dplyr::full_join(h, w, by = "date") |> dplyr::arrange(.data$date)

  # Anchor: the last actual observation on or before the forecast origin.
  origin <- min(f$forecast_date) - 1
  a <- hist$value[hist$date <= origin]
  i <- which(out$date <= origin)
  if (length(a) && length(i)) {
    for (cl in intersect(c("q05", "q16", "q50", "q84", "q95"), names(out))) {
      out[[cl]][max(i)] <- dplyr::last(a)
    }
  }
  for (cl in c("q05", "q16", "q50", "q84", "q95")) {
    if (!cl %in% names(out)) out[[cl]] <- NA_real_
  }
  out
}

# The fan itself: history in ink, two sequential washes of the accent, median on
# top. Shared by every variable on this page and by the ISK fan on Markaðir.
forecast_chart <- function(df, unit = "%", digits = 2, label = NULL) {
  d <- dplyr::arrange(df, .data$date)

  # Bands are drawn as an area from the LOWER bound down to the axis, painted
  # over by an area from the UPPER bound, rather than as a stacked ribbon.
  #
  # The stacked form (lower bound + width) is the usual ECharts idiom but it is
  # wrong for any series that crosses zero: ECharts accumulates positive and
  # negative values into SEPARATE stacks, so a negative lower bound throws the
  # band to one side of the line. That is how the heat and output-gap fans first
  # rendered. `areaStyle$origin = "start"` fills from the axis start instead, so
  # painting upper-then-lower in the surface colour leaves exactly the interval
  # visible and works for any sign.
  band <- function(e, lo, hi, opacity) {
    e |>
      echarts4r::e_line_(hi, symbol = "none", legend = FALSE, silent = TRUE,
                         lineStyle = list(opacity = 0),
                         areaStyle = list(color = TOK$accent, opacity = opacity,
                                          origin = "start"),
                         tooltip = list(show = FALSE)) |>
      echarts4r::e_line_(lo, symbol = "none", legend = FALSE, silent = TRUE,
                         connectNulls = FALSE,
                         lineStyle = list(opacity = 0),
                         areaStyle = list(color = TOK$surface, opacity = 1,
                                          origin = "start"),
                         tooltip = list(show = FALSE))
  }

  # Order matters: paint the 90% interval first (fill to upper, mask below
  # lower), then the 68% on top of it. Painting them the other way round would
  # have the wider band's mask erase the narrower one.
  e <- echarts4r::e_charts_(d, "date")
  e <- band(e, "q05", "q95", 0.10)
  e <- band(e, "q16", "q84", 0.18)

  e |>
    echarts4r::e_line_("actual", name = label %||% "Mælt", symbol = "none",
                       lineStyle = list(color = TOK$ink, width = 2),
                       itemStyle = list(color = TOK$ink)) |>
    echarts4r::e_line_("q50", name = "Spá", symbol = "none",
                       lineStyle = list(color = TOK$accent, width = 2),
                       itemStyle = list(color = TOK$accent),
                       endLabel = list(show = TRUE, formatter = "Spá",
                                       color = TOK$ink2, fontSize = 11)) |>
    echarts4r::e_x_axis_("date", type = "time", boundaryGap = FALSE,
                         axisLabel = list(hideOverlap = TRUE)) |>
    chart_drop_axis_data(x_type = "time") |>
    echarts4r::e_y_axis(scale = TRUE, axisLabel = list(
      formatter = htmlwidgets::JS("function(v){return APP.fmtAxis(v);}"))) |>
    echarts4r::e_legend(top = 0, left = 0) |>
    echarts4r::e_tooltip(trigger = "axis", formatter = htmlwidgets::JS(sprintf(
      "function(p){return APP.tip(p, {unit:'%s', digits:%d, freq:'month'});}",
      unit, digits))) |>
    echarts4r::e_grid(left = 8, right = 60, top = 28, bottom = 8,
                      containLabel = TRUE) |>
    echarts4r::e_utc() |>
    (\(x) { x$x$theme <- "editorial"; x$x$mainOpts$locale <- "IS"; x })() |>
    chart_fix_values()
}

# Table twin: the path at the horizons a reader quotes.
forecast_table <- function(variable, digits = 2) {
  fc <- dat("forecast_macro")
  if (!nrow(fc)) return(tibble::tibble())
  f <- dplyr::filter(fc, .data$variable == !!variable,
                     .data$horizon %in% c(1, 3, 6, 12, 18))
  if (!nrow(f)) return(tibble::tibble())
  w <- f |>
    dplyr::select("horizon", "forecast_date", "quantile", "value") |>
    tidyr::pivot_wider(names_from = "quantile", values_from = "value")
  tibble::tibble(
    `Sjóndeild` = paste0(w$horizon, " mán."),
    `Mánuður` = format(w$forecast_date, "%Y-%m"),
    `Miðgildi` = round(w[["0.5"]], digits),
    `90% bil` = paste0(formatC(w[["0.05"]], format = "f", digits = digits,
                               decimal.mark = ","), "–",
                       formatC(w[["0.95"]], format = "f", digits = digits,
                               decimal.mark = ","))
  )
}

# The four published variables, in reading order. Inflation leads: it is the
# number that most directly stands in for the bank and central-bank forecasts.
FORECAST_VARS <- c("infl", "policy_rate", "heat", "gap")

page_forecasts_ui <- function() {
  htmltools::tagList(
    htmltools::tags$div(
      class = "page__head",
      htmltools::tags$h1(lbl("forecasts")),
      htmltools::tags$p(
        class = "lede",
        "Dreifispár úr BVAR-líkani: verðbólga, stýrivextir, hitastig hagkerfisins ",
        "og framleiðsluspenna, 18 mánuði fram. Spárnar koma allar úr sama ",
        "líkani og eru því innbyrðis samkvæmar. Bilið er niðurstaðan — ",
        "miðgildið er samantekt á því, ekki fullyrðing um hvað gerist.")
    ),

    htmltools::tags$div(
      class = "grid grid--2",
      lapply(FORECAST_VARS, function(v) {
        figure_ui(paste0("fc_", v), lbl(v),
                  paste0(if (nzchar(lbl_unit(v))) paste0(lbl_unit(v), " — ") else "",
                         "mælt og spáð, 68% og 90% óvissubil"),
                  source = "Eigin útreikningur",
                  data_to = vintage_of("forecast_macro"),
                  computed_at = computed_of("bvar"))
      })
    ),

    htmltools::tags$div(
      class = "fig__note", style = "margin-top:20px; max-width:68ch",
      "Líkanið er metið á mánaðarlegum gögnum frá 2009. Það er þrálátt í eðli ",
      "sínu og tekur ekki mið af boðuðum ákvörðunum — sjá nánar á ",
      "aðferðafræðisíðunni.")
  )
}

page_forecasts_server <- function(id = "forecasts") {
  hist_for <- function(v) {
    switch(v,
      infl = dplyr::filter(dat("cpi"), .data$series == "CPI_change_A") |>
        dplyr::select("date", "value"),
      policy_rate = dat("policy"),
      heat = dat("heat_level") |> dplyr::transmute(date = .data$date, value = .data$index),
      gap = dat("output_gap"))
  }

  for (v in FORECAST_VARS) {
    local({
      vv <- v
      figure_server(
        paste0("fc_", vv),
        data = shiny::reactive(forecast_frame(hist_for(vv), vv, years = 5)),
        build = function(df) {
          forecast_chart(df, unit = lbl_unit(vv), digits = 2, label = lbl(vv))
        },
        table = function(df) forecast_table(vv)
      )
    })
  }
}
