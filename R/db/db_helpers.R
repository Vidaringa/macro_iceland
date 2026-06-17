# Shared Postgres DB helpers
#
# db_connect / db_upsert / db_ensure_table — the single source of these helpers.
# Every cadence runner (run_daily.R, run_monthly.R, ...) source()s this file
# rather than redefining them inline. Logic is unchanged from its original home
# in get_daily_data.R; this file only relocates it so all runners share it.
#
# Requires DBI and RPostgres to be attached by the sourcing runner.

# Single shared Postgres connection for a whole run (not one per source).
# Connection params come from the standard libpq env vars
# (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD); RPostgres reads them itself.
db_connect <- function() {
  DBI::dbConnect(RPostgres::Postgres())
}

# Upsert a tibble on its key columns: insert new rows, update existing ones,
# append the tail without rewriting history. Done via a staging temp table +
# INSERT ... ON CONFLICT so re-running the daily job is idempotent.
db_upsert <- function(con, table, tbl, conflict_cols) {
  if (nrow(tbl) == 0) return(invisible(0L))
  staging <- paste0("_stage_", table)
  DBI::dbWriteTable(con, staging, as.data.frame(tbl),
                    temporary = TRUE, overwrite = TRUE)
  cols      <- DBI::dbQuoteIdentifier(con, names(tbl))
  keys      <- DBI::dbQuoteIdentifier(con, conflict_cols)
  updates   <- names(tbl)[!names(tbl) %in% conflict_cols]
  set_clause <- if (length(updates) == 0) {
    # key-only table: nothing to update, just skip duplicates
    "NOTHING"
  } else {
    paste0("UPDATE SET ",
           paste(sprintf("%1$s = EXCLUDED.%1$s",
                         DBI::dbQuoteIdentifier(con, updates)),
                 collapse = ", "))
  }
  sql <- sprintf(
    "INSERT INTO %s (%s) SELECT %s FROM %s ON CONFLICT (%s) DO %s",
    DBI::dbQuoteIdentifier(con, table),
    paste(cols, collapse = ", "),
    paste(cols, collapse = ", "),
    DBI::dbQuoteIdentifier(con, staging),
    paste(keys, collapse = ", "),
    set_clause
  )
  on.exit(DBI::dbRemoveTable(con, staging, fail_if_missing = FALSE), add = TRUE)
  DBI::dbExecute(con, sql)
}

# Create a table if it does not already exist. `db_upsert` does INSERT INTO an
# existing table (no implicit CREATE), so a source's first-ever run needs its
# target table to exist. `cols` maps column name -> SQL type; `pk` names the
# primary-key columns (the same columns later used as upsert conflict keys).
db_ensure_table <- function(con, table, cols, pk) {
  if (DBI::dbExistsTable(con, table)) return(invisible(FALSE))
  col_defs <- paste(
    DBI::dbQuoteIdentifier(con, names(cols)), unname(cols),
    collapse = ", "
  )
  pk_clause <- paste0(
    ", PRIMARY KEY (",
    paste(DBI::dbQuoteIdentifier(con, pk), collapse = ", "),
    ")"
  )
  DBI::dbExecute(con, sprintf(
    "CREATE TABLE IF NOT EXISTS %s (%s%s)",
    DBI::dbQuoteIdentifier(con, table), col_defs, pk_clause
  ))
  invisible(TRUE)
}
