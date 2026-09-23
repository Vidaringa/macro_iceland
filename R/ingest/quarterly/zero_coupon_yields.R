# Quarterly — daily zero-coupon government yields (Seðlabankinn Hagvísar) ----
# The CBI's own fitted zero-coupon curve: nominal (óverðtryggð) and indexed
# (verðtryggð) yields at the 5y and 10y points, DAILY back to 2001. Feeds A3 —
# it is the only long curve history available, and the fitted A3 curve from
# bonds_daily only starts 2026-06.
#
# Sourced by run_quarterly.R, which provides `con`, has attached tidyverse +
# httr2 + chromote + rvest, and sourced the DB helpers. Target table:
#   zero_coupon_yields (date, series, value), upsert on (date, series).
#
# WHY QUARTERLY CADENCE FOR A DAILY SERIES. Hagvísar is published quarterly and
# each issue restates the WHOLE history, so one pull per quarter backfills every
# day since 2001. The series is daily but the SOURCE updates quarterly; running
# this daily would re-download 50MB to learn nothing. The ~3-month ragged edge
# this leaves is a property of the publication, not a pipeline failure.
#
# ACCESS MODE (c) — Excel-only, resolved live. The chapter workbooks hang off a
# per-issue article page whose slug carries an Icelandic-month date
# (".../grein/hagvisar-sedlabanka-islands-26-juni-2026"), and the download URL is
# a /library/?itemid= GUID that changes every issue. So: render the tag archive
# headless, pick the newest issue by parsing the slug date, then find the
# "Kafli VIII" anchor on that page. NOTE the chapter is labelled like a PDF on
# the page but is served as .xlsx (~50MB) — do not assume the caption's file type.
#
# WORKBOOK SHAPE (sheet "VIII-13", mynd VIII-13 "Ávöxtunarkrafa ríkistryggðra
# skuldabréfa"): rows 1-11 are metadata (Fs./Ufs./Nm./H./Vá./Há./Ath. captions in
# column 1), row 12 holds the four series names, data runs from row 13. Column 1
# is an Excel date serial (origin 1899-12-30), columns 2-5 are:
#   Óverðtryggð 5 ára | Óverðtryggð 10 ára | Verðtryggð 5 ára | Verðtryggð 10 ára
# The sheet is located by CONTENT (the mynd code in the metadata block) rather
# than by position, because sheet order shifts between issues.

HAGVISAR_TAG <- paste0(
  "https://sedlabanki.is/frettir-og-utgefid-efni/safnsida/?tag=hagv%C3%ADsar")

# Icelandic month names as they appear in the article slug, in calendar order.
IS_MONTHS <- c("januar", "februar", "mars", "april", "mai", "juni",
               "juli", "agust", "september", "oktober", "november", "desember")

ZCY_SERIES <- c("ZCY_NOMINAL_5Y", "ZCY_NOMINAL_10Y",
                "ZCY_INDEXED_5Y", "ZCY_INDEXED_10Y")

# Resolve the newest Hagvísar issue and download its Kafli VIII workbook.
cbi_hagvisar_kafli8_xlsx <- function() {
  b <- chromote::ChromoteSession$new(wait_ = TRUE)
  on.exit(b$close(), add = TRUE)
  b$default_timeout <- 60

  # (1) Newest issue from the tag archive. The archive lists newest-first, but
  # that order is not guaranteed, so the issue date is parsed from the slug
  # rather than trusted from position. Slug: ...-<day>-<icelandic month>-<year>.
  b$Page$navigate(HAGVISAR_TAG)
  b$Page$loadEventFired(wait_ = TRUE)
  Sys.sleep(6)  # JS-rendered archive
  href <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html() |> rvest::html_elements("a") |> rvest::html_attr("href")
  hv <- unique(href[!is.na(href) &
    grepl("grein/hagvisar-sedlabanka-islands-", href, ignore.case = TRUE)])
  if (length(hv) == 0) stop("No Hagvisar issue link on the tag archive")

  slug <- tolower(sub(".*hagvisar-sedlabanka-islands-", "", hv))
  # Strip Icelandic accents so the month matches IS_MONTHS (juní -> juni).
  slug <- chartr("áéíóúýþæöð", "aeiouythaod", slug)
  parts <- stringr::str_match(slug, "^([0-9]{1,2})-([a-z]+)-([0-9]{4})$")
  ok <- !is.na(parts[, 1]) & parts[, 3] %in% IS_MONTHS
  if (!any(ok)) stop("Could not parse any Hagvisar issue date from slugs")
  issue_date <- as.Date(sprintf("%s-%02d-%02d", parts[ok, 4],
                                match(parts[ok, 3], IS_MONTHS),
                                as.integer(parts[ok, 2])))
  report <- hv[ok][which.max(issue_date)]

  # (2) The Kafli VIII anchor on that issue's page. Captioned as a chapter, but
  # served as .xlsx — the caption's stated type is not to be trusted.
  b$Page$navigate(paste0("https://sedlabanki.is", report))
  b$Page$loadEventFired(wait_ = TRUE)
  Sys.sleep(5)
  a   <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html() |> rvest::html_elements("a")
  ah  <- a |> rvest::html_attr("href")
  atx <- a |> rvest::html_text2() |> stringr::str_squish()
  pick <- which(!is.na(ah) & grepl("itemid=", ah, fixed = TRUE) &
                  grepl("Kafli VIII", atx, ignore.case = TRUE))[1]
  if (is.na(pick)) stop("No 'Kafli VIII' chapter file on Hagvisar issue page")

  tmp <- tempfile(fileext = ".xlsx")
  httr2::request(paste0("https://sedlabanki.is", ah[pick])) |>
    httr2::req_timeout(300) |> httr2::req_perform(path = tmp)
  tmp
}

get_cbi_zero_coupon_yields <- function() {
  xlsx <- cbi_hagvisar_kafli8_xlsx()

  # Find the VIII-13 sheet by CONTENT: sheet order shifts between issues, so the
  # mynd code is matched inside the metadata block rather than assuming a name.
  raw <- NULL
  for (s in readxl::excel_sheets(xlsx)) {
    d <- readxl::read_excel(xlsx, sheet = s, col_names = FALSE,
                            .name_repair = "minimal")
    if (any(grepl("Mynd VIII-13", as.matrix(d), fixed = TRUE))) { raw <- d; break }
  }
  if (is.null(raw)) stop("Sheet 'Mynd VIII-13' not found in Kafli VIII workbook")

  raw <- as.data.frame(raw)
  if (ncol(raw) < 5) stop("VIII-13 has ", ncol(raw), " columns, expected >= 5")

  # Data starts on the first row whose column 1 parses as a plausible Excel date
  # serial. Anchoring on that rather than a hard-coded row 13 survives the CBI
  # adding or removing a metadata caption.
  serial <- suppressWarnings(as.numeric(raw[[1]]))
  first  <- which(is.finite(serial) & serial > 36000)[1]   # > 1998-07
  if (is.na(first)) stop("No date serials found in VIII-13 column 1")

  body <- raw[seq(first, nrow(raw)), 1:5]
  names(body) <- c("serial", ZCY_SERIES)

  out <- body |>
    dplyr::mutate(date = as.Date(suppressWarnings(as.numeric(.data$serial)),
                                 origin = "1899-12-30")) |>
    dplyr::filter(!is.na(.data$date)) |>
    dplyr::select("date", dplyr::all_of(ZCY_SERIES)) |>
    tidyr::pivot_longer(dplyr::all_of(ZCY_SERIES),
                        names_to = "series", values_to = "value") |>
    dplyr::mutate(value = suppressWarnings(as.numeric(.data$value))) |>
    dplyr::filter(is.finite(.data$value)) |>
    dplyr::arrange(.data$series, .data$date)

  if (nrow(out) == 0) stop("VIII-13 parsed to zero rows")
  out
}

zcy <- get_cbi_zero_coupon_yields()

db_ensure_table(con, "zero_coupon_yields",
                cols = c(date = "DATE", series = "TEXT",
                         value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "zero_coupon_yields", zcy, conflict_cols = c("date", "series"))
