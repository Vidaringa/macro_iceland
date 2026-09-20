# Markaðir — observed market data ----
#
# Everything here is measured, not modelled: no fitted curve exists yet (that is
# module A3), so the yield-by-maturity figures plot the actual bonds rather than
# a smooth curve, and are labelled as such.
#
# The nominal (RIKB) and indexed (RIKS) bonds are shown in SEPARATE figures with
# their own y scales. RIKS yields are REAL yields; putting them on one axis with
# nominal yields would invite a comparison that is not meaningful, which is both
# a spec rule and the one-axis rule.

page_markets_ui <- function() {
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
      htmltools::tags$h1(lbl("markets")),
      htmltools::tags$p(
        class = "lede",
        "Ávöxtunarkrafa ríkisbréfa, millibankavextir, ríkisvíxlar og gengi. ",
        "Allar tölur eru mældar markaðsstærðir — engin ferilaðlögun liggur ",
        "að baki.")
    ),

    htmltools::tags$div(
      class = "grid grid--2",
      figure_ui("mk_rikb", "Óverðtryggð ríkisbréf (RIKB)",
                "Ávöxtunarkrafa í prósentum eftir líftíma",
                source = "Nasdaq Iceland",
                data_to = vintage_of("bonds_daily"),
                note = paste0("Hver punktur er eitt bréf. Samanburður við stöðuna ",
                              "fyrir mánuði sýnir hvernig ferillinn hefur hreyfst.")),
      figure_ui("mk_riks", "Verðtryggð ríkisbréf (RIKS)",
                "RAUNávöxtunarkrafa í prósentum eftir líftíma",
                source = "Nasdaq Iceland",
                data_to = vintage_of("bonds_daily"),
                note = paste0("Raunávöxtun er ekki samanburðarhæf við ",
                              "óverðtryggða kröfu að ofan nema að teknu tilliti ",
                              "til verðbólguvæntinga."))
    ),

    htmltools::tags$div(
      class = "grid grid--2", style = "margin-top:20px",
      figure_ui("mk_bench", "Ávöxtunarkrafa valinna ríkisbréfa",
                "Prósent — þróun yfir tíma",
                source = "Nasdaq Iceland",
                data_to = vintage_of("bonds_daily")),
      figure_ui("mk_twi", "Gengisvísitala krónunnar",
                "Vísitala — hækkun merkir veikari krónu",
                source = "Seðlabanki Íslands",
                data_to = vintage_of("fx_daily"))
    ),

    htmltools::tags$div(
      style = "margin-top:20px",
      figure_ui("mk_isk_fan", "Óvissa um gengi krónunnar",
                "Mánaðarleg breyting í prósentum — 68% og 90% óvissubil",
                source = "Eigin útreikningur",
                data_to = vintage_of("forecast_fx"),
                computed_at = computed_of("isk"),
                note = paste0(
                  "Þetta er ÓVISSUMAT, ekki spá um stefnu. Mánaðarlegar ",
                  "gengisbreytingar eru nánast ófyrirsjáanlegar: prófun utan ",
                  "úrtaks sýnir enga marktæka hæfni til að spá fyrir um ",
                  "átt þeirra. Bilið segir hversu stórar hreyfingar eru ",
                  "líklegar — miðgildið segir lítið. Gengið er auk þess ",
                  "stýrt fljótandi: Seðlabankinn hefur átt viðskipti á ",
                  "millibankamarkaði í meirihluta mánaða."))
    ),

    htmltools::tags$h2("Gengi", style = "margin:28px 0 12px"),
    htmltools::tags$div(class = "grid grid--3",
                        fx_tile("EUR"), fx_tile("USD"), fx_tile("GBP")),

    htmltools::tags$div(
      class = "tbl-card", style = "margin-top:28px",
      htmltools::tags$h3("Ríkisbréf í umferð"),
      reactable::reactableOutput("mk_bonds_tbl")
    ),

    htmltools::tags$div(
      class = "tbl-card", style = "margin-top:20px",
      htmltools::tags$h3("Útboð ríkisvíxla"),
      reactable::reactableOutput("mk_tbills_tbl")
    )
  )
}

# Latest yields by years-to-maturity, plus the same cross-section a month
# earlier. Returns a long frame with a `when` key so the two vintages become two
# series — the before/after form (one hue, two shades) rather than two colours,
# because they are the same quantity at two dates.
markets_curve_frame <- function(want_indexed) {
  bonds <- dat("bonds"); attrs <- dat("bond_attrs")
  if (!nrow(bonds) || !nrow(attrs)) return(tibble::tibble())

  as_of <- max(bonds$date)
  prior_dates <- bonds$date[bonds$date <= as_of - 30]
  prior <- if (length(prior_dates)) max(prior_dates) else NA

  # The argument is deliberately NOT called `indexed`: a filter comparing
  # .data$indexed to a parameter of the same name resolves both to the column
  # and silently keeps every row, which is how both curves ended up identical.
  keep <- attrs |>
    dplyr::filter(!is.na(.data$maturity),
                  dplyr::coalesce(.data$indexed, FALSE) == want_indexed)
  if (!nrow(keep)) return(tibble::tibble())

  bonds |>
    dplyr::filter(.data$date %in% c(as_of, prior)) |>
    dplyr::inner_join(dplyr::select(keep, "orderbookid", "maturity"),
                      by = "orderbookid") |>
    dplyr::mutate(
      yrs = as.numeric(.data$maturity - as_of) / 365.25,
      when = ifelse(.data$date == as_of, "now", "prior")) |>
    dplyr::filter(.data$yrs > 0) |>
    dplyr::arrange(.data$when, .data$yrs)
}

page_markets_server <- function(id = "markets") {

  curve_chart <- function(df) {
    # bond_code is carried as a LABEL, not a key: leaving it in the pivot would
    # split "now" and "prior" onto separate rows and break the pairing.
    wide <- df |>
      dplyr::select("yrs", "when", "yield") |>
      tidyr::pivot_wider(names_from = "when", values_from = "yield") |>
      dplyr::arrange(.data$yrs)
    if (!"prior" %in% names(wide)) wide$prior <- NA_real_

    e <- echarts4r::e_charts_(wide, "yrs")
    # Prior vintage first so "now" sits on top; a lighter step of the SAME hue
    # keeps it read as the same quantity at another date.
    if (any(!is.na(wide$prior))) {
      e <- echarts4r::e_line_(
        e, "prior", name = "Fyrir mánuði", symbol = "circle", symbolSize = 8,
        lineStyle = list(color = TOK$deemph, width = 2),
        itemStyle = list(color = TOK$surface, borderColor = TOK$deemph,
                         borderWidth = 2))
    }
    e |>
      echarts4r::e_line_(
        "now", name = "Nú", symbol = "circle", symbolSize = 9,
        lineStyle = list(color = TOK$accent, width = 2),
        itemStyle = list(color = TOK$accent, borderColor = TOK$surface,
                         borderWidth = 2)) |>
      echarts4r::e_x_axis_("yrs", type = "value",
                           name = "Líftími (ár)", nameLocation = "middle",
                           nameGap = 26,
                           nameTextStyle = list(color = TOK$muted, fontSize = 11),
                           axisLabel = list(formatter = htmlwidgets::JS(
                             "function(v){return APP.fmtAxis(v);}"))) |>
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

  curve_table <- function(df) {
    df |>
      dplyr::filter(.data$when == "now") |>
      dplyr::transmute(`Bréf` = .data$bond_code,
                       `Líftími (ár)` = round(.data$yrs, 1),
                       `Krafa %` = round(.data$yield, 2),
                       `Verð` = round(.data$price, 2)) |>
      dplyr::arrange(.data$`Líftími (ár)`)
  }

  figure_server("mk_rikb", data = shiny::reactive(markets_curve_frame(FALSE)),
                build = curve_chart, table = curve_table)
  figure_server("mk_riks", data = shiny::reactive(markets_curve_frame(TRUE)),
                build = curve_chart, table = curve_table)

  # Three benchmark nominal bonds over time — at three series, direct labels
  # still separate cleanly at the right edge.
  figure_server(
    "mk_bench",
    data = shiny::reactive({
      d <- dat("bonds")
      if (!nrow(d)) return(d)
      d |>
        dplyr::filter(.data$bond_code %in% MARKETS_BENCH) |>
        dplyr::select(date = "date", series = "bond_code", value = "yield")
    }),
    build = function(df) {
      chart_line(df, y = "value", series = "series", unit = "%", digits = 2,
                 freq = "day", end_labels = TRUE)
    }
  )

  figure_server(
    "mk_twi",
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

  # Density only, per the backtest verdict: the bands are the product and the
  # median is not presented as a directional call.
  figure_server(
    "mk_isk_fan",
    data = shiny::reactive({
      fx <- dat("forecast_fx")
      if (!nrow(fx)) return(tibble::tibble())
      fx |>
        dplyr::select("forecast_date", "quantile", "value") |>
        tidyr::pivot_wider(names_from = "quantile", values_from = "value") |>
        dplyr::rename_with(~ paste0("q", sub("^0\\.", "", .x)), -"forecast_date") |>
        dplyr::rename(date = "forecast_date") |>
        dplyr::rename_with(~ sub("^q5$", "q50", .x)) |>
        dplyr::mutate(actual = NA_real_) |>
        dplyr::arrange(.data$date)
    }),
    build = function(df) forecast_chart(df, unit = "%", digits = 2,
                                        label = lbl("d_ltwi")),
    table = function(df) {
      fx <- dat("forecast_fx")
      if (!nrow(fx)) return(tibble::tibble())
      w <- fx |>
        dplyr::filter(.data$horizon %in% c(1, 3, 6, 12, 18)) |>
        dplyr::select("horizon", "forecast_date", "quantile", "value") |>
        tidyr::pivot_wider(names_from = "quantile", values_from = "value")
      tibble::tibble(
        `Sjóndeild` = paste0(w$horizon, " mán."),
        `Mánuður` = format(w$forecast_date, "%Y-%m"),
        `90% bil` = paste0(
          formatC(w[["0.05"]], format = "f", digits = 2, decimal.mark = ","),
          "–",
          formatC(w[["0.95"]], format = "f", digits = 2, decimal.mark = ",")))
    }
  )
}

MARKETS_BENCH <- c("RIKB 28 1115", "RIKB 31 0124", "RIKB 35 0917")

# The two market tables render through their own outputs.
page_markets_tables_server <- function(output) {

  output$mk_bonds_tbl <- reactable::renderReactable({
    attrs <- dat("bond_attrs"); bonds <- dat("bonds")
    shiny::validate(shiny::need(nrow(attrs) > 0, lbl("no_data")))
    latest <- if (nrow(bonds)) {
      bonds |>
        dplyr::filter(.data$date == max(.data$date)) |>
        dplyr::select("orderbookid", "yield", "price")
    } else tibble::tibble(orderbookid = character())

    tb <- attrs |>
      dplyr::left_join(latest, by = "orderbookid") |>
      dplyr::transmute(
        `Bréf` = .data$bond_code,
        `Tegund` = ifelse(dplyr::coalesce(.data$indexed, FALSE),
                          "Verðtryggt", "Óverðtryggt"),
        `Gjalddagi` = format(.data$maturity, "%d.%m.%Y"),
        `Nafnvextir %` = round(.data$coupon, 2),
        `Krafa %` = round(.data$yield, 2),
        `Verð` = round(.data$price, 2),
        ISIN = .data$isin) |>
      dplyr::arrange(.data$`Tegund`, .data$`Gjalddagi`)

    reactable::reactable(
      tb, compact = TRUE, striped = TRUE, highlight = TRUE,
      defaultPageSize = 13, showPageSizeOptions = FALSE,
      defaultColDef = reactable::colDef(
        format = reactable::colFormat(locales = "is-IS"), minWidth = 90, na = "—"))
  })

  output$mk_tbills_tbl <- reactable::renderReactable({
    d <- dat("tbills")
    shiny::validate(shiny::need(nrow(d) > 0, lbl("no_data")))
    tb <- d |>
      dplyr::transmute(
        `Útboð` = format(.data$date, "%d.%m.%Y"),
        `Flokkur` = .data$series,
        `Krafa %` = round(.data$yield, 3),
        `Þekja` = round(.data$bid_to_cover, 2),
        `Samþykkt (m.kr.)` = round(.data$accepted_mkr, 0))
    reactable::reactable(
      tb, compact = TRUE, striped = TRUE, highlight = TRUE,
      defaultPageSize = 13, showPageSizeOptions = FALSE,
      defaultColDef = reactable::colDef(
        format = reactable::colFormat(locales = "is-IS"), minWidth = 90, na = "—"))
  })
}
