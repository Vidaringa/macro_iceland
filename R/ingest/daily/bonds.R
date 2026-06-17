# Daily — RIKB/RIKS government bonds + new-bond attribute reconciliation ----
# Closing bid (Kaup) and yield (Krafa) for every outstanding RIKB (nominal) and
# RIKS (indexed) series, scraped from the JS-rendered lanamal.is landing page.
# Then: for any bond now listed but not yet in `bond_attributes`, pull its static
# attributes and append (existing bonds untouched — attributes are fixed at issue).
#
# Sourced by run_daily.R, which provides `con` and has already attached
# tidyverse + chromote + rvest, sourced the DB helpers, AND sourced
# get_bond_attributes.R (for bond_chromote_session / get_one_bond_attributes,
# reused by the reconciliation below). Target tables: bonds_daily
# (date, bond_code, orderbookid, kaup, krafa) upsert on (date, bond_code);
# bond_attributes upsert on (orderbookid, attribute).

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


# New-bond attribute reconciliation ----
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
