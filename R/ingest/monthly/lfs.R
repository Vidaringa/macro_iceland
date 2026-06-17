# Monthly — Labour Force Survey (Hagstofa) ----
# Vinnumarkaðsrannsókn monthly, measured (not seasonally adjusted) series from
# PX-Web VIN00001.px, total population (Kyn/aldur = 0, "Alls"). We pull the four
# labour signals a coincident heat index uses (SPEC A1):
#
#   LFS_EMPLOYED      = Starfandi          (Eining 4, employed, level, thousands)
#   LFS_PARTICIPATION = Atvinnuþátttaka    (Eining 6, participation rate, %)
#   LFS_UNEMPLOYMENT  = Atvinnuleysi       (Eining 7, unemployment rate, %)
#   LFS_HOURS         = Unnar stundir      (Eining 11, hours worked)
#
# Measured (not seasonally adjusted) is taken deliberately: the DFM standardises
# and handles seasonality on its inputs, so the raw series is the canonical
# source-of-truth and avoids baking in Hagstofa's adjustment choice. (The
# seasonally adjusted variant lives in VIN00002 if ever needed.)
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/hagstofa.R sourced). Target table:
# lfs (date, series, value), upsert on (date, series).

lfs_units <- c(
  "4"  = "LFS_EMPLOYED",
  "6"  = "LFS_PARTICIPATION",
  "7"  = "LFS_UNEMPLOYMENT",
  "11" = "LFS_HOURS"
)

get_hagstofa_lfs <- function() {
  hagstofa_pxweb_query(
    "Samfelag/vinnumarkadur/vinnumarkadsrannsokn/1_manadartolur/VIN00001.px",
    selections = list(
      "Kyn/aldur" = "0",            # total population
      "Eining"    = names(lfs_units)
    )
  ) |>
    dplyr::transmute(
      date   = hagstofa_month_to_date(`Mánuður`),
      series = unname(lfs_units[`Eining`]),
      value
    ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

lfs_tbl <- get_hagstofa_lfs()

db_ensure_table(con, "lfs",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "lfs", lfs_tbl, conflict_cols = c("date", "series"))
