# Monthly — pension-fund new lending (Seðlabankinn / gagnabanki) ----
# New lending by the pension funds, net of pre-/over-payments, split by
# indexation, from the gagnabanki report at /report/pensionloans (sheet
# LIF_NEW_LOANS_TOTAL). A household-credit / mortgage-flow heat-index input
# (SPEC A1). Monthly in M.kr. from 2009-02.
#
# Sourced by run_monthly.R, which provides `con`, has attached tidyverse +
# httr2 + jsonlite, and sourced the DB helpers and R/ingest/sedlabanki.R.
# Target table: pension_new_loans (date, series, value), upsert on
# (date, series).
#
# ACCESS MODE (c) — Excel-only, via the gagnabanki Angular blob download
# (gagnabanki_report_xlsx / gagnabanki_wide_rows in R/ingest/sedlabanki.R): no
# stable download URL exists; the workbook is built client-side and captured by
# hooking URL.createObjectURL. Source rows (1-based, date header in row 3, data
# from col C): 5 = new indexed lending (M.kr.), 6 = new unindexed lending.

get_cbi_pension_new_loans <- function() {
  xlsx <- gagnabanki_report_xlsx("pensionloans")
  gagnabanki_wide_rows(xlsx, rows = c(
    PENSION_NEW_LOANS_INDEXED   = 5L,  # Verðtryggð útlán
    PENSION_NEW_LOANS_UNINDEXED = 6L   # Óverðtryggð útlán
  ))
}

pension_new_loans_tbl <- get_cbi_pension_new_loans()

db_ensure_table(con, "pension_new_loans",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "pension_new_loans", pension_new_loans_tbl,
          conflict_cols = c("date", "series"))
