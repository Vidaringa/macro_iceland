# The policy-rate path figure — shared by Yfirlit and Stýrivextir ----
#
# History as a step line, the BVAR density as two sequential washes of one hue,
# and the market-implied path as its own series. Built here rather than in a
# page file because both pages draw it and the assembly is where the subtle
# rules live: each source has its OWN origin, and the fan is anchored at h = 0
# to the actual rate so the bands attach to the history instead of floating.

# Long frame: history plus one column per forecast quantity. `kind` distinguishes
# the observed segment from the projected one for the table twin.
policy_path_frame <- function(years = 5) {
  policy <- dat("policy")
  fc     <- dat("forecasts")
  if (!nrow(policy)) return(tibble::tibble())

  cutoff <- max(policy$date) - round(years * 365.25)
  hist <- policy |>
    dplyr::filter(.data$date >= cutoff) |>
    dplyr::transmute(date = .data$date, actual = .data$value)

  if (!nrow(fc)) return(dplyr::mutate(hist, q05 = NA_real_, q16 = NA_real_,
                                      q50 = NA_real_, q84 = NA_real_,
                                      q95 = NA_real_, market = NA_real_))

  # BVAR: wide by quantile, anchored at its origin month.
  bv <- fc |> dplyr::filter(.data$source == "bvar")
  bvw <- if (nrow(bv)) {
    w <- bv |>
      dplyr::select("forecast_date", "quantile", "value") |>
      tidyr::pivot_wider(names_from = "quantile", values_from = "value",
                         names_prefix = "q") |>
      dplyr::rename_with(~ sub("^q0\\.", "q", .x)) |>
      dplyr::rename_with(~ sub("^q0$", "q05", .x))
    names(w) <- sub("^q5$", "q50", names(w))
    names(w) <- sub("^q05$", "q05", names(w))
    dplyr::rename(w, date = "forecast_date")
  } else tibble::tibble(date = as.Date(character()))

  mk <- fc |> dplyr::filter(.data$source == "market")
  mkw <- if (nrow(mk)) {
    mk |> dplyr::transmute(date = .data$forecast_date, market = .data$value)
  } else tibble::tibble(date = as.Date(character()))

  out <- hist |>
    dplyr::full_join(bvw, by = "date") |>
    dplyr::full_join(mkw, by = "date") |>
    dplyr::arrange(.data$date)

  # Anchor each projection at its own origin: the last actual rate on or before
  # that origin. Without this the fan starts adrift of the line it continues.
  anchor <- function(col, origin) {
    if (!col %in% names(out) || is.na(origin)) return(out)
    a <- policy$value[policy$date <= origin]
    if (!length(a)) return(out)
    i <- which(out$date <= origin)
    if (!length(i)) return(out)
    out[[col]][max(i)] <- dplyr::last(a)
    out
  }
  bv_origin <- if (nrow(bv)) max(bv$origin_date) else NA
  mk_origin <- if (nrow(mk)) max(mk$origin_date) else NA
  for (cl in intersect(c("q05", "q16", "q50", "q84", "q95"), names(out))) {
    out <- anchor(cl, bv_origin)
  }
  out <- anchor("market", mk_origin)

  for (cl in c("q05", "q16", "q50", "q84", "q95", "market")) {
    if (!cl %in% names(out)) out[[cl]] <- NA_real_
  }
  out
}

policy_path_chart <- function(df, height = NULL) {
  # Bands: one hue, two opacities. Sequential, because they encode magnitude of
  # uncertainty, not identity. Drawn as fill-to-upper then mask-below-lower
  # rather than as a stacked ribbon — ECharts accumulates positive and negative
  # values into separate stacks, so the stacked form breaks on any series that
  # crosses zero (see page_forecasts.R, where the heat fan exposed it). The
  # policy rate never goes negative, but the same constructor shape is used for
  # variables that do, so both use the sign-safe form.
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
  d <- dplyr::arrange(df, .data$date)
  e <- echarts4r::e_charts_(d, "date", height = height)
  e <- band(e, "q05", "q95", 0.10)
  e <- band(e, "q16", "q84", 0.18)

  e |>
    echarts4r::e_line_("actual", name = "Stýrivextir",
                       symbol = "none", step = "end",
                       lineStyle = list(color = TOK$ink, width = 2),
                       itemStyle = list(color = TOK$ink)) |>
    echarts4r::e_line_("q50", name = lbl("bvar"), symbol = "none",
                       lineStyle = list(color = TOK$accent, width = 2),
                       itemStyle = list(color = TOK$accent),
                       endLabel = list(show = TRUE, formatter = lbl("bvar"),
                                       color = TOK$ink2, fontSize = 11)) |>
    echarts4r::e_line_("market", name = lbl("market"), symbol = "circle",
                       symbolSize = 8,
                       lineStyle = list(color = lbl_colour("market"), width = 2),
                       itemStyle = list(color = lbl_colour("market"),
                                        borderColor = TOK$surface, borderWidth = 2),
                       endLabel = list(show = TRUE, formatter = lbl("market"),
                                       color = TOK$ink2, fontSize = 11),
                       connectNulls = TRUE) |>
    echarts4r::e_x_axis_("date", type = "time", boundaryGap = FALSE,
                         axisLabel = list(hideOverlap = TRUE)) |>
    chart_drop_axis_data(x_type = "time") |>
    echarts4r::e_y_axis(scale = TRUE, axisLabel = list(
      formatter = htmlwidgets::JS("function(v){return APP.fmtAxis(v);}"))) |>
    echarts4r::e_legend(top = 0, left = 0) |>
    echarts4r::e_tooltip(trigger = "axis", formatter = htmlwidgets::JS(
      "function(p){return APP.tip(p, {unit:'%', digits:2, freq:'month'});}")) |>
    echarts4r::e_grid(left = 8, right = 96, top = 28, bottom = 8,
                      containLabel = TRUE) |>
    echarts4r::e_utc() |>
    (\(x) { x$x$theme <- "editorial"; x$x$mainOpts$locale <- "IS"; x })() |>
    chart_fix_values()
}

# Table twin: the projected path at the horizons a reader actually quotes.
# A source without a given horizon shows an em dash rather than an interpolation.
policy_path_table <- function(df) {
  fc <- dat("forecasts")
  if (!nrow(fc)) return(tibble::tibble())
  hz <- c(1, 3, 6, 12, 18)

  bv <- fc |>
    dplyr::filter(.data$source == "bvar", .data$horizon %in% hz) |>
    dplyr::select("horizon", "quantile", "value") |>
    tidyr::pivot_wider(names_from = "quantile", values_from = "value")
  mk <- fc |>
    dplyr::filter(.data$source == "market", .data$horizon %in% hz) |>
    dplyr::select("horizon", market = "value")

  base <- tibble::tibble(horizon = hz)
  out <- base |>
    dplyr::left_join(bv, by = "horizon") |>
    dplyr::left_join(mk, by = "horizon")

  med <- if ("0.5" %in% names(out)) out[["0.5"]] else rep(NA_real_, nrow(out))
  lo  <- if ("0.05" %in% names(out)) out[["0.05"]] else rep(NA_real_, nrow(out))
  hi  <- if ("0.95" %in% names(out)) out[["0.95"]] else rep(NA_real_, nrow(out))

  tibble::tibble(
    `Sjóndeild` = paste0(out$horizon, " mán."),
    `BVAR miðgildi` = round(med, 2),
    `90% bil` = ifelse(is.na(lo), "—",
                       paste0(formatC(lo, format = "f", digits = 2, decimal.mark = ","),
                              "–",
                              formatC(hi, format = "f", digits = 2, decimal.mark = ","))),
    `Markaðsvænting` = ifelse(is.na(out$market), NA_real_, round(out$market, 2))
  )
}
