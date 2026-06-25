# Quarterly — output gap (Seðlabankinn QMM forecast database) ----
# The output gap is not on any CBI data feed; it is a Quarterly Macroeconomic
# Model (QMM) estimate published with the Bank's macro forecast (efnahagsspá).
# The forecast page links a single QMM database workbook whose "Gagnagrunnur"
# sheet holds one column per model variable; the variable `GAP` is the output gap
# (as a FRACTION of potential output — stored here ×100 as percent). A cycle /
# slack read (SPEC A1). Quarterly; the GAP column currently runs to ~2025Q4 and
# is revised each forecast vintage (upsert keeps the latest).
#
# Sourced by run_quarterly.R (provides `con`; tidyverse + httr2 + jsonlite + xml2
# attached; chromote + rvest are called namespace-qualified, as in card_turnover.R).
# Target table: output_gap (date, series, value), upsert on (date, series).
#
# ACCESS MODE (c) — Excel-only. The download link carries a library itemid that
# changes each forecast vintage, and the page is JS-rendered, so the link is
# resolved live: render the page and take the single anchor whose href is
# type=xlsx (the QMM Gagnagrunnur workbook). In the sheet, row 1 is the variable
# header (find the `GAP` column by name — it drifts between vintages), column A is
# the quarter code "YYYYQq" (with three metadata rows — Comment/Org./Type — above
# the dates, skipped by keeping only cells that match the quarter pattern).

OUTPUT_GAP_PAGE <- "https://sedlabanki.is/peningastefna/efnahagsspa/"

# Resolve + download the single QMM database .xlsx linked from the forecast page.
cbi_qmm_xlsx <- function() {
  b <- chromote::ChromoteSession$new(wait_ = TRUE)
  on.exit(b$close(), add = TRUE)
  b$Page$navigate(OUTPUT_GAP_PAGE)
  b$Page$loadEventFired(wait_ = TRUE)
  Sys.sleep(4)  # JS-rendered: the library anchors populate after load
  href <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html() |>
    rvest::html_elements("a") |>
    rvest::html_attr("href")
  xlsx <- unique(href[!is.na(href) & grepl("type=xlsx", href, fixed = TRUE)])
  if (length(xlsx) != 1) {
    stop("Expected exactly one .xlsx link on the forecast page, found ", length(xlsx))
  }
  tmp <- tempfile(fileext = ".xlsx")
  httr2::request(paste0("https://sedlabanki.is", xlsx)) |>
    httr2::req_perform(path = tmp)
  tmp
}

get_cbi_output_gap <- function() {
  xlsx  <- cbi_qmm_xlsx()
  sheet <- grep("Gagnagrunnur", readxl::excel_sheets(xlsx), value = TRUE)[1]
  raw   <- readxl::read_excel(xlsx, sheet = sheet,
                              col_names = FALSE, .name_repair = "minimal")

  gap_col <- which(as.character(unlist(raw[1, ])) == "GAP")
  if (length(gap_col) != 1) {
    stop("Expected exactly one 'GAP' column in row 1, found ", length(gap_col))
  }
  date_chr <- as.character(raw[[1]])
  keep     <- grepl("^[0-9]{4}Q[1-4]$", date_chr)  # drops Comment/Org./Type rows

  tibble::tibble(
    date   = lubridate::make_date(
      as.integer(stringr::str_sub(date_chr[keep], 1, 4)),
      (as.integer(stringr::str_sub(date_chr[keep], 6, 6)) - 1L) * 3L + 1L, 1L),
    series = "OUTPUT_GAP",
    value  = as.numeric(unlist(raw[keep, gap_col])) * 100  # QMM fraction -> % of potential
  ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date)
}

output_gap_tbl <- get_cbi_output_gap()

db_ensure_table(con, "output_gap",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "output_gap", output_gap_tbl, conflict_cols = c("date", "series"))
