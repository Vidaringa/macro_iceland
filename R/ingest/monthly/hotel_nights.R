# Monthly — hotel / accommodation overnight stays (Hagstofa) ----
# Gistinætur from PX-Web SAM01601.px: overnight stays across ALL registered
# accommodation types, all nationalities, whole country — a tourism heat-index
# input (SPEC A1). Monthly from 1998.
#
# Table shape note: unlike most PX-Web tables this one splits time into SEPARATE
# year (Ár) and month-number (Mánuður) dimensions rather than a "2026M05" code,
# and Mánuður = "0" is the annual "Alls" total — which we drop, keeping the 12
# real months and building the date from year + month number.
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# hotel_nights (date, series, value), upsert on (date, series).

get_hagstofa_hotel_nights <- function() {
  hagstofa_pxweb_query(
    "Atvinnuvegir/ferdathjonusta/Gisting/3_allartegundirgististada/SAM01601.px",
    selections = list(
      "Þjóðerni"   = "Total",   # all nationalities
      "Landshluti" = "IS",      # whole country
      "Eining"     = "0"        # Gistinætur (overnight stays, not guest arrivals)
    )
  ) |>
    dplyr::filter(`Mánuður` != "0") |>   # drop the annual 'Alls' row
    dplyr::transmute(
      date   = lubridate::make_date(as.integer(`Ár`), as.integer(`Mánuður`), 1L),
      series = "HOTEL_NIGHTS",
      value
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date)
}

hotel_nights_tbl <- get_hagstofa_hotel_nights()

db_ensure_table(con, "hotel_nights",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "hotel_nights", hotel_nights_tbl, conflict_cols = c("date", "series"))
