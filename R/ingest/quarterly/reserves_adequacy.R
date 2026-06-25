# Quarterly — FX-reserve adequacy ratios (Seðlabankinn Financial Stability) ----
# The reserve-adequacy components are not on any data feed; they are published in
# the Fjármálastöðugleiki (Financial Stability) report, chart "Gjaldeyrisforði
# Seðlabanka Íslands", as the foreign reserve measured against international
# adequacy benchmarks: as a % of the IMF composite metric (Samsett forðaviðmið
# AGS / RAM) and as a % of short-term external debt (erlendar skammtímaskuldir).
# These two ratios are a reserve-cushion / external-vulnerability read (SPEC A1).
# The reserve LEVEL itself is deliberately NOT stored here — it is already pulled
# into `reserves`. Quarterly; the FS report carries a ~6-year rolling window.
#
# Sourced by run_quarterly.R (provides `con`; tidyverse + httr2 + jsonlite + xml2
# attached; chromote + rvest are called namespace-qualified, as in card_turnover.R).
# Target table: reserves_adequacy (date, series, value), upsert on (date, series).
#
# ACCESS MODE (c) — Excel-only, resolved live across three hops because nothing
# here is stable: (1) the publications page lists the LATEST FS report (its URL
# carries the YYYY-N issue); (2) that report page links the chapter chart-data
# workbook ("…gögn úr köflum", a rotating library itemid); (3) inside it the chart
# is located by CONTENT — the sheet whose header carries "Samsett forðaviðmið" —
# because the chart NUMBER drifts between issues. Columns are then found by header
# name, and the quarter is col A as "qF YYYY" (1F = Q1). Values are already in %.

FS_PUBLICATIONS <- "https://sedlabanki.is/frettir-og-utgefid-efni/rit-og-skyrslur/"

# Resolve + download the latest FS report's chapter chart-data workbook.
cbi_fs_chapter_data_xlsx <- function() {
  b <- chromote::ChromoteSession$new(wait_ = TRUE)
  on.exit(b$close(), add = TRUE)
  b$default_timeout <- 60

  # (1) Latest FS report link from the publications page (pick max YYYY-N).
  b$Page$navigate(FS_PUBLICATIONS)
  b$Page$loadEventFired(wait_ = TRUE)
  Sys.sleep(5)
  href <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html() |> rvest::html_elements("a") |> rvest::html_attr("href")
  fs <- unique(href[!is.na(href) &
    grepl("grein/fjarmalastodugleiki-[0-9]{4}-[0-9]", href)])
  if (length(fs) == 0) stop("No Financial Stability report link on publications page")
  issue  <- as.integer(gsub("\\D", "", stringr::str_extract(fs, "[0-9]{4}-[0-9]")))
  report <- fs[which.max(issue)]

  # (2) Chapter chart-data workbook on that report page ("gögn úr köflum").
  b$Page$navigate(paste0("https://sedlabanki.is", report))
  b$Page$loadEventFired(wait_ = TRUE)
  Sys.sleep(5)
  a    <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html() |> rvest::html_elements("a")
  ah   <- a |> rvest::html_attr("href")
  atx  <- a |> rvest::html_text2() |> stringr::str_squish()
  pick <- which(!is.na(ah) & grepl("itemid=", ah) &
                grepl("gögn úr köflum", atx, fixed = TRUE))[1]
  if (is.na(pick)) stop("No 'gögn úr köflum' chapter-data file on FS report page")

  tmp <- tempfile(fileext = ".xlsx")
  httr2::request(paste0("https://sedlabanki.is", ah[pick])) |>
    httr2::req_timeout(120) |> httr2::req_perform(path = tmp)
  tmp
}

get_cbi_reserves_adequacy <- function() {
  xlsx <- cbi_fs_chapter_data_xlsx()

  # Find the chart sheet by CONTENT (the composite-metric series label).
  raw <- NULL
  for (s in readxl::excel_sheets(xlsx)) {
    d <- readxl::read_excel(xlsx, sheet = s, col_names = FALSE, .name_repair = "minimal")
    if (any(grepl("Samsett forðavið", as.matrix(d), fixed = TRUE))) { raw <- d; break }
  }
  if (is.null(raw)) stop("No 'Samsett forðaviðmið' chart in FS chapter data")

  m       <- as.matrix(raw)
  hdr_row <- which(apply(m, 1, function(r) any(grepl("Samsett forðavið", r, fixed = TRUE))))[1]
  hdr     <- as.character(m[hdr_row, ])
  col_comp <- which(grepl("Samsett forðavið", hdr, fixed = TRUE))[1]   # % of IMF composite metric
  col_std  <- which(grepl("skammtíma", hdr, fixed = TRUE))[1]          # % of short-term ext. debt

  qm   <- stringr::str_match(as.character(raw[[1]]), "^([1-4])F\\s*([0-9]{4})$")
  keep <- !is.na(qm[, 1])

  tibble::tibble(
    date = lubridate::make_date(
      as.integer(qm[keep, 3]), (as.integer(qm[keep, 2]) - 1L) * 3L + 1L, 1L),
    RESERVE_ADEQ_COMPOSITE       = suppressWarnings(as.numeric(raw[[col_comp]]))[keep],
    RESERVE_ADEQ_SHORT_TERM_DEBT = suppressWarnings(as.numeric(raw[[col_std]]))[keep]
  ) |>
    tidyr::pivot_longer(-date, names_to = "series", values_to = "value") |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(series, date)
}

reserves_adequacy_tbl <- get_cbi_reserves_adequacy()

db_ensure_table(con, "reserves_adequacy",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "reserves_adequacy", reserves_adequacy_tbl,
          conflict_cols = c("date", "series"))
