# run_quarterly.R — quarterly ingestion orchestrator
#
# Thin runner (same shape as run_daily.R / run_monthly.R): attaches the shared
# libraries, sources the DB helpers and the shared Hagstofa PX-Web helper, opens
# ONE Postgres connection, then sources every ingest file in R/ingest/quarterly/
# (each pulls its source and upserts against `con`), and disconnects last.
#
# Each source runs in its own tryCatch: a source failing (a quarter not yet
# published, an endpoint down) is logged as a warning and the run continues —
# quarterly national-accounts vintages arrive irregularly, so a series not
# updating is logged-missing, not a pipeline failure (PROJECT.md §7).
#
# Run from the repo root so the relative source() paths resolve.

# 1.0.0 SETUP ----
library(tidyverse)
library(httr2)
library(jsonlite)
library(DBI)
library(RPostgres)

source(file.path("R", "db", "db_helpers.R"))
source(file.path("R", "ingest", "hagstofa.R"))

# 2.0.0 RUN ----
con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)

ingest_files <- list.files(
  file.path("R", "ingest", "quarterly"),
  pattern = "\\.R$", full.names = TRUE
) |> sort()

failures <- character()
for (f in ingest_files) {
  ok <- tryCatch({
    source(f, local = TRUE)
    TRUE
  }, error = function(e) {
    warning("Ingest source failed: ", basename(f), " — ", conditionMessage(e),
            call. = FALSE, immediate. = TRUE)
    FALSE
  })
  if (!ok) failures <- c(failures, basename(f))
}

# 3.0.0 TEARDOWN ----
DBI::dbDisconnect(con)
on.exit()

if (length(failures) > 0) {
  warning("Quarterly run completed with failed sources: ",
          paste(failures, collapse = ", "), call. = FALSE)
} else {
  message("Quarterly run completed: all ", length(ingest_files), " sources OK.")
}
