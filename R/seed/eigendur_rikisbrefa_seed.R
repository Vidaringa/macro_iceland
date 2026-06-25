# One-time seed — historical government-securities ownership ----
# Loads the deep history of government-bond/bill holdings (2008-09 onward) from
# raw_data/eigendur_rikisbrefa.csv into the govt_bond_owners table. RUN ONCE.
#
# The live gagnabanki `securities` report only exposes a rolling ~18-month
# window (handled by R/ingest/monthly/govt_bond_owners.R), so the years before
# that window exist only in this hand-saved CSV. This script seeds them; the
# monthly ingest then keeps only the recent window fresh. Both write the same
# (date, security, holder) key, so re-running the monthly job over the seeded
# overlap is an idempotent no-op rather than a duplicate.
#
# Self-contained (NOT sourced by run_monthly.R): attaches its own libraries,
# opens its own connection. Run from the repo root:
#   Rscript R/seed/eigendur_rikisbrefa_seed.R

library(tidyverse)
library(DBI)
library(RPostgres)

source(file.path("R", "db", "db_helpers.R"))
source(file.path("R", "ingest", "sedlabanki.R"))

raw <- readr::read_delim(
  file.path("raw_data", "eigendur_rikisbrefa.csv"),
  delim = ";", locale = readr::locale(encoding = "UTF-8"),
  show_col_types = FALSE
)
tbl <- gagnabanki_bond_owners_long(raw)

con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)

db_ensure_table(con, "govt_bond_owners",
                cols = c(date = "DATE", security = "TEXT",
                         holder = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "security", "holder"))
db_upsert(con, "govt_bond_owners", tbl,
          conflict_cols = c("date", "security", "holder"))

message("Seeded govt_bond_owners with ", nrow(tbl), " rows from ",
        format(min(tbl$date)), " to ", format(max(tbl$date)), ".")
