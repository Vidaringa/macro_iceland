# Monthly — deposit-institution (bank) lending by sector (Seðlabankinn) ----
# Outstanding loans of deposit-taking corporations (banks), from the gagnabanki
# report FINSTATS.MONETARY.LOANS.TABLE. The bank counterpart to the pension-fund
# lending series, named to pair with them (BANK_* vs PENSION_*). M.kr., monthly.
# Sheet IV = households (indexed / unindexed residential mortgages); sheet V =
# non-financial companies (total business lending).
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite
# attached; DB helpers and R/ingest/sedlabanki.R sourced). Target table:
# bank_loans_sector (date, series, value), upsert on (date, series).
#
# ACCESS MODE (c) — gagnabanki Angular blob download. This is a FAME-export
# workbook (gagnabanki_serial_rows): date header is Excel serials in row 9, data
# from col C; labels live in col B. Source rows — sheet IV: 15 = household
# indexed residential mortgages (Verðtryggð, Með veð í íbúð), 18 = household
# unindexed residential mortgages (Önnur útlán, Með veð í íbúð). Sheet V: 10 =
# total loans to non-financial companies (Útlán til atvinnufyrirtækja).
# Mirrors PENSION_LOANS_HH_MORTGAGE_IDX / _UNINDEXED / PENSION_LOANS_CORPORATES.

get_cbi_bank_loans_sector <- function() {
  xlsx <- gagnabanki_report_xlsx("monetary", report = "FINSTATS.MONETARY.LOANS.TABLE")
  dplyr::bind_rows(
    gagnabanki_serial_rows(xlsx, sheet = "IV", header_row = 9, first_col = 3,
      groups = list(
        BANK_LOANS_HH_MORTGAGE_IDX   = 15L,  # verðtryggð fasteignalán
        BANK_LOANS_HH_MORTGAGE_UNIDX = 18L   # óverðtryggð fasteignalán
      )),
    gagnabanki_serial_rows(xlsx, sheet = "V", header_row = 9, first_col = 3,
      groups = list(
        BANK_LOANS_CORPORATES = 10L          # Útlán til atvinnufyrirtækja
      ))
  ) |>
    dplyr::arrange(date, series)
}

bank_loans_sector_tbl <- get_cbi_bank_loans_sector()

db_ensure_table(con, "bank_loans_sector",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "bank_loans_sector", bank_loans_sector_tbl,
          conflict_cols = c("date", "series"))
