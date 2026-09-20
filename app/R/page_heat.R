# Hitastig — the heat-index page ----
#
# The index over its full history, what drives it (group decomposition and the
# per-indicator table), and the cycle series it is meant to summarise. The point
# of the page is that the headline number is explainable rather than a black
# box, so the decomposition is given equal weight to the level.

page_heat_ui <- function() {
  heat <- dat("heat_level")
  last <- if (nrow(heat)) dplyr::last(heat$index) else NA_real_
  prov <- nrow(heat) && isTRUE(dplyr::last(heat$provisional))
  prov_note <- if (prov) paste0(
    lbl("provisional"), ": nýjasti mánuður byggir á ",
    dplyr::last(heat$n_observed), " af ", dplyr::last(heat$n_total),
    " vísum og er sýndur með brotinni línu.") else NULL

  htmltools::tagList(
    htmltools::tags$div(
      class = "page__head",
      htmltools::tags$h1(lbl("heat")),
      htmltools::tags$p(
        class = "lede",
        "Samsett vísitala um stöðu hagkerfisins, reiknuð úr 19 mánaðarlegum ",
        "vísum með þáttalíkani. Núll svarar til meðalstöðu áranna 2010–2019; ",
        "einingin er staðalfrávik. Vísitalan er samfallandi — hún lýsir ",
        "líðandi stundu, ekki framtíðinni.")
    ),

    htmltools::tags$div(
      class = "controls",
      htmltools::tags$div(
        class = "seg",
        shiny::radioButtons("heat_range", NULL,
                            choices = c("5 ár" = "5", "10 ár" = "10",
                                        "Frá 1999" = "all"),
                            selected = "10", inline = TRUE)
      )
    ),

    figure_ui("heat_level", "Hitastig hagkerfisins",
              "Staðalfrávik frá leitni — núll er meðalstaða 2010–2019",
              source = "Eigin útreikningur á gögnum Hagstofu, Seðlabanka og Gallup",
              data_to = vintage_of("heatindex_level"),
              computed_at = computed_of("heat"),
              note = prov_note,
              class = "fig--tall"),

    htmltools::tags$div(
      style = "margin-top:20px",
      figure_ui("heat_groups", "Hvað drífur hitastigið",
                "Framlag hvers málaflokks til vísitölunnar, staðalfrávik",
                source = "Eigin útreikningur",
                data_to = vintage_of("heatindex_level"),
                computed_at = computed_of("heat"),
                note = paste0(
                  "Framlög málaflokkanna leggjast nákvæmlega saman í vísitöluna, ",
                  "svo lesa má hvaðan hitastigið kemur hverju sinni."))
    ),

    htmltools::tags$div(
      class = "tbl-card", style = "margin-top:20px",
      htmltools::tags$h3("Vísar að baki nýjasta gildi"),
      htmltools::tags$p(class = "fig__sub",
                        "Staðalfært gildi, vægi í líkaninu og framlag hvers vísis."),
      reactable::reactableOutput("heat_inputs_tbl")
    ),

    htmltools::tags$h2("Hagsveiflan", style = "margin:28px 0 4px"),
    htmltools::tags$p(class = "fig__sub",
                      "Lykilstærðir sem vísitalan dregur saman. Ársbreyting í prósentum.",
                      style = "margin-bottom:12px"),
    htmltools::tags$div(class = "grid grid--6", id = "heat-cycle",
                        lapply(HEAT_CYCLE, function(code) {
                          figure_ui(paste0("cyc_", code), lbl(code), NULL,
                                    class = "fig--short")
                        }))
  )
}

# The six cycle panels, in a fixed order. Named here rather than inline because
# the UI and the server both walk the same list.
HEAT_CYCLE <- c("GDP_yoy", "CPI_change_A", "LFS_UNEMPLOYMENT",
                "HOUSE_PRICE_YOY", "CARD_YOY", "HOTEL_YOY")

# The indicator table sits outside a figure (it is a primary object, not a
# chart's twin), so it renders through its own output.
page_heat_inputs_server <- function(output) {
  output$heat_inputs_tbl <- reactable::renderReactable({
    d <- dat("heat_inputs")
    shiny::validate(shiny::need(nrow(d) > 0, lbl("no_data")))
    tb <- d |>
      dplyr::transmute(
        `Vísir` = lbl(.data$series),
        `Málaflokkur` = lbl(.data$group),
        `Staðalfært gildi` = round(.data$value_std, 2),
        `Vægi` = round(.data$loading, 3),
        `Framlag` = round(.data$contribution, 3),
        `Nýjast` = format(.data$last_observed, "%Y-%m")) |>
      dplyr::arrange(dplyr::desc(abs(.data$Framlag)))
    reactable::reactable(
      tb, compact = TRUE, striped = TRUE, highlight = TRUE,
      defaultPageSize = 19, showPageSizeOptions = FALSE,
      defaultColDef = reactable::colDef(
        format = reactable::colFormat(locales = "is-IS"), minWidth = 90,
        na = "—"),
      columns = list(`Vísir` = reactable::colDef(minWidth = 180),
                     `Málaflokkur` = reactable::colDef(minWidth = 140))
    )
  })
}

# `input` is passed in because the range control sits on the page rather than
# inside a figure module — one filter row scoping the charts below it, which is
# the rule, and it keeps the segmented control out of every figure's chrome.
page_heat_server <- function(input, id = "heat") {

  figure_server(
    "heat_level",
    data = shiny::reactive({
      d <- dat("heat_level")
      if (!nrow(d)) return(d)
      yrs <- input$heat_range %||% "10"
      if (identical(yrs, "all")) return(d)
      dplyr::filter(d, .data$date >= max(.data$date) - as.numeric(yrs) * 365.25)
    }),
    build = function(df) {
      chart_line(df, y = "index", unit = "", digits = 2, freq = "month",
                 baseline = 0, dashed = "provisional", deemph = "low_confidence",
                 mark_areas = RECESSIONS[RECESSIONS$to >= min(df$date), ])
    },
    table = function(df) {
      df |>
        dplyr::transmute(
          !!lbl("date") := format(.data$date, "%Y-%m"),
          Hitastig = round(.data$index, 2),
          `Vísitala (50=meðaltal)` = round(.data$index100, 1),
          `Vísar` = paste0(.data$n_observed, "/", .data$n_total)) |>
        dplyr::arrange(dplyr::desc(.data[[lbl("date")]]))
    }
  )

  # Stacked columns, inlined: this is the only stack in the app, so it does not
  # earn a constructor. Mixed-sign contributions mean no series is reliably the
  # top of the stack, so no rounded data-ends; the 2px separation between
  # segments is a surface-coloured border, which is how ECharts does it without
  # adding data ink.
  figure_server(
    "heat_groups",
    data = shiny::reactive({
      d <- dat("heat_groups")
      if (!nrow(d)) return(d)
      yrs <- input$heat_range %||% "10"
      # The stack is dense, so cap it at ten years even when the level chart
      # shows the full history — beyond that the columns are sub-pixel.
      cap <- if (identical(yrs, "all")) 10 else as.numeric(yrs)
      dplyr::filter(d, .data$date >= max(.data$date) - cap * 365.25)
    }),
    build = function(df) {
      codes <- LABELS$code[LABELS$kind == "group"]
      codes <- codes[codes %in% unique(df$series)]
      wide <- df |>
        dplyr::select("date", "series", "value") |>
        tidyr::pivot_wider(names_from = "series", values_from = "value") |>
        dplyr::arrange(.data$date)

      e <- echarts4r::e_charts_(wide, "date")
      for (cd in codes) {
        e <- echarts4r::e_bar_(
          e, cd, name = lbl(cd), stack = "grp", barMaxWidth = 24,
          itemStyle = list(color = lbl_colour(cd),
                           borderColor = TOK$surface, borderWidth = 1))
      }
      e |>
        echarts4r::e_x_axis_("date", type = "time",
                            axisLabel = list(hideOverlap = TRUE)) |>
        chart_drop_axis_data(x_type = "time") |>
        echarts4r::e_y_axis(axisLabel = list(
          formatter = htmlwidgets::JS("function(v){return APP.fmtAxis(v);}"))) |>
        echarts4r::e_legend(top = 0, left = 0) |>
        echarts4r::e_tooltip(trigger = "axis", formatter = htmlwidgets::JS(
          "function(p){return APP.tip(p, {unit:'', digits:2, freq:'month'});}")) |>
        echarts4r::e_grid(left = 8, right = 16, top = 28, bottom = 8,
                          containLabel = TRUE) |>
        echarts4r::e_utc() |>
        (\(x) { x$x$theme <- "editorial"; x$x$mainOpts$locale <- "IS"; x })() |>
        chart_fix_values()
    }
  )

  for (code in HEAT_CYCLE) {
    local({
      cd <- code
      figure_server(
        paste0("cyc_", cd),
        data = shiny::reactive({
          d <- dat("cycle")
          if (!nrow(d)) return(d)
          d |>
            dplyr::filter(.data$series == cd,
                          .data$date >= max(.data$date) - 3660,
                          !is.na(.data$value))
        }),
        build = function(df) {
          chart_line(df, y = "value", unit = "%", digits = 1,
                     freq = if (cd == "GDP_yoy") "quarter" else "month",
                     baseline = 0)
        }
      )
    })
  }
}
