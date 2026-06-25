# Shared Seðlabankinn (Central Bank of Iceland) xmltimeseries helpers
#
# The CBI serves time series from an ASP.NET feed at
#   https://www.sedlabanki.is/xmltimeseries/Default.aspx
# addressed either by a single TimeSeriesID or by a whole GroupID, both with a
# DagsFra/DagsTil date window. The existing daily sources (policy rate, REIBOR,
# FX) already hit this feed by TimeSeriesID; these helpers add (a) group
# discovery — list every series ID + Name + Description in a group, so the right
# TimeSeriesID is FOUND from the feed's own captions rather than guessed
# (INGEST_TASK §0) — and (b) a single-series pull returning a tidy tibble.
#
# Sourced by run_*.R, which have attached tidyverse + xml2 (+ httr2).

CBI_XMLTS <- "https://www.sedlabanki.is/xmltimeseries/Default.aspx"

# List every series in a group: its TimeSeriesID (the <TimeSeries ID="..."> attr),
# Name and Description. Used to locate the exact ID for a wanted series.
cbi_group_catalog <- function(group_id, from = "2000-01-01", to = Sys.Date()) {
  url <- paste0(CBI_XMLTS, "?GroupID=", group_id,
                "&DagsFra=", from, "&DagsTil=", to, "&Type=xml")
  x <- xml2::read_xml(url)
  ts <- xml2::xml_find_all(x, ".//TimeSeries")
  tibble::tibble(
    time_series_id = xml2::xml_attr(ts, "ID"),
    name           = xml2::xml_text(xml2::xml_find_first(ts, "./Name")),
    description    = xml2::xml_text(xml2::xml_find_first(ts, "./Description"))
  )
}

# Pull a single CBI series by TimeSeriesID into a tidy (date, value) tibble.
# Dates in the feed are mm/dd/yyyy h:m:s; values numeric. NA-valued entries
# (non-publication points) are dropped so callers log-miss rather than store NA.
cbi_series <- function(time_series_id, from = "2000-01-01", to = Sys.Date()) {
  url <- paste0(CBI_XMLTS, "?TimeSeriesID=", time_series_id,
                "&DagsFra=", from, "&DagsTil=", to, "&Type=xml")
  x <- xml2::read_xml(url)
  entries <- xml2::xml_find_all(x, ".//Entry")
  tibble::tibble(
    date = lubridate::mdy_hms(
      xml2::xml_text(xml2::xml_find_first(entries, ".//Date"))
    ) |> as.Date(),
    value = as.numeric(
      xml2::xml_text(xml2::xml_find_first(entries, ".//Value"))
    )
  ) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date)
}

# --- gagnabanki.is Excel reports (Angular blob downloads) -------------------
#
# The newer CBI data portal at https://gagnabanki.is/report/<report> serves each
# report as an Angular SPA. Its "Excel" button does NOT hit a stable download URL
# — the app fetches JSON and builds the .xlsx CLIENT-SIDE as a Blob, handing it
# to URL.createObjectURL for a synthetic anchor download. There is therefore no
# server endpoint to GET. We render the page headless (chromote), HOOK
# URL.createObjectURL before clicking so we keep a reference to the Blob, click
# the Excel button, then read the Blob back as base64 and write the bytes.
#
# `report` is the value of the page's `page=` query param (e.g.
# "MARKETS.PENSIONFUNDS.LOANS.SECTOR.TABLE"); pages with a single default report
# (e.g. "pension") can be addressed by the path slug alone with report = NULL.
# Returns the path to a tempfile .xlsx (caller reads it with readxl).
#
# Requires chromote + jsonlite (jsonlite is attached by the runners; chromote
# via ::). The wide date window asks the portal for full history (from 1997).
gagnabanki_report_xlsx <- function(slug, report = NULL,
                                   from = "1990-01-01", to = Sys.Date()) {
  url <- paste0("https://gagnabanki.is/report/", slug,
                "?from=", from, "&to=", to,
                if (!is.null(report)) paste0("&page=", report) else "")

  b <- chromote::ChromoteSession$new(wait_ = TRUE)
  on.exit(b$close(), add = TRUE)
  b$default_timeout <- 60
  b$Page$navigate(url)
  b$Page$loadEventFired(wait_ = TRUE)
  Sys.sleep(8)  # Angular: report grid + Excel button render after load

  # Hook createObjectURL so the Blob the app builds is retained on `window`.
  b$Runtime$evaluate(paste0(
    "window.__capturedBlob=null;(function(){var o=URL.createObjectURL;",
    "URL.createObjectURL=function(b){try{if(b instanceof Blob)",
    "window.__capturedBlob=b;}catch(e){}return o.apply(this,arguments);};})();'ok'"
  ))
  # Click the Excel export button (a mat-button whose label span reads 'Excel').
  b$Runtime$evaluate(paste0(
    "(function(){var s=Array.from(document.querySelectorAll",
    "('span.mdc-button__label')).find(s=>s.textContent.trim()==='Excel');",
    "if(!s)return'no-btn';(s.closest('button')||s).click();return'ok';})()"
  ))
  Sys.sleep(6)  # let the app fetch + build the workbook Blob

  # Read the captured Blob as a base64 data URL (async -> awaitPromise).
  b64 <- b$Runtime$evaluate(paste0(
    "new Promise(function(res){var bl=window.__capturedBlob;",
    "if(!bl){res('NO_BLOB');return;}var fr=new FileReader();",
    "fr.onload=function(){res(fr.result.split(',')[1]);};fr.readAsDataURL(bl);})"
  ), awaitPromise = TRUE)$result$value
  if (identical(b64, "NO_BLOB") || is.null(b64)) {
    stop("gagnabanki Excel export produced no Blob for report '", slug,
         if (!is.null(report)) paste0("/", report) else "", "'")
  }

  tmp <- tempfile(fileext = ".xlsx")
  writeBin(jsonlite::base64_dec(b64), tmp)
  tmp
}

# Read a gagnabanki balance-sheet-style workbook (row labels in col A, a date
# header in row 3 as "YYYY-MM" codes, data from `first_col` to an ever-growing
# last month) into a long (date, series, value) tibble for the requested rows.
# `rows` is a named integer vector: names = series names to store under,
# values = 1-based source row numbers (e.g. c(LOANS_HH = 15L)). Most reports put
# the first data column at C (the default); the balance-sheet OVERVIEW report
# starts one column earlier at B, so `first_col` is overridable.
gagnabanki_wide_rows <- function(xlsx, rows, sheet = 1, first_col = 3L) {
  raw <- readxl::read_excel(xlsx, sheet = sheet,
                            col_names = FALSE, .name_repair = "minimal")
  # Date header is row 3, "YYYY-MM" from `first_col` to the last non-NA cell.
  hdr       <- as.character(unlist(raw[3, ]))
  date_cols <- which(!is.na(hdr) & grepl("^[0-9]{4}-[0-9]{2}$", hdr))
  date_cols <- date_cols[date_cols >= first_col]
  dates     <- lubridate::ym(hdr[date_cols])  # first of month

  purrr::imap_dfr(rows, function(row_num, series_name) {
    tibble::tibble(
      date   = dates,
      series = series_name,
      value  = as.numeric(unlist(raw[as.integer(row_num), date_cols]))
    )
  }) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date, series)
}

# Read a gagnabanki FAME-EXPORT workbook into a long (date, series, value)
# tibble. These differ from the wide reports above: the date header is a row of
# EXCEL SERIALS (not "YYYY-MM" strings), the header row and first data column
# vary by report, and several blocks may repeat the same row labels. So the
# caller passes `header_row`, `first_col` (1-based, e.g. 3 = col C, 2 = col B),
# and `groups` — a named list mapping each output series name to the source row
# number(s) to SUM (one number for a plain row, a vector to combine rows, e.g.
# floating + fixed into one mortgage total).
gagnabanki_serial_rows <- function(xlsx, sheet, header_row, first_col, groups) {
  raw <- readxl::read_excel(xlsx, sheet = sheet,
                            col_names = FALSE, .name_repair = "minimal")
  serials   <- suppressWarnings(as.numeric(unlist(raw[header_row, ])))
  date_cols <- which(!is.na(serials))
  date_cols <- date_cols[date_cols >= first_col]
  # Serials are month-END; floor to the first of the month so these align with
  # the wide-report series (which key on month-start) for easy pairing/joins.
  dates     <- lubridate::floor_date(
    as.Date(serials[date_cols], origin = "1899-12-30"), "month")

  purrr::imap_dfr(groups, function(row_nums, series_name) {
    # Sum the requested source rows column-wise (na.rm so a partly-missing
    # block still totals the available components).
    vals <- vapply(date_cols, function(cc) {
      sum(as.numeric(unlist(raw[as.integer(row_nums), cc])), na.rm = TRUE)
    }, numeric(1))
    tibble::tibble(date = dates, series = series_name, value = vals)
  }) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::arrange(date, series)
}

# --- Govt-bond ownership (gagnabanki "securities" report) -------------------
#
# The gagnabanki report `securities` (Eigendur ríkisverðbréfa) and the historical
# CSV raw_data/eigendur_rikisbrefa.csv share an IDENTICAL shape: one row per
# (year, Icelandic-month, security `Heiti`) with eight holder-type columns. This
# reshapes that wide frame (from either the live Excel or the CSV) into a long
# (date, security, holder, value) tibble. `df` is the parsed sheet/CSV with the
# original Icelandic column names; the three key columns are Ár / Mánuður / Heiti
# and the remaining columns are the holder types, mapped to stable English codes.
gagnabanki_bond_owners_long <- function(df) {
  months <- c(jan = 1, feb = 2, mar = 3, apr = 4, "maí" = 5, "jún" = 6,
              "júl" = 7, "ágú" = 8, sep = 9, okt = 10, "nóv" = 11, des = 12)
  holders <- c(
    "Bankar, sparisjóðir og lánafyrirtæki" = "BANKS",
    "Verðbréfa- og fjárfestingarsjóðir"    = "MUTUAL_FUNDS",
    "Lífeyrissjóðir"                       = "PENSION_FUNDS",
    "Fyrirtæki"                            = "COMPANIES",
    "Tryggingafélög"                       = "INSURERS",
    "Einstaklingar"                        = "INDIVIDUALS",
    "Aðrir"                                = "OTHERS",
    "Erlendir aðilar"                      = "FOREIGN"
  )

  df |>
    dplyr::rename(year = "Ár", month = "Mánuður", security = "Heiti") |>
    dplyr::mutate(
      date = lubridate::make_date(as.integer(.data$year),
                                  months[.data$month], 1L)
    ) |>
    dplyr::select("date", "security", dplyr::all_of(names(holders))) |>
    tidyr::pivot_longer(
      cols = dplyr::all_of(names(holders)),
      names_to = "holder", values_to = "value"
    ) |>
    dplyr::mutate(holder = unname(holders[.data$holder]),
                  value = as.numeric(.data$value)) |>
    dplyr::filter(!is.na(.data$value)) |>
    dplyr::arrange(.data$date, .data$security, .data$holder)
}
