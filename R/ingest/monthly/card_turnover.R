# Monthly — card turnover / payment intermediation (Seðlabankinn) ----
# Household card turnover and foreign-tourist card consumption from the CBI
# "Greiðslumiðlun" (payment intermediation) Excel workbook. A consumption /
# domestic-demand heat-index input (SPEC A1). Monthly from 1998.
#
# Sourced by run_monthly.R, which provides `con`, has attached tidyverse +
# httr2, and sourced the DB helpers. Target table:
#   card_turnover (date, series, value), upsert on (date, series).
#
# ACCESS MODE (c) — Excel-only. There is no xmltimeseries feed for these series;
# the only published source is one .xlsx linked from the data-portal page
#   https://sedlabanki.is/gagnatorg/greidslumidlun/
# whose download URL carries a library itemid that CHANGES every month, so the
# URL cannot be hard-coded. The page is client-rendered, so the anchor is found
# by rendering it headless (chromote) and selecting the single itemid link whose
# caption starts with "Grei…" (the Greiðslumiðlun workbook), then downloading it.
#
# WORKBOOK SHAPE: data lives on sheet "Sheet1" (sheet 1, "FAME Persistence2", is
# metadata). Row 6 is the date header as Excel serials; data columns run from
# column F to an ever-growing last month, so the dated columns are discovered as
# the non-NA cells of row 6 (from F on) rather than assuming a fixed width.
# Fixed source rows (1-based): 9 = total household card turnover; 12/37 =
# domestic debit/credit; 17/42 = foreign debit/credit; 63 = foreign tourists'
# card consumption in Iceland. Domestic = 12+37, foreign = 17+42.

# Locate and download the Greiðslumiðlun workbook to a temp file, returning the
# path. The itemid changes monthly, so the anchor is resolved live each run.
cbi_greidslumidlun_xlsx <- function() {
  b <- chromote::ChromoteSession$new(wait_ = TRUE)
  on.exit(b$close(), add = TRUE)
  b$Page$navigate("https://sedlabanki.is/gagnatorg/greidslumidlun/")
  b$Page$loadEventFired(wait_ = TRUE)
  Sys.sleep(3)  # JS-rendered: the download anchor populates after load
  doc <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html()

  a    <- doc |> rvest::html_elements("a")
  href <- a |> rvest::html_attr("href")
  txt  <- a |> rvest::html_text2()
  # The one library-itemid anchor captioned with the Greiðslumiðlun workbook.
  keep <- !is.na(href) & grepl("itemid=", href, fixed = TRUE) & grepl("Grei", txt)
  if (sum(keep) != 1) {
    stop("Expected exactly one Greiðslumiðlun download link, found ", sum(keep))
  }

  tmp <- tempfile(fileext = ".xlsx")
  httr2::request(paste0("https://sedlabanki.is", href[keep])) |>
    httr2::req_perform(path = tmp)
  tmp
}

get_cbi_card_turnover <- function() {
  xlsx <- cbi_greidslumidlun_xlsx()
  raw  <- readxl::read_excel(xlsx, sheet = "Sheet1",
                             col_names = FALSE, .name_repair = "minimal")

  # Date header is row 6, Excel serials; keep the dated columns from F (6) on.
  serials   <- as.numeric(unlist(raw[6, ]))
  date_cols <- which(!is.na(serials))
  date_cols <- date_cols[date_cols >= 6]
  dates     <- as.Date(serials[date_cols], origin = "1899-12-30")

  pull_row <- function(r, label) {
    tibble::tibble(date = dates, series = label,
                   value = as.numeric(unlist(raw[r, date_cols])))
  }

  raw_long <- dplyr::bind_rows(
    pull_row(9,  "CARD_TURNOVER_HH"),            # total household card turnover
    pull_row(12, "_dom_debit"),
    pull_row(37, "_dom_credit"),
    pull_row(17, "_for_debit"),
    pull_row(42, "_for_credit"),
    pull_row(63, "TOURIST_CONSUMPTION")          # foreign tourists' card use here
  )

  # Combine debit + credit into domestic / foreign household card turnover.
  combined <- raw_long |>
    dplyr::filter(series %in% c("_dom_debit", "_dom_credit",
                                "_for_debit", "_for_credit")) |>
    dplyr::mutate(series = dplyr::if_else(
      series %in% c("_dom_debit", "_dom_credit"),
      "CARD_TURNOVER_HH_DOMESTIC", "CARD_TURNOVER_HH_FOREIGN")) |>
    dplyr::group_by(date, series) |>
    dplyr::summarise(value = sum(value, na.rm = TRUE), .groups = "drop")

  raw_long |>
    dplyr::filter(series %in% c("CARD_TURNOVER_HH", "TOURIST_CONSUMPTION")) |>
    dplyr::bind_rows(combined) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date, series)
}

card_turnover_tbl <- get_cbi_card_turnover()

db_ensure_table(con, "card_turnover",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "card_turnover", card_turnover_tbl, conflict_cols = c("date", "series"))
