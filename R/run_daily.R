# run_daily.R — daily ingestion orchestrator
#
# Thin runner: no pulling/cleaning logic lives here. It attaches the shared
# libraries, sources the DB helpers and the bond-attribute helpers, opens ONE
# Postgres connection for the whole run, then sources every ingest file in
# R/ingest/daily/ (each pulls its source and upserts against `con`), and
# disconnects last.
#
# Each source is run independently: if one source fails (network blip, a
# scrape returning nothing, an endpoint down) it is logged as a warning and the
# run continues with the next source, rather than aborting the whole daily job.
# This matches the ragged-edge rule (a series not updating is logged-missing,
# not a pipeline failure). Failures are summarised at the end.
#
# Run from the repo root (the scheduled task sets the working directory there)
# so the relative source() paths resolve.

# 1.0.0 SETUP ----
library(tidyverse)
library(chromote)
library(rvest)
library(xml2)
library(httr2)
library(fredr)
library(quantmod)
library(DBI)
library(RPostgres)

# API keys (e.g. the FRED key) live in the HOME .Renviron, but R only auto-reads
# the .Renviron in the working directory — the repo root, which holds just the
# PG connection vars. We must NOT blanket-load the HOME .Renviron: it defines a
# DIFFERENT Postgres target (PGDATABASE/PGUSER) than the repo file, and loading
# it would silently switch the run onto the wrong database. So we read the HOME
# file into a temporary env and lift out only the keys we need, leaving the
# already-loaded repo PG vars untouched.
local({
  home_renv <- path.expand("~/.Renviron")
  if (file.exists(home_renv)) {
    e <- new.env()
    readRenviron <- NULL  # avoid accidental shadowing; use base explicitly below
    # Parse KEY=VALUE / KEY = "VALUE" lines without mutating the session env.
    lines <- readLines(home_renv, warn = FALSE)
    kv <- stringr::str_match(lines, '^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*"?([^"]*)"?\\s*$')
    keep <- c("FRED_API_KEY", "FREDR")  # only the keys daily ingest needs
    for (i in which(!is.na(kv[, 2]) & kv[, 2] %in% keep)) {
      if (!nzchar(Sys.getenv(kv[i, 2]))) {
        do.call(Sys.setenv, setNames(list(kv[i, 3]), kv[i, 2]))
      }
    }
  }
})

# Shared DB helpers (db_connect / db_upsert / db_ensure_table).
source(file.path("R", "db", "db_helpers.R"))

# Shared ECB Data Portal helper (ecb_series), used by the ECB rate source.
source(file.path("R", "ingest", "ecb.R"))

# Bond-attribute helpers (chromote scrape + Icelandic->English map) live in the
# one-time pull script; the daily new-bond reconciliation in bonds.R reuses
# them. Sourcing is guarded (sys.nframe() != 0L), so only the helpers load.
source(file.path("R", "get_bond_attributes.R"))

# 2.0.0 RUN ----
con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)

# Source every ingest file in the daily folder, in sorted order. Each is run in
# its own tryCatch so one failure does not abort the rest of the run.
ingest_files <- list.files(
  file.path("R", "ingest", "daily"),
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
  warning("Daily run completed with failed sources: ",
          paste(failures, collapse = ", "), call. = FALSE)
} else {
  message("Daily run completed: all ", length(ingest_files), " sources OK.")
}
