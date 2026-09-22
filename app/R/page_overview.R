# Yfirlit — the front page ----
#
# A KPI row of five tiles over two hero figures. The tiles are rendered into the
# static HTML by ui(), so the headline numbers arrive WITH the page rather than
# after a server round trip — the difference between a publication and a
# dashboard that boots in front of you.

page_overview_ui <- function() {
  policy   <- dat("policy")
  heat     <- dat("heat_level")
  cpi      <- dat("cpi")
  fx       <- dat("fx")
  bonds    <- dat("bonds")
  vint     <- dat("vintages")

  # Policy rate: the hero. Its delta is the size of the last actual change.
  p_last <- if (nrow(policy)) dplyr::last(policy$value) else NA_real_
  p_chg  <- if (nrow(policy)) {
    v <- policy$value
    i <- which(v != dplyr::lag(v))
    if (length(i)) v[max(i)] - v[max(i) - 1] else NA_real_
  } else NA_real_
  p_chg_date <- if (nrow(policy)) {
    v <- policy$value; i <- which(v != dplyr::lag(v))
    if (length(i)) format(policy$date[max(i)], "%d.%m.%Y") else NULL
  } else NULL
  p_spark <- if (nrow(policy)) {
    policy |>
      dplyr::mutate(m = lubridate::floor_date(.data$date, "month")) |>
      dplyr::group_by(.data$m) |>
      dplyr::summarise(v = dplyr::last(.data$value), .groups = "drop") |>
      dplyr::pull("v") |> utils::tail(24)
  } else numeric()

  h_last <- if (nrow(heat)) dplyr::last(heat$index) else NA_real_
  h_prev <- if (nrow(heat) > 1) heat$index[nrow(heat) - 1] else NA_real_
  h_prov <- nrow(heat) && isTRUE(dplyr::last(heat$provisional))

  cpi_s  <- tile_stats(cpi, "CPI_change_A", lag_days = 370)
  twi_s  <- tile_stats(fx, "TWI", lag_days = 30)

  # A 10-year benchmark proxy: the nominal bond maturing nearest ten years out.
  bond10 <- overview_bond10(bonds, dat("bond_attrs"))

  htmltools::tagList(
    htmltools::tags$div(
      class = "page__head",
      htmltools::tags$h1("Yfirlit"),
      htmltools::tags$p(
        class = "lede",
        "Staða íslensks þjóðarbúskapar og vaxtamarkaðar — hitastig hagkerfisins, ",
        "stýrivextir og vaxtaferill, uppfært daglega úr opinberum gögnum.")
    ),

    htmltools::tags$div(
      class = "grid grid--tiles",
      stat_tile("Stýrivextir", fmt_num(p_last, 2), "%", hero = TRUE,
                delta = p_chg, delta_label = p_chg_date,
                spark = spark_svg(p_spark)),
      stat_tile("Hitastig hagkerfisins", fmt_num(h_last, 2),
                delta = if (!is.na(h_last) && !is.na(h_prev)) h_last - h_prev else NULL,
                delta_label = "frá fyrri mánuði",
                spark = spark_svg(utils::tail(heat$index, 24)),
                note = if (h_prov) paste0(lbl("provisional"), ": ",
                                          dplyr::last(heat$n_observed), " af ",
                                          dplyr::last(heat$n_total), " vísum") else NULL),
      stat_tile("Verðbólga", fmt_num(cpi_s$value, 1), "%",
                delta = cpi_s$delta, delta_label = "frá fyrra ári",
                spark = spark_svg(cpi_s$spark)),
      stat_tile("Gengisvísitala", fmt_num(twi_s$value, 1),
                delta = twi_s$delta, delta_label = "frá fyrri mánuði",
                spark = spark_svg(twi_s$spark)),
      stat_tile(bond10$label, fmt_num(bond10$value, 2), "%",
                delta = bond10$delta, delta_label = "frá fyrri viku",
                spark = spark_svg(bond10$spark))
    ),

    htmltools::tags$div(
      class = "grid grid--2", style = "margin-top:20px",
      figure_ui("ov_heat", "Hitastig hagkerfisins",
                "Staðalfrávik frá leitni — núll er meðalstaða",
                source = "Eigin útreikningur",
                data_to = vintage_of("heatindex_level"),
                computed_at = computed_of("heat")),
      figure_ui("ov_policy", "Stýrivextir og spáð þróun",
                "Prósent — söguleg þróun og 18 mánaða spá",
                source = "Seðlabanki Íslands, eigin útreikningur",
                data_to = vintage_of("rates_policy"),
                computed_at = computed_of("bvar"))
    ),

    htmltools::tags$div(
      style = "margin-top:20px",
      figure_ui("ov_infl", "Verðbólga og spáð þróun",
                "Prósent — ársbreyting vísitölu neysluverðs og 18 mánaða spá",
                source = "Hagstofa Íslands, eigin útreikningur",
                data_to = vintage_of("cpi"),
                computed_at = computed_of("bvar"),
                class = "fig--flat")
    ),

    htmltools::tags$div(
      class = "strip",
      htmltools::tags$span(htmltools::tags$b(lbl("latest_strip"))),
      lapply(seq_len(nrow(vint)), function(i) htmltools::tags$span(
        overview_vintage_label(vint$tbl[i]), " ",
        htmltools::tags$b(format(as.Date(vint$data_to[i]), "%d.%m.%Y"))))
    )
  )
}

# Human labels for the vintage strip. Kept beside the page that shows it since
# these are provenance names for TABLES, not series codes in LABELS.
overview_vintage_label <- function(tbl) {
  c(rates_policy = "Stýrivextir", rates_reibor = "REIBOR", fx_daily = "Gengi",
    rates_external = "Erlendir vextir", cpi = "Verðbólga",
    tbill_auctions = "Ríkisvíxlar", heatindex_level = "Hitastig",
    forecast_policy_rate = "Vaxtaspá", bonds_daily = "Ríkisbréf")[tbl] |>
    unname() |> (\(x) if (is.na(x)) tbl else x)()
}

# The nominal bond closest to ten years to maturity, with its latest yield and
# one-week change. A proxy for the long end until the A3 curve model exists —
# and labelled as the actual bond so it is never mistaken for a fitted 10y.
overview_bond10 <- function(bonds, attrs) {
  empty <- list(label = "Ríkisbréf, 10 ára", value = NA_real_,
                delta = NA_real_, spark = numeric())
  if (!nrow(bonds) || !nrow(attrs)) return(empty)

  as_of <- max(bonds$date)
  nominal <- attrs |>
    dplyr::filter(!.data$indexed, !is.na(.data$maturity)) |>
    dplyr::mutate(yrs = as.numeric(.data$maturity - as_of) / 365.25) |>
    dplyr::filter(.data$yrs > 0)
  if (!nrow(nominal)) return(empty)

  pick <- nominal$orderbookid[which.min(abs(nominal$yrs - 10))]
  code <- nominal$bond_code[nominal$orderbookid == pick][1]
  s <- bonds |> dplyr::filter(.data$orderbookid == pick) |> dplyr::arrange(.data$date)
  if (!nrow(s)) return(empty)

  prior <- s$yield[s$date <= as_of - 7]
  list(
    label = code,
    value = dplyr::last(s$yield),
    delta = if (length(prior)) dplyr::last(s$yield) - dplyr::last(prior) else NA_real_,
    spark = utils::tail(s$yield, 20)
  )
}

page_overview_server <- function(id = "overview") {

  figure_server(
    "ov_heat",
    data = shiny::reactive({
      d <- dat("heat_level")
      if (nrow(d)) dplyr::filter(d, .data$date >= max(.data$date) - 3660) else d
    }),
    build = function(df) {
      chart_line(df, y = "index", unit = "", digits = 2, freq = "month",
                 baseline = 0, dashed = "provisional",
                 mark_areas = RECESSIONS[RECESSIONS$to >= min(df$date), ])
    },
    table = function(df) {
      df |>
        dplyr::transmute(
          !!lbl("date") := format(.data$date, "%Y-%m"),
          Hitastig = round(.data$index, 2),
          `Vísar` = paste0(.data$n_observed, "/", .data$n_total)) |>
        dplyr::arrange(dplyr::desc(.data[[lbl("date")]]))
    }
  )

  figure_server(
    "ov_policy",
    data = shiny::reactive(policy_path_frame(years = 5)),
    build = function(df) policy_path_chart(df),
    table = function(df) policy_path_table(df)
  )

  figure_server(
    "ov_infl",
    data = shiny::reactive({
      h <- dplyr::filter(dat("cpi"), .data$series == "CPI_change_A") |>
        dplyr::select("date", "value")
      forecast_frame(h, "infl", years = 5)
    }),
    build = function(df) forecast_chart(df, unit = "%", digits = 2,
                                        label = lbl("infl")),
    table = function(df) forecast_table("infl")
  )
}
