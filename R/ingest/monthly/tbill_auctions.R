# Monthly poll of event data — Treasury-bill (ríkisvíxlar) auction results ----
# There is NO daily secondary-market quote for Treasury bills anywhere: the
# lanamal.is landing page and market-overview render only RIKB/RIKS, and the CBI
# SDMX host is not reachable externally. T-bill rates exist ONLY as auction
# results, published per auction (~monthly) as a news article on lanamal.is.
# This scrapes the RIKV auction-result articles for the accepted yield — the
# short-end risk-free rate read (SPEC A1) and a money-market complement to
# REIBOR / the policy rate.
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 + jsonlite + xml2
# attached; rvest is called namespace-qualified, as in card_turnover.R). Auctions
# are event-driven, but the listing only exposes the latest handful and there is
# no usable pagination param, so this POLLS the listing each monthly run and
# upserts — history ACCRETES forward (same model as the SDDS sources). A deep
# backfill would need the listing's load-more API, which is not exposed as a
# plain GET. Target table: tbill_auctions (date, series, yield, bid_to_cover,
# accepted_mkr), upsert on (date, series). `date` is the settlement / payment
# date (Greiðslu-og uppgjörsdagur) — the only date carried in the results table
# (the auction day is ~3 days earlier and not published there).
#
# ACCESS MODE (b) — scrape. Each results article is server-rendered HTML (no JS
# needed). It also embeds the announcement of the NEXT auction, which carries
# OTHER RIKV/RIKS codes and dates; to avoid conflating them we parse ONLY the
# results table — the one carrying the bid-to-cover (Boðhlutfall) and weighted-
# average-accepted (Vegið meðaltal samþykktra) rows. Numbers are Icelandic-format
# (decimal comma, "." thousands). The "verð / flatir vextir" rows give price and
# the simple/flat yield per series; we keep the weighted-average accepted yield.

LANAMAL_BASE <- "https://www.lanamal.is"
TBILL_RESULTS_LISTING <- "/frettir/nidurstodur-utboda/rikisvixlar"

# Parse one auction-result article into a (date, series, yield, ...) tibble, or
# NULL if it carries no parseable results table (e.g. a postponed auction).
parse_tbill_auction <- function(article_path) {
  isk_num <- function(x) readr::parse_number(
    x, locale = readr::locale(decimal_mark = ",", grouping_mark = "."))
  txts <- httr2::request(paste0(LANAMAL_BASE, article_path)) |>
    httr2::req_timeout(40) |>
    httr2::req_perform() |>
    httr2::resp_body_string() |>
    rvest::read_html() |>
    rvest::html_elements("table") |>
    rvest::html_text2() |>
    stringr::str_squish()
  # The results table is the one with the bid-to-cover and weighted-avg rows.
  i <- which(stringr::str_detect(txts, "Boðhlutfall") &
             stringr::str_detect(txts, "Vegið meðaltal samþykktra"))[1]
  if (is.na(i)) return(NULL)
  txt <- txts[i]

  series <- unique(stringr::str_extract_all(txt, "RIKV \\d{2} \\d{4}")[[1]])
  n <- length(series)
  if (n == 0) return(NULL)

  # Text following a label, to end of the (single) results-table string.
  seg <- function(label) {
    p <- stringr::str_locate(txt, stringr::fixed(label))
    if (is.na(p[1, 1])) "" else stringr::str_sub(txt, p[1, 2] + 1)
  }
  settle <- head(stringr::str_extract_all(
    seg("Greiðslu-og uppgjörsdagur"), "\\d{2}\\.\\d{2}\\.\\d{4}")[[1]], n)
  amount <- head(stringr::str_extract_all(
    seg("Samþykkt tilboð að nafnverði (m.kr.)"), "[0-9][0-9.]*")[[1]], n)
  bidcov <- head(stringr::str_extract_all(
    seg("Boðhlutfall"), "[0-9]+,[0-9]+")[[1]], n)
  # Each series contributes a "price / yield" pair; the first n pairs after the
  # label are the weighted-average-accepted row (group 2 = the flat yield).
  pairs <- stringr::str_match_all(
    seg("Vegið meðaltal samþykktra tilboða (verð / flatir vextir)"),
    "([0-9][0-9.]*,[0-9]+) / ([0-9][0-9.]*,[0-9]+)")[[1]]

  tibble::tibble(
    date         = as.Date(settle, "%d.%m.%Y"),
    series       = series,
    yield        = isk_num(pairs[seq_len(n), 3]),
    bid_to_cover = isk_num(bidcov),
    accepted_mkr = isk_num(amount)
  )
}

get_tbill_auctions <- function() {
  hrefs <- httr2::request(paste0(LANAMAL_BASE, TBILL_RESULTS_LISTING)) |>
    httr2::req_timeout(40) |>
    httr2::req_perform() |>
    httr2::resp_body_string() |>
    rvest::read_html() |>
    rvest::html_elements("a") |>
    rvest::html_attr("href")
  article_paths <- unique(hrefs[!is.na(hrefs) &
    stringr::str_detect(hrefs, "/rikisvixlar/nanar/\\d+")])

  purrr::map(article_paths, parse_tbill_auction) |>
    purrr::list_rbind() |>
    dplyr::filter(!is.na(date), !is.na(yield)) |>
    dplyr::distinct() |>
    dplyr::arrange(date, series)
}

tbill_auctions_tbl <- get_tbill_auctions()

db_ensure_table(con, "tbill_auctions",
                cols = c(date = "DATE", series = "TEXT", yield = "DOUBLE PRECISION",
                         bid_to_cover = "DOUBLE PRECISION", accepted_mkr = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "tbill_auctions", tbill_auctions_tbl,
          conflict_cols = c("date", "series"))
