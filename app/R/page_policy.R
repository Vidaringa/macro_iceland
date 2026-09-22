# Stýrivextir — the policy-rate page ----
#
# The fan chart at full size, the path table beneath it, the interest-rate
# corridor in emphasis form, and external policy rates for context. Each
# forecast reading keeps its own origin, and the page reads them generically
# from `source`, so the third reading (the reaction function) will appear here
# with no change to this file.

page_policy_ui <- function() {
  ext <- dat("external")

  tile <- function(code, lag_days = 30) {
    s <- tile_stats(ext, code, lag_days = lag_days)
    stat_tile(lbl(code), fmt_num(s$value, 2), "%",
              delta = s$delta, delta_label = "frá fyrri mánuði",
              spark = spark_svg(s$spark))
  }

  htmltools::tagList(
    htmltools::tags$div(
      class = "page__head",
      htmltools::tags$h1(lbl("policy")),
      htmltools::tags$p(
        class = "lede",
        "Meginvextir Seðlabanka Íslands, vaxtagangur bankans og tvær spár um ",
        "framhaldið: dreifispá úr líkani og markaðsvænting lesin úr ",
        "REIBOR-ferlinum.")
    ),

    figure_ui("pol_fan", "Stýrivextir og spáð þróun",
              "Prósent — miðgildi með 68% og 90% óvissubili",
              source = "Seðlabanki Íslands, eigin útreikningur",
              data_to = vintage_of("rates_policy"),
              computed_at = computed_of("bvar"),
              note = paste0(
                "Líkanspáin er dreifispá: hún lýsir líkindadreifingu vaxta, ekki ",
                "einu gildi. Hún byggir á viðvarandi þróun og tekur því ekki mið ",
                "af boðuðum vaxtaákvörðunum. Markaðsvæntingin nær aðeins sex ",
                "mánuði fram — lengra nær REIBOR-ferillinn ekki."),
              class = "fig--flat-tall"),

    htmltools::tags$div(
      class = "tbl-card", style = "margin-top:20px",
      htmltools::tags$h3("Spáð vaxtastig eftir sjóndeild"),
      reactable::reactableOutput("pol_table")
    ),

    htmltools::tags$div(
      class = "grid grid--2", style = "margin-top:20px",
      figure_ui("pol_corridor", "Vaxtagangur Seðlabankans",
                "Prósent — innlánsvextir eru meginvextir bankans",
                source = "Seðlabanki Íslands",
                data_to = vintage_of("rates_policy")),
      figure_ui("pol_reibor", "REIBOR-millibankavextir",
                "Prósent — eftir binditíma",
                source = "Seðlabanki Íslands",
                data_to = vintage_of("rates_reibor"))
    ),

    htmltools::tags$h2("Erlendir stýrivextir", style = "margin:28px 0 12px"),
    htmltools::tags$div(
      class = "grid grid--4",
      tile("ECB_DEPO"), tile("FED_FUNDS"), tile("UST_2Y"), tile("UST_10Y")
    )
  )
}

page_policy_server <- function(id = "policy") {

  figure_server(
    "pol_fan",
    data = shiny::reactive(policy_path_frame(years = 6)),
    build = function(df) policy_path_chart(df),
    table = function(df) policy_path_table(df)
  )

  # Emphasis form: the policy rate proper in the accent, the three other
  # corridor rates in the de-emphasis gray. The reader should see one line and
  # its envelope, not four competing series.
  figure_server(
    "pol_corridor",
    data = shiny::reactive({
      d <- dat("corridor")
      if (nrow(d)) dplyr::filter(d, .data$date >= max(.data$date) - 1830) else d
    }),
    build = function(df) {
      # No end labels: the corridor rates sit within a percentage point of each
      # other at the right edge, so labels would collide and detach from their
      # lines. The legend carries identity and the accent line is the subject.
      chart_line(df, y = "value", series = "series", kind = "step",
                 unit = "%", digits = 2, freq = "day",
                 emphasis = "DEPOSIT_7D", end_labels = FALSE)
    }
  )

  figure_server(
    "pol_reibor",
    data = shiny::reactive({
      d <- dat("reibor")
      if (nrow(d)) dplyr::filter(d, .data$date >= max(.data$date) - 1830) else d
    }),
    build = function(df) {
      # Same reasoning as the corridor: the four tenors converge, so identity
      # comes from the legend rather than from four overlapping labels.
      chart_line(df, y = "value", series = "series",
                 unit = "%", digits = 2, freq = "day", end_labels = FALSE)
    }
  )
}

# The path table sits outside a figure (it is the primary object, not a chart's
# twin), so it renders through its own output.
page_policy_table_server <- function(output) {
  output$pol_table <- reactable::renderReactable({
    tb <- policy_path_table(NULL)
    shiny::validate(shiny::need(nrow(tb) > 0, lbl("no_data")))
    reactable::reactable(
      tb, compact = TRUE, striped = TRUE, highlight = TRUE,
      sortable = FALSE, pagination = FALSE,
      defaultColDef = reactable::colDef(
        format = reactable::colFormat(locales = "is-IS", digits = 2),
        minWidth = 90, na = "—")
    )
  })
}
