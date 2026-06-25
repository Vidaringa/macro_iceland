# Monthly — ownership of government securities (Seðlabankinn / gagnabanki) ----
# Holdings of Treasury bonds & bills (RIKB/RIKS/… and "Víxlar alls") broken down
# by holder type, from the gagnabanki report `securities` (Eigendur
# ríkisverðbréfa). Foreign ownership of government bonds (holder FOREIGN) is the
# requested heat-index input; the other seven holder types are stored alongside
# it since the source breaks them out 1:1. Monthly in M.kr.
#
# Sourced by run_monthly.R, which provides `con`, has attached tidyverse +
# httr2 + jsonlite, and sourced the DB helpers and R/ingest/sedlabanki.R.
# Target table: govt_bond_owners (date, security, holder, value), upsert on
# (date, security, holder).
#
# ACCESS MODE (c) — Excel-only, via the gagnabanki Angular blob download
# (gagnabanki_report_xlsx in R/ingest/sedlabanki.R): no stable download URL
# exists; the workbook is built client-side and captured by hooking
# URL.createObjectURL. The "Gögn" sheet shares the EXACT shape of the historical
# CSV (raw_data/eigendur_rikisbrefa.csv), so one reader —
# gagnabanki_bond_owners_long — tidies both.
#
# APPEND-ONLY: the live report only exposes a rolling ~18-month window, so this
# pulls that window each run and upserts it; the deep history (from 2008-09) is
# loaded ONCE by R/seed/eigendur_rikisbrefa_seed.R. The (date, security, holder)
# upsert key means the live window's overlap with the seed is an idempotent
# no-op refresh, never a duplicate — so history is appended to, not rewritten.

get_cbi_govt_bond_owners <- function() {
  xlsx <- gagnabanki_report_xlsx("securities")
  raw  <- readxl::read_excel(xlsx, sheet = "Gögn", .name_repair = "minimal")
  gagnabanki_bond_owners_long(raw)
}

govt_bond_owners_tbl <- get_cbi_govt_bond_owners()

db_ensure_table(con, "govt_bond_owners",
                cols = c(date = "DATE", security = "TEXT",
                         holder = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "security", "holder"))
db_upsert(con, "govt_bond_owners", govt_bond_owners_tbl,
          conflict_cols = c("date", "security", "holder"))
