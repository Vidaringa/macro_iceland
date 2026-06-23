# Monthly — pension-fund lending by sector (Seðlabankinn / gagnabanki) ----
# Outstanding loans of the pension funds broken down by borrower sector, from the
# gagnabanki report MARKETS.PENSIONFUNDS.LOANS.SECTOR.TABLE (sheet
# LIF_BALANCE_SHEETS_LOANS_SECTOR). A household-credit / mortgage heat-index
# input (SPEC A1). Monthly in M.kr. from 1997-02.
#
# Sourced by run_monthly.R, which provides `con`, has attached tidyverse +
# httr2 + jsonlite, and sourced the DB helpers and R/ingest/sedlabanki.R.
# Target table: pension_loans_sector (date, series, value), upsert on
# (date, series).
#
# ACCESS MODE (c) — Excel-only, via the gagnabanki Angular blob download
# (gagnabanki_report_xlsx / gagnabanki_wide_rows in R/ingest/sedlabanki.R): no
# stable download URL exists; the workbook is built client-side and captured by
# hooking URL.createObjectURL. Source rows (1-based, date header in row 3, data
# from col C): 6 = corporates, 15 = households (total), 17 = household indexed
# residential mortgages, 20 = household unindexed residential mortgages.

get_cbi_pension_loans_sector <- function() {
  xlsx <- gagnabanki_report_xlsx(
    "pension",
    report = "MARKETS.PENSIONFUNDS.LOANS.SECTOR.TABLE"
  )
  gagnabanki_wide_rows(xlsx, rows = c(
    PENSION_LOANS_CORPORATES        = 6L,   # Atvinnufyrirtæki
    PENSION_LOANS_HOUSEHOLDS        = 15L,  # Heimili (total)
    PENSION_LOANS_HH_MORTGAGE_IDX   = 17L,  # verðtryggð fasteignalán
    PENSION_LOANS_HH_MORTGAGE_UNIDX = 20L   # óverðtryggð fasteignalán
  ))
}

pension_loans_sector_tbl <- get_cbi_pension_loans_sector()

db_ensure_table(con, "pension_loans_sector",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "pension_loans_sector", pension_loans_sector_tbl,
          conflict_cols = c("date", "series"))
