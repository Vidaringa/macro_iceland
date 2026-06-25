# run_models.R — model orchestrator
#
# Thin runner (same shape as run_monthly.R): attaches the shared libraries,
# sources the DB helpers, opens ONE Postgres connection, then sources every model
# file in R/models/ (each reads canonical series, computes, and upserts its model
# outputs against `con`), and disconnects last. Runs AFTER the ingest runners so it
# reads the freshly upserted canonical series.
#
# Each model runs in its own tryCatch: a model failing (e.g. too few observed
# series this vintage) is logged as a warning and the run continues — consistent
# with the ragged-edge rule (a model not updating is logged-missing, not a pipeline
# failure). Subdirectories (R/models/checks/) are NOT sourced — only top-level
# model files.
#
# Run from the repo root so the relative source() paths resolve.

# 1.0.0 SETUP ----
library(tidyverse)
library(dfms)
library(BVAR)
library(DBI)
library(RPostgres)
# zoo is used via zoo:: (na.approx) in the A2 module; not attached to avoid masking.

source(file.path("R", "db", "db_helpers.R"))

# 2.0.0 RUN ----
con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)

model_files <- list.files(
  file.path("R", "models"),
  pattern = "\\.R$", full.names = TRUE
) |> sort()

failures <- character()
for (f in model_files) {
  ok <- tryCatch({
    source(f, local = TRUE)
    TRUE
  }, error = function(e) {
    warning("Model failed: ", basename(f), " — ", conditionMessage(e),
            call. = FALSE, immediate. = TRUE)
    FALSE
  })
  if (!ok) failures <- c(failures, basename(f))
}

# 3.0.0 TEARDOWN ----
DBI::dbDisconnect(con)
on.exit()

if (length(failures) > 0) {
  warning("Model run completed with failures: ",
          paste(failures, collapse = ", "), call. = FALSE)
} else {
  message("Model run completed: all ", length(model_files), " models OK.")
}
