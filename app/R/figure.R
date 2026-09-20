# The figure module — a chart can't ship without its apparatus ----
#
# Every chart in the app is wrapped by this module, so a title, a unit
# subtitle, a provenance line and a table twin are structural rather than
# something to remember. The table twin matters twice over: it is the
# accessibility relief for the palette slots that fall below 3:1 contrast, and
# it is what a professional reader reaches for when they want the number rather
# than the shape.

figure_ui <- function(id, title, subtitle = NULL, source = NULL,
                      data_to = NULL, computed_at = NULL, note = NULL,
                      class = NULL) {
  ns <- shiny::NS(id)
  prov <- c(
    if (!is.null(source))      paste0(lbl("source_prefix"), ": ", source),
    if (!is.null(data_to))     paste0(lbl("data_to"), " ", data_to),
    if (!is.null(computed_at)) paste0(lbl("computed_at"), " ", computed_at)
  )

  htmltools::tags$figure(
    class = paste("fig", class),
    htmltools::tags$div(
      class = "fig__head",
      htmltools::tags$h3(class = "fig__title", title),
      if (!is.null(subtitle)) htmltools::tags$p(class = "fig__sub", subtitle)
    ),
    htmltools::tags$div(
      class = "fig__plot",
      echarts4r::echarts4rOutput(ns("chart"), height = "100%")
    ),
    if (!is.null(note)) htmltools::tags$p(class = "fig__note", note),
    htmltools::tags$details(
      class = "fig__table",
      htmltools::tags$summary(lbl("table_toggle")),
      reactable::reactableOutput(ns("table"))
    ),
    if (length(prov)) htmltools::tags$figcaption(
      class = "fig__prov", paste(prov, collapse = " · "))
  )
}

# `data`  reactive returning the tibble to plot
# `build` function(df) -> echarts4r widget
# `table` function(df) -> tibble for the twin; the default pivots a tidy
#         (date, series, value) frame wide with display labels as headers,
#         which is the right shape for all but a couple of figures.
figure_server <- function(id, data, build, table = NULL) {
  shiny::moduleServer(id, function(input, output, session) {

    output$chart <- echarts4r::renderEcharts4r({
      df <- data()
      shiny::validate(shiny::need(is.data.frame(df) && nrow(df) > 0, lbl("no_data")))
      build(df)
    })

    output$table <- reactable::renderReactable({
      df <- data()
      shiny::validate(shiny::need(is.data.frame(df) && nrow(df) > 0, lbl("no_data")))
      tb <- if (!is.null(table)) table(df) else {
        if (all(c("date", "series", "value") %in% names(df))) {
          df |>
            dplyr::select("date", "series", "value") |>
            tidyr::pivot_wider(names_from = "series", values_from = "value") |>
            dplyr::arrange(dplyr::desc(.data$date)) |>
            dplyr::rename_with(~ lbl(.x), -"date") |>
            dplyr::rename(!!lbl("date") := "date")
        } else df |> dplyr::arrange(dplyr::desc(dplyr::pick(1)))
      }
      reactable::reactable(
        tb, compact = TRUE, striped = TRUE, highlight = TRUE,
        defaultPageSize = 12, showPageSizeOptions = FALSE,
        # Icelandic number formatting is a decimal comma; doing it client-side
        # keeps the sorting numeric.
        defaultColDef = reactable::colDef(
          format = reactable::colFormat(locales = "is-IS", digits = 2),
          minWidth = 90
        )
      )
    })
  })
}
