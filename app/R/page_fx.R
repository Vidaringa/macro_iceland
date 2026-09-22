# Gengi — the króna ----
#
# FX used to ride along on the "Markaðir" page, which was really about bonds.
# It is a separate asset class with its own drivers, so it gets its own page:
# the trade-weighted index over time, then the three bilateral rates that a
# reader actually transacts in.
#
# The index is the headline because it is the one that answers "is the króna
# strong or weak" without picking a counterpart currency. A RISE is a WEAKER
# króna, which is the opposite of the intuition most readers bring, so the
# subtitle says so on every render rather than relying on a note.

page_fx_ui <- function() {
  fx <- dat("fx")

  fx_tile <- function(code) {
    s <- tile_stats(fx, code, lag_days = 30)
    stat_tile(lbl(code), fmt_num(s$value, 2), "kr.",
              delta = s$delta, delta_label = "frá fyrri mánuði",
              spark = spark_svg(s$spark))
  }

  htmltools::tagList(
    htmltools::tags$div(
      class = "page__head",
      htmltools::tags$h1(lbl("fx")),
      htmltools::tags$p(
        class = "lede",
        "Gengi krónunnar: gengisvísitalan, sem mælir krónuna gagnvart ",
        "viðskiptavegnu meðaltali gjaldmiðla, og gengi helstu mynta. ",
        "Hækkun vísitölunnar merkir VEIKARI krónu.")
    ),

    htmltools::tags$div(class = "grid grid--3",
                        fx_tile("EUR"), fx_tile("USD"), fx_tile("GBP")),

    htmltools::tags$div(
      style = "margin-top:20px",
      figure_ui("fx_twi", "Gengisvísitala krónunnar",
                "Vísitala — hækkun merkir veikari krónu",
                source = "Seðlabanki Íslands",
                data_to = vintage_of("fx_daily"),
                class = "fig--flat")
    )
  )
}

page_fx_server <- function(id = "fx") {
  figure_server(
    "fx_twi",
    data = shiny::reactive({
      d <- dat("fx")
      if (!nrow(d)) return(d)
      dplyr::filter(d, .data$series == "TWI",
                    .data$date >= max(.data$date) - 1830)
    }),
    build = function(df) {
      chart_line(df, y = "value", unit = "", digits = 1, freq = "day")
    }
  )
}
