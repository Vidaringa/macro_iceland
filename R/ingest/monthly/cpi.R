# Monthly — CPI + core subindices (Hagstofa) ----
# Vísitala neysluverðs from Hagstofa PX-Web table VIS01000.px (base 1988=100).
# We pull the two headline indices — CPI (Vísitala neysluverðs) and CPILH
# (Vísitala neysluverðs án húsnæðis, CPI ex-housing) — and for each both the
# index LEVEL and the year-on-year change (Ársbreyting, %). The index level is
# the canonical source-of-truth series; the YoY change is kept because it is the
# headline inflation number the BVAR reads directly and is not cleanly
# re-derivable across the table's base shifts.
#
# Sourced by run_monthly.R, which provides `con`, has attached tidyverse +
# httr2 + jsonlite, and has sourced the DB helpers and R/ingest/hagstofa.R.
# Target table: cpi (date, series, value), upsert on (date, series). `series`
# is one of CPI_index / CPI_change_A / CPILH_index / CPILH_change_A.

get_hagstofa_cpi <- function() {
  raw <- hagstofa_pxweb_query(
    "Efnahagur/visitolur/1_vnv/1_vnv/VIS01000.px",
    selections = list(
      "Vísitala" = c("CPI", "CPILH"),
      "Liður"    = c("index", "change_A")
    )
  )

  raw |>
    dplyr::transmute(
      date   = hagstofa_month_to_date(`Mánuður`),
      series = paste0(`Vísitala`, "_", `Liður`),
      value
    ) |>
    # Ragged edge: the latest month may be published as an empty cell. Drop NA
    # rows so we log-miss the tail rather than write NA over a future real value.
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

cpi_tbl <- get_hagstofa_cpi()

db_ensure_table(con, "cpi",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "cpi", cpi_tbl, conflict_cols = c("date", "series"))
