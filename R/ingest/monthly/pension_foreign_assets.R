# Monthly — pension-fund foreign vs total assets (Seðlabankinn / gagnabanki) ----
# Total and foreign assets of the pension funds, from the gagnabanki balance-
# sheet report MARKETS.PENSIONFUNDS.OVERVIEW.TABLE (sheet LIF_BALANCE_SHEETS_
# TOTAL). The foreign-asset SHARE (foreign / total) is the quantity of interest:
# pension funds are bound by a statutory 50% ceiling on assets held abroad, and
# the share has been climbing toward it (≈41% as of 2026-04). A capital-flow /
# FX-pressure heat-index input (SPEC A1). Stored as the two component levels so
# the share — and the distance to the 50% ceiling — is derived downstream.
# M.kr., monthly from 1997-01. (data_sources.md listed this quarterly; the CBI
# balance sheet is in fact monthly.)
#
# Sourced by run_monthly.R, which provides `con`, has attached tidyverse +
# httr2 + jsonlite, and sourced the DB helpers and R/ingest/sedlabanki.R.
# Target table: pension_foreign_assets (date, series, value), upsert on
# (date, series).
#
# ACCESS MODE (c) — Excel-only, via the gagnabanki Angular blob download
# (gagnabanki_report_xlsx / gagnabanki_wide_rows in R/ingest/sedlabanki.R): no
# stable public download URL exists (the CBI SDMX host fr.sedlabanki.is is not
# reachable externally), so the workbook is built client-side and captured by
# hooking URL.createObjectURL. Unlike the loans reports, this balance-sheet
# workbook starts its date columns at col B, so first_col = 2. Source rows
# (1-based, date header in row 3): 4 = total assets (Eignir samtals), 28 =
# foreign assets (Erlendar eignir); total = domestic (row 5) + foreign exactly.

get_cbi_pension_foreign_assets <- function() {
  xlsx <- gagnabanki_report_xlsx(
    "pension",
    report = "MARKETS.PENSIONFUNDS.OVERVIEW.TABLE"
  )
  gagnabanki_wide_rows(xlsx, first_col = 2L, rows = c(
    PENSION_ASSETS_TOTAL   = 4L,   # Eignir samtals
    PENSION_ASSETS_FOREIGN = 28L   # Erlendar eignir
  ))
}

pension_foreign_assets_tbl <- get_cbi_pension_foreign_assets()

db_ensure_table(con, "pension_foreign_assets",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "pension_foreign_assets", pension_foreign_assets_tbl,
          conflict_cols = c("date", "series"))
