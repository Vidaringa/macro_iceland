# Monthly — new household mortgages from banks (Seðlabankinn) ----
# New residential-mortgage credit to households from deposit-taking corporations
# (banks), net of pre-/over-payments, from the gagnabanki report
# FINSTATS.MONETARY.NEWCREDIT.TABLE. The bank counterpart to PENSION_NEW_LOANS_*;
# named to pair with / sum against the pension-fund new-lending series. M.kr.,
# monthly from 2013-01.
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/sedlabanki.R sourced). Target table:
# bank_new_mortgages (date, series, value), upsert on (date, series).
#
# ACCESS MODE (c) — gagnabanki Angular blob download, FAME-export workbook
# (gagnabanki_serial_rows): single data sheet "I", date header Excel serials in
# row 10, data from col B; labels in col A. The sheet repeats the household
# residential-mortgage rows (floating + fixed rate) in three blocks; each pair
# is SUMMED into one figure:
#   43 + 44  -> total new HH mortgages            (block "New credit")
#   81 + 82  -> new UNINDEXED (óverðtryggð) HH mortgages (block "New unindexed credit")
#  119 + 120 -> new INDEXED   (verðtryggð)  HH mortgages (block "New indexed credit")

get_cbi_bank_new_mortgages <- function() {
  xlsx <- gagnabanki_report_xlsx("monetary", report = "FINSTATS.MONETARY.NEWCREDIT.TABLE")
  gagnabanki_serial_rows(xlsx, sheet = "I", header_row = 10, first_col = 2,
    groups = list(
      BANK_NEW_MORTGAGE_HH_TOTAL     = c(43L, 44L),
      BANK_NEW_MORTGAGE_HH_UNINDEXED = c(81L, 82L),
      BANK_NEW_MORTGAGE_HH_INDEXED   = c(119L, 120L)
    ))
}

bank_new_mortgages_tbl <- get_cbi_bank_new_mortgages()

db_ensure_table(con, "bank_new_mortgages",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "bank_new_mortgages", bank_new_mortgages_tbl,
          conflict_cols = c("date", "series"))
