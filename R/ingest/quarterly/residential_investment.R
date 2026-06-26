# Quarterly — residential investment (Hagstofa) ----
# Fjármunamyndun í íbúðarhúsnæði (residential gross fixed capital formation),
# chain-volume seasonally-adjusted, quarterly from 1995Q1. A heat-index input
# (SPEC A1) and the deepest construction-activity signal we have: residential
# investment collapsed ~56% year-on-year through the 2008-09 crisis, so together
# with house_prices it makes the GFC visible to the heat index where the
# late-starting (2015+) trade series cannot.
#
# Source: PX-Web THJ03111, Mælikvarði=3 (keðjutengt, árstíðaleiðrétt / chain-
# volume SA), Skipting=2 (Íbúðarhús). Unlike the JSON-stat tables wrapped by
# hagstofa.R, this is requested as CSV (response=csv): a wide layout with one
# column per quarter ("1995Á1"), so it is parsed directly here. Endpoint + cell
# mapping taken from hagdeild/thjodhagslikan (R/data/03_real_activity/
# residential_investment.R).
#
# Sourced by run_quarterly.R (provides `con`; tidyverse + httr2 attached; DB
# helpers sourced). Target table: residential_investment (date, series, value),
# upsert on (date, series).

RESINV_PX <- paste0(
  "https://px.hagstofa.is/pxis/api/v1/is/Efnahagur/thjodhagsreikningar/",
  "fjarmunamyndun_fjarmunaeign/fjarmunamyndun_arsfj/THJ03111.px"
)

get_hagstofa_residential_investment <- function() {
  raw <- httr2::request(RESINV_PX) |>
    httr2::req_body_json(list(
      query = list(
        list(code = "Mælikvarði", selection = list(filter = "item", values = list("3"))),
        list(code = "Skipting",   selection = list(filter = "item", values = list("2")))
      ),
      response = list(format = "csv")
    )) |>
    httr2::req_timeout(60) |>
    httr2::req_perform() |>
    httr2::resp_body_string(encoding = "UTF-8")

  readr::read_csv(I(raw), show_col_types = FALSE) |>
    dplyr::select(-dplyr::any_of(c("Mælikvarði", "Skipting"))) |>
    tidyr::pivot_longer(dplyr::everything(),
                        names_to = "quarter", values_to = "value") |>
    dplyr::transmute(
      date = lubridate::make_date(
        as.integer(stringr::str_sub(quarter, 1, 4)),
        (as.integer(stringr::str_sub(quarter, 6, 6)) - 1L) * 3L + 1L, 1L),
      series = "RESIDENTIAL_INVESTMENT",
      value
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date)
}

residential_investment_tbl <- get_hagstofa_residential_investment()

db_ensure_table(con, "residential_investment",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "residential_investment", residential_investment_tbl,
          conflict_cols = c("date", "series"))
