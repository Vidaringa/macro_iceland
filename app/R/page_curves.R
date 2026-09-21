# Vaxtaferlar — the fitted term structures and breakeven inflation ----
#
# The breakeven leads the page. It is the one number here that nobody else in
# Iceland publishes as a term structure, and it is what the two fitted curves
# exist to produce: the gap between a nominal yield and a real yield IS the
# inflation the market is pricing over that horizon.
#
# The nominal and real curves keep separate panels with their own scales. A real
# yield is not comparable to a nominal one — the difference between them is the
# subject of the page, not something to invite by eye off a shared axis.

page_curves_ui <- function() {
  pts <- dat("curve_points")
  res <- dat("curve_residuals")

  as_of <- if (nrow(pts)) max(pts$date) else NA
  be <- if (nrow(pts)) {
    dplyr::filter(pts, .data$curve == "breakeven", .data$date == as_of)
  } else tibble::tibble()

  pick_be <- function(m) {
    if (!nrow(be)) return(NA_real_)
    i <- which.min(abs(be$maturity - m))
    if (!length(i)) NA_real_ else be$yield[i]
  }

  # Cheapest and richest bond against their own curves — the headline rich/cheap.
  rc <- if (nrow(res)) {
    dplyr::arrange(res, dplyr::desc(.data$residual))
  } else tibble::tibble()

  htmltools::tagList(
    htmltools::tags$div(
      class = "page__head",
      htmltools::tags$h1(lbl("curves")),
      htmltools::tags$p(
        class = "lede",
        "Ferlar lagaðir að ávöxtunarkröfu ríkisbréfa með Nelson-Siegel aðferð: ",
        "óverðtryggður ferill úr RIKB-bréfum, verðtryggður úr RIKS-bréfum, og ",
        "munurinn á þeim — verðbólguálagið — sem er sú verðbólga sem ",
        "markaðurinn verðleggur.")
    ),

    htmltools::tags$div(
      class = "grid grid--3",
      stat_tile("Verðbólguálag, 5 ára", fmt_num(pick_be(5), 2), "%", hero = TRUE,
                note = "Verðbólga sem markaðurinn verðleggur næstu fimm árin"),
      stat_tile("Verðbólguálag, 10 ára", fmt_num(pick_be(10), 2), "%"),
      stat_tile("Verðbólgumarkmið Seðlabankans", "2,50", "%",
                note = "Til samanburðar")
    ),

    htmltools::tags$div(
      style = "margin-top:20px",
      figure_ui("cv_breakeven", "Verðbólguálag eftir líftíma",
                "Prósent — óverðtryggð krafa að frádreginni verðtryggðri",
                source = "Eigin útreikningur á gögnum Nasdaq Iceland",
                data_to = vintage_of("curve_points"),
                computed_at = computed_of("curve"),
                note = paste0(
                  "Álagið er birt eingöngu á þeim líftímum þar sem BÁÐIR ",
                  "ferlarnir byggja á raunverulegum bréfum. Stysta verðtryggða ",
                  "bréfið er um þriggja ára, svo styttra álag er ekki reiknað."),
                class = "fig--tall")
    ),

    htmltools::tags$div(
      class = "grid grid--2", style = "margin-top:20px",
      figure_ui("cv_nominal", "Óverðtryggður vaxtaferill",
                "Prósent eftir líftíma — ferill og undirliggjandi bréf",
                source = "Eigin útreikningur á gögnum Nasdaq Iceland",
                data_to = vintage_of("curve_points"),
                computed_at = computed_of("curve")),
      figure_ui("cv_real", "Verðtryggður vaxtaferill",
                "RAUNávöxtun í prósentum eftir líftíma",
                source = "Eigin útreikningur á gögnum Nasdaq Iceland",
                data_to = vintage_of("curve_points"),
                computed_at = computed_of("curve"))
    ),

    htmltools::tags$div(
      style = "margin-top:20px",
      figure_ui("cv_be_hist", "Þróun verðbólguálags",
                "Prósent — 5 og 10 ára álag yfir tíma",
                source = "Eigin útreikningur",
                data_to = vintage_of("curve_points"),
                computed_at = computed_of("curve"))
    ),

    htmltools::tags$div(
      class = "tbl-card", style = "margin-top:20px",
      htmltools::tags$h3("Frávik bréfa frá eigin ferli"),
      htmltools::tags$p(class = "fig__sub",
                        paste0("Jákvætt frávik merkir hærri kröfu en ferillinn ",
                               "segir til um — bréfið er ódýrt miðað við ",
                               "ferilinn. Punktar, ekki prósentustig.")),
      reactable::reactableOutput("cv_resid_tbl")
    )
  )
}

page_curves_server <- function(id = "curves") {

  latest <- function() {
    p <- dat("curve_points")
    if (!nrow(p)) return(p)
    dplyr::filter(p, .data$date == max(.data$date))
  }

  # The fitted curve with the bonds it was fitted to, so a reader can see the fit
  # rather than take it on trust.
  curve_with_bonds <- function(cv, colour) {
    df  <- dplyr::filter(latest(), .data$curve == cv)
    obs <- dplyr::filter(dat("curve_residuals"), .data$curve == cv)
    if (!nrow(df)) return(NULL)

    # One frame carrying both series, joined on the x variable: the fitted grid
    # in `yield`, the observed bonds in `obs`, each NA where the other applies.
    # Building it up front avoids reaching into the widget's data afterwards.
    # Note the column order in the second transmute: `obs` is taken from
    # `.data$yield` BEFORE a `yield = NA` assignment would shadow it. Writing
    # yield first silently produced an all-NA scatter.
    d <- dplyr::bind_rows(
      dplyr::transmute(df, maturity = .data$maturity, yield = .data$yield,
                       obs = NA_real_),
      dplyr::transmute(obs, maturity = .data$tau, obs = .data$yield,
                       yield = NA_real_)) |>
      dplyr::arrange(.data$maturity)

    echarts4r::e_charts_(d, "maturity") |>
      echarts4r::e_line_("yield", name = lbl(cv), symbol = "none",
                         connectNulls = TRUE,
                         lineStyle = list(color = colour, width = 2),
                         itemStyle = list(color = colour)) |>
      echarts4r::e_scatter_("obs", name = "Bréf", symbol_size = 9,
                            itemStyle = list(color = TOK$ink,
                                             borderColor = TOK$surface,
                                             borderWidth = 2)) |>
      # Maturity ticks read as whole years: the bonds sit at 0.572 and 23.992
      # years, and an axis labelled to three decimals is noise, not precision.
      echarts4r::e_x_axis_("maturity", type = "value", name = "Líftími (ár)",
                           nameLocation = "middle", nameGap = 26,
                           nameTextStyle = list(color = TOK$muted, fontSize = 11),
                           axisLabel = list(formatter = htmlwidgets::JS(
                             "function(v){return APP.fmt(v, 0);}"))) |>
      chart_drop_axis_data(x_type = "value") |>
      echarts4r::e_y_axis(scale = TRUE, axisLabel = list(
        formatter = htmlwidgets::JS("function(v){return APP.fmtAxis(v);}"))) |>
      echarts4r::e_legend(top = 0, left = 0) |>
      echarts4r::e_tooltip(trigger = "axis", formatter = htmlwidgets::JS(
        "function(p){return APP.tip(p, {unit:'%', digits:2, freq:'none'});}")) |>
      echarts4r::e_grid(left = 8, right = 16, top = 28, bottom = 24,
                        containLabel = TRUE) |>
      (\(x) { x$x$theme <- "editorial"; x$x$mainOpts$locale <- "IS"; x })() |>
      chart_fix_values()
  }

  figure_server(
    "cv_breakeven",
    data = shiny::reactive(dplyr::filter(latest(), .data$curve == "breakeven")),
    build = function(df) {
      chart_line(df, y = "yield", x = "maturity", x_type = "value",
                 unit = "%", digits = 2, markers = TRUE)
    },
    table = function(df) {
      df |> dplyr::transmute(`Líftími (ár)` = .data$maturity,
                             `Verðbólguálag %` = round(.data$yield, 2))
    }
  )

  figure_server(
    "cv_nominal",
    data = shiny::reactive(dplyr::filter(latest(), .data$curve == "nominal")),
    build = function(df) curve_with_bonds("nominal", lbl_colour("nominal")),
    table = function(df) {
      df |> dplyr::transmute(`Líftími (ár)` = .data$maturity,
                             `Krafa %` = round(.data$yield, 2))
    }
  )

  figure_server(
    "cv_real",
    data = shiny::reactive(dplyr::filter(latest(), .data$curve == "real")),
    build = function(df) curve_with_bonds("real", lbl_colour("real")),
    table = function(df) {
      df |> dplyr::transmute(`Líftími (ár)` = .data$maturity,
                             `Raunkrafa %` = round(.data$yield, 2))
    }
  )

  # Two maturities over time: enough to show the level and any change in slope,
  # few enough that direct labels still separate.
  figure_server(
    "cv_be_hist",
    data = shiny::reactive({
      p <- dat("curve_points")
      if (!nrow(p)) return(p)
      # Zero-padded so the shorter maturity sorts first: these labels are not in
      # the dictionary, so chart_line falls back to sorting them as strings and
      # "10 ára" would otherwise precede "5 ára".
      p |>
        dplyr::filter(.data$curve == "breakeven", .data$maturity %in% c(5, 10)) |>
        dplyr::transmute(date = .data$date,
                         series = sprintf("%2d ára", as.integer(.data$maturity)),
                         value = .data$yield)
    }),
    build = function(df) {
      chart_line(df, y = "value", series = "series", unit = "%", digits = 2,
                 freq = "day", end_labels = TRUE)
    }
  )
}

# The residual table renders through its own output (a primary object, not a
# chart's twin).
page_curves_table_server <- function(output) {
  output$cv_resid_tbl <- reactable::renderReactable({
    d <- dat("curve_residuals")
    shiny::validate(shiny::need(nrow(d) > 0, lbl("no_data")))
    tb <- d |>
      dplyr::transmute(
        `Bréf` = .data$bond_code,
        `Ferill` = lbl(.data$curve),
        `Líftími (ár)` = round(.data$tau, 2),
        `Krafa %` = round(.data$yield, 2),
        `Ferill segir %` = round(.data$fitted, 2),
        `Frávik (punktar)` = round(.data$residual * 100, 1)) |>
      dplyr::arrange(dplyr::desc(.data$`Frávik (punktar)`))
    reactable::reactable(
      tb, compact = TRUE, striped = TRUE, highlight = TRUE,
      defaultPageSize = 13, showPageSizeOptions = FALSE,
      defaultColDef = reactable::colDef(
        format = reactable::colFormat(locales = "is-IS"), minWidth = 90, na = "—"))
  })
}
