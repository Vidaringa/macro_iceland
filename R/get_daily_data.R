# Daily data

# 1.0.0 SETUP ----
library(tidyverse)
library(chromote)
library(rvest)
library(xml2)
library(DBI)
library(RPostgres)

# Bond-attribute helpers (chromote scrape + Icelandic->English map) live in the
# one-time pull script; the daily new-bond reconciliation below reuses them.
source(file.path("R", "get_bond_attributes.R"))

# 1.1.0 DATABASE ----
# Single shared Postgres connection for the whole daily run (not one per source).
# Connection params come from the standard libpq env vars
# (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD); RPostgres reads them itself.
db_connect <- function() {
  DBI::dbConnect(RPostgres::Postgres())
}

# Upsert a tibble on its key columns: insert new rows, update existing ones,
append the tail without rewriting history. Done via a staging temp table +
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

con <- db_connect()

# 2.0.0 ICELANDIC RATES AND BONDS ----

# 2.1.0 Policy rate components ----
# 7-day term deposit rate (headline), current account rate,
# overnight rate, collateralised lending rate

get_cbi_policy_rate <- function(from = "2009-01-01", to = Sys.Date()) {
  
  url <- paste0(
    "https://www.sedlabanki.is/xmltimeseries/Default.aspx?",
    "DagsFra=", from,
    "&DagsTil=", to,
    "&TimeSeriesID=17923",
    "&Type=xml"
  )
  
  x <- xml2::read_xml(url)
  entries <- xml2::xml_find_all(x, ".//Entry")
  
  tibble::tibble(
    date = lubridate::mdy_hms(
      xml2::xml_text(xml2::xml_find_first(entries, ".//Date"))
    ) |> as.Date(),
    policy_rate = as.numeric(
      xml2::xml_text(xml2::xml_find_first(entries, ".//Value"))
    )
  ) |> 
    dplyr::arrange(date)
}

policy_rate_tbl <- get_cbi_policy_rate()

db_upsert(con, "rates_policy", policy_rate_tbl, conflict_cols = "date")


# 2.2.0 All RIKB (nominal) and RIKS (indexed) government bond ----
# Closing yields/prices, every outstanding series.
#
# The landing page renders (after JS) two price tables — Óverðtryggt (RIKB,
# nominal) and Verðtryggt (RIKS, indexed) — each with columns Hreyfing/Kaup/
# Krafa. Hreyfing is a decorative up/down arrow with no data, so it is dropped;
# we keep the bond code, Kaup (bid price) and Krafa (yield). The detail-page
# links on the same page give the authoritative bond_code -> orderbookid map.
#
# (The CSS selector ".text-right , .text-center+ .text-center , .fixed-width"
# returns the same cells as a flat list; parsing the <table> elements is used
# instead because the tables carry their own column headers.)

get_lanamal_bonds <- function() {

  b <- bond_chromote_session()
  on.exit(b$close(), add = TRUE)
  b$Page$navigate("https://www.lanamal.is")
  Sys.sleep(8)  # JS-rendered: prices populate after load

  doc <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html()

  # Bond code -> orderbookid, straight from the detail links (no transform guess).
  id_map <- tibble::tibble(
    href = doc |> rvest::html_elements("a") |> rvest::html_attr("href")
  ) |>
    dplyr::filter(stringr::str_detect(href, "orderbookid=")) |>
    dplyr::transmute(
      orderbookid = stringr::str_extract(href, "(?<=orderbookid=)[a-z0-9_]+"),
      bond_code   = orderbookid |>
        stringr::str_to_upper() |>
        stringr::str_replace_all("_", " ")
    ) |>
    dplyr::distinct()

  # The two price tables are exactly those whose headers carry Kaup and Krafa.
  price_tbls <- doc |> rvest::html_elements("table") |>
    purrr::keep(\(t) {
      h <- tryCatch(names(rvest::html_table(t)), error = function(e) character())
      all(c("Kaup", "Krafa") %in% h)
    })

  price_tbls |>
    purrr::map(\(t) {
      tt <- rvest::html_table(t)
      tt |>
        rlang::set_names(c("bond_code", names(tt)[-1])) |>
        dplyr::transmute(
          bond_code = stringr::str_squish(bond_code),
          # Icelandic decimal comma -> numeric.
          kaup  = readr::parse_number(
            Kaup,  locale = readr::locale(decimal_mark = ",", grouping_mark = ".")),
          krafa = readr::parse_number(
            Krafa, locale = readr::locale(decimal_mark = ",", grouping_mark = "."))
        )
    }) |>
    purrr::list_rbind() |>
    dplyr::filter(stringr::str_detect(bond_code, "^(RIKB|RIKS) ")) |>
    dplyr::left_join(id_map, by = "bond_code") |>
    dplyr::mutate(date = Sys.Date()) |>
    dplyr::relocate(date, bond_code, orderbookid)
}

bonds_tbl <- get_lanamal_bonds()

db_upsert(con, "bonds_daily", bonds_tbl, conflict_cols = c("date", "bond_code"))


# 2.2.1 New-bond attribute reconciliation ----
# For any bond now listed but not yet in `bond_attributes`, pull its static
# attributes and append. Existing bonds are left untouched (attributes are
# fixed at issue), so the daily job only ever adds genuinely new series.

existing_orderbookids <- if (DBI::dbExistsTable(con, "bond_attributes")) {
  DBI::dbGetQuery(con, "SELECT DISTINCT orderbookid FROM bond_attributes")$orderbookid
} else {
  character()
}

new_orderbookids <- bonds_tbl |>
  dplyr::distinct(orderbookid) |>
  dplyr::filter(!is.na(orderbookid), !orderbookid %in% existing_orderbookids) |>
  dplyr::pull(orderbookid)

if (length(new_orderbookids) > 0) {
  b_attr <- bond_chromote_session()
  new_bond_attributes_tbl <- new_orderbookids |>
    purrr::map(\(id) get_one_bond_attributes(id, b_attr)) |>
    purrr::list_rbind()
  b_attr$close()

  db_upsert(con, "bond_attributes", new_bond_attributes_tbl,
            conflict_cols = c("orderbookid", "attribute"))
}



# 2.3.0 Treasury bill (ríkisvíxlar) rates, all maturities ----


# 2.4.0 REIBOR fixings, O/N and 1, 3, 6 months ----
# CBI xmltimeseries feed, one TimeSeriesID per tenor. The IDs are NOT
# consecutive and do not match tenor order: IDs 18/19 return no data, and
# the bid-side REIBID series sit at 3-8, so the REIBOR ask-side fixings we
# want are 12 (O/N), 13 (1M), 15 (3M), 16 (6M). Verified against the feed's
# <TimeSeries><Name> captions.
reibor_series <- c(
  "O/N" = 12,
  "1M"  = 13,
  "3M"  = 15,
  "6M"  = 16
)

get_cbi_reibor <- function(series = reibor_series,
                           from = "2000-01-01", to = Sys.Date()) {

  purrr::imap(series, \(id, tenor) {
    url <- paste0(
      "https://www.sedlabanki.is/xmltimeseries/Default.aspx?",
      "DagsFra=", from,
      "&DagsTil=", to,
      "&TimeSeriesID=", id,
      "&Type=xml"
    )

    x <- xml2::read_xml(url)
    entries <- xml2::xml_find_all(x, ".//Entry")

    tibble::tibble(
      date = lubridate::mdy_hms(
        xml2::xml_text(xml2::xml_find_first(entries, ".//Date"))
      ) |> as.Date(),
      tenor  = tenor,
      reibor = as.numeric(
        xml2::xml_text(xml2::xml_find_first(entries, ".//Value"))
      )
    )
  }) |>
    purrr::list_rbind() |>
    dplyr::arrange(date, tenor)
}

reibor_tbl <- get_cbi_reibor()

db_upsert(con, "rates_reibor", reibor_tbl, conflict_cols = c("date", "tenor"))



# 9.0.0 TEARDOWN ----
# Close the shared connection last, after every source above has written.
DBI::dbDisconnect(con)