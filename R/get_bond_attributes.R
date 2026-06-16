# One-time data pull: government bond attributes (Lánamál)
#
# Pulls the static "Skilmáli / Gildi" attribute table from each bond's detail
# page on lanamal.is and returns one long tibble: one row per (bond, attribute).
# Icelandic labels are mapped to canonical English keys where known; any label
# without a mapping is kept verbatim (English-mapped + raw kept). RIKB and RIKS
# pages use different/inconsistent labels for the same concept, which is exactly
# why a long, lookup-mapped shape is used rather than a rigid wide schema.
#
# Run once to backfill `bond_attributes`. get_daily_data.R reuses the helpers
# below to fetch attributes for any newly-listed bond and append them.

# 1.0.0 SETUP ----
library(tidyverse)
library(chromote)
library(rvest)
library(DBI)
library(RPostgres)

# 2.0.0 ICELANDIC LABEL -> ENGLISH KEY MAP ----
# Both RIKB (nominal) and RIKS (indexed) labels mapped onto a shared English
# vocabulary. Concepts that differ in wording across the two series collapse to
# the same key (e.g. coupon: "Nafnvextir" / "Vextir"). Labels absent here are
# kept verbatim downstream, so a new/renamed field is preserved, never dropped.
bond_attr_label_map <- c(
  "Nafn"                                     = "name",
  "ISIN númer"                          = "isin",
  "Skráð í OMX Norrænu kauphöllinni Íslandi" = "listing_date",
  "Skráð í Kauphöll Íslands" = "listing_date",
  "Útgáfudagur"                     = "issue_date",
  "Innlausnardagur"                          = "maturity_date",
  "Tegund bréfs"                         = "bond_type",
  "Nafnvextir"                               = "coupon_rate",
  "Vextir"                                   = "coupon_rate",
  "Fyrsti gjalddagi vaxta"                   = "first_coupon_date",
  "Fyrsti gjalddagi afborgana"               = "first_principal_date",
  "Fyrsti vaxtadagur"                        = "interest_start_date",
  "Gjaldmiðill"                         = "currency",
  "Nafnverðseiningar"                   = "nominal_unit",
  "Fjárhæð að nafnvirði" = "nominal_unit",
  "Innkallanleg"                             = "callable",
  "Innleysanlegt"                            = "redeemable",
  "Breytanlegt"                              = "convertible",
  "Subordinated"                             = "subordinated",
  "Viðskiptavakt"                       = "market_making",
  "Útgefið nafnverð"           = "issued_nominal",
  "Innlausnarverð"                      = "redemption_value",
  "Verðtrygging"                        = "indexed",
  "Vísitala"                            = "index_name",
  "Grunnvísitala við útgáfu" = "base_index",
  "Markaður"                            = "market",
  "Útreikningsregla"                    = "day_count",
  "OMX dagaregla"                            = "day_count",
  "Fjöldi aukastafa"                    = "decimals"
)

# 3.0.0 HELPERS ----

# Robust connect to a headless Chrome session. Caller is responsible for $close().
# Wider command timeout: lanamal.is can be slow to acknowledge navigation.
bond_chromote_session <- function() {
  chromote::ChromoteSession$new(wait_ = TRUE) |>
    (\(s) { s$default_timeout <- 30; s })()
}

# Pull the attribute key-value table for a single bond into a long tibble.
# `orderbookid` is the lowercased, underscore-joined code, e.g. "rikb_31_0124".
# `b` is a live ChromoteSession (shared across bonds to avoid relaunching Chrome).
get_one_bond_attributes <- function(orderbookid, b) {

  url <- paste0(
    "https://lanamal.is/markadsyfirlit/?type=bond&orderbookid=",
    orderbookid
  )
  # Navigation can transiently time out; one retry before giving up on this bond.
  ok <- tryCatch({ b$Page$navigate(url); TRUE },
                 error = function(e) { Sys.sleep(3); FALSE })
  if (!ok) {
    ok <- tryCatch({ b$Page$navigate(url); TRUE },
                   error = function(e) FALSE)
  }
  if (!ok) {
    warning("Navigation failed for ", orderbookid, " — skipped")
    return(tibble::tibble())
  }
  Sys.sleep(7)  # JS-rendered: data populates after load

  doc <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html()

  # The attribute table is the one 2-column table whose first column carries the
  # Icelandic terms (it contains an "ISIN" row). Identify it structurally rather
  # than by position, since the page also renders several price tables.
  tbls <- doc |> rvest::html_elements("table")
  attr_tbl <- NULL
  for (t in tbls) {
    tt <- tryCatch(rvest::html_table(t), error = function(e) NULL)
    if (!is.null(tt) && ncol(tt) == 2 && any(grepl("ISIN", tt[[1]]))) {
      attr_tbl <- tt
      break
    }
  }
  if (is.null(attr_tbl)) {
    warning("No attribute table found for ", orderbookid)
    return(tibble::tibble())
  }

  raw <- attr_tbl |>
    rlang::set_names(c("label_is", "value_raw")) |>
    dplyr::mutate(dplyr::across(dplyr::everything(), stringr::str_squish)) |>
    dplyr::filter(label_is != "")

  # Identifier attributes are pure strings: never coerce them to num/date
  # (e.g. "RIKB 31 0124" looks date-like, ISIN "IS0000020386" looks numeric).
  id_attrs <- c("name", "isin")

  raw |>
    dplyr::transmute(
      orderbookid = orderbookid,
      attribute   = dplyr::coalesce(
        unname(bond_attr_label_map[label_is]), label_is
      ),
      label_is    = label_is,
      value_raw   = value_raw
    ) |>
    dplyr::mutate(
      # Disambiguate "Útreikningsregla": on RIKB it is the day-count convention
      # ("Actual - actual ..."), but on RIKS the same label carries the bond
      # structure ("Bullet Bond") while day-count lives under "OMX dagaregla".
      # Route by value so the two never collide on the day_count key.
      attribute = dplyr::if_else(
        label_is == "Útreikningsregla" &
          !stringr::str_detect(value_raw, stringr::regex("actual|aðferð",
                                                         ignore_case = TRUE)),
        "bond_type", attribute
      )
    ) |>
    dplyr::mutate(
      # Dates are dd.mm.yyyy.
      value_date = dplyr::if_else(
        attribute %in% id_attrs, lubridate::NA_Date_,
        suppressWarnings(lubridate::dmy(value_raw))
      ),
      # Icelandic numeric: "." thousands sep, "," decimal, optional "%".
      # Skip identifiers and anything that already parsed as a date.
      value_num = dplyr::if_else(
        attribute %in% id_attrs | !is.na(value_date), NA_real_,
        value_raw |>
          stringr::str_remove_all("%") |>
          stringr::str_remove_all("\\.") |>
          stringr::str_replace(",", ".") |>
          stringr::str_squish() |>
          readr::parse_number(locale = readr::locale(decimal_mark = ".")) |>
          suppressWarnings()
      )
    )
}

# 4.0.0 RUN: pull attributes for every currently-listed bond ----

# Authoritative bond list + orderbookids come straight from the landing page's
# detail links, so we never have to guess the code -> orderbookid transform.
get_listed_orderbookids <- function() {
  b <- bond_chromote_session()
  on.exit(b$close(), add = TRUE)
  b$Page$navigate("https://www.lanamal.is")
  Sys.sleep(8)
  doc <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html()
  doc |>
    rvest::html_elements("a") |>
    rvest::html_attr("href") |>
    stringr::str_subset("orderbookid=") |>
    stringr::str_extract("(?<=orderbookid=)[a-z0-9_]+") |>
    unique()
}

# Guard the run so `source()`-ing this file from get_daily_data.R loads only the
# helpers above (and not this full backfill). `sys.nframe() == 0L` is true only
# when the script is executed directly (Rscript / console), false when sourced.
if (sys.nframe() == 0L) {

  orderbookids <- get_listed_orderbookids()

  b <- bond_chromote_session()
  bond_attributes_tbl <- purrr::map(
    orderbookids,
    \(id) get_one_bond_attributes(id, b)
  ) |>
    purrr::list_rbind()
  b$close()

  # Upsert into Postgres `bond_attributes`, keyed on (orderbookid, attribute):
  # staging temp table + INSERT ... ON CONFLICT so re-running this backfill is
  # idempotent. Connection params come from the PG* env vars (.Renviron).
  con <- DBI::dbConnect(RPostgres::Postgres())
  DBI::dbWriteTable(con, "_stage_bond_attributes",
                    as.data.frame(bond_attributes_tbl),
                    temporary = TRUE, overwrite = TRUE)
  DBI::dbExecute(con, "
    INSERT INTO bond_attributes
      (orderbookid, attribute, label_is, value_raw, value_date, value_num)
    SELECT orderbookid, attribute, label_is, value_raw, value_date, value_num
    FROM _stage_bond_attributes
    ON CONFLICT (orderbookid, attribute) DO UPDATE SET
      label_is   = EXCLUDED.label_is,
      value_raw  = EXCLUDED.value_raw,
      value_date = EXCLUDED.value_date,
      value_num  = EXCLUDED.value_num
  ")
  DBI::dbDisconnect(con)

}
