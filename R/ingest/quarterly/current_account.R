# Quarterly — balance of payments / current account (Seðlabankinn) ----
# The current account (viðskiptajöfnuður) and its four components, from the CBI's
# Greiðslujöfnuður við útlönd time-series workbook. Quarterly from 1995 Q1, in
# million ISK; a deficit prints negative.
#
# Sourced by run_quarterly.R, which provides `con`, has attached tidyverse +
# httr2 + xml2, and sourced the DB helpers and R/ingest/sedlabanki.R (chromote and
# rvest are called namespace-qualified, as in reserves_adequacy.R). Target table:
# current_account (date, series, value), upsert on (date, series).
#
# WHY NOT THE SDDS FEED: this file previously pulled TimeSeriesID 83
# (NSDP.EXS.BPCAAC.XXX.ISK.IS.N.Q) from the xmltimeseries SDDS/NSDP feed. That was
# wrong twice over. It served only a rolling ~4-quarter window, and — verified
# against this workbook and against the Bank's own press release — the values were
# not the current account at all: the feed's 2026 Q2 value of -1230 is
# `Jöfnuður fjárframlaga` (the CAPITAL account), while the current account that
# quarter was -120,269 m.kr. ("Halli á viðskiptajöfnuði 120,3 ma.kr. á öðrum
# ársfjórðungi 2026"). The six rows that feed had written were deleted when this
# rewrite landed.
#
# ACCESS MODE (c) — Excel-only, resolved live: the workbook's /library/?itemid=
# GUID rotates with each quarterly release, so it is found by anchor caption on
# the Gagnatorg page (same approach as reserves_adequacy.R). Inside, sheet
# "Lárétt" is quarters-across-columns: row 5 carries "YYYY Qn" headers and column
# A the Icelandic row labels. Rows are located BY LABEL, never by number — the
# sheet carries 220+ rows of BoP detail and their positions drift between
# releases.

BOP_PAGE <- "https://sedlabanki.is/gagnatorg/greidslujofnudur-vid-utlond/"

# Row label -> stored series code. The four components sum to the current account
# (checked below), so storing them lets a downstream model use the decomposition
# rather than only the headline.
BOP_ROWS <- c(
  "Viðskiptajöfnuður"  = "CURRENT_ACCOUNT",
  "Vöruskiptajöfnuður" = "TRADE_BALANCE",
  "Þjónusta"           = "SERVICES_BALANCE",
  "Frumþáttatekjur"    = "PRIMARY_INCOME",
  "Rekstrarframlög"    = "SECONDARY_INCOME"
)

get_cbi_balance_of_payments <- function() {
  b <- chromote::ChromoteSession$new(wait_ = TRUE)
  on.exit(b$close(), add = TRUE)
  b$default_timeout <- 60

  b$Page$navigate(BOP_PAGE)
  b$Page$loadEventFired(wait_ = TRUE)
  Sys.sleep(5)
  a <- b$Runtime$evaluate("document.documentElement.outerHTML")$result$value |>
    rvest::read_html() |> rvest::html_elements("a")
  href <- rvest::html_attr(a, "href")
  txt  <- rvest::html_text2(a) |> stringr::str_squish()
  pick <- which(!is.na(href) & grepl("itemid=", href) &
                grepl("Greiðslujöfnuður við útlönd", txt, fixed = TRUE))[1]
  if (is.na(pick)) stop("No Greiðslujöfnuður workbook link on the Gagnatorg page")

  xlsx <- tempfile(fileext = ".xlsx")
  httr2::request(paste0("https://sedlabanki.is", href[pick])) |>
    httr2::req_timeout(120) |> httr2::req_perform(path = xlsx)

  raw <- readxl::read_excel(xlsx, sheet = "Lárétt", col_names = FALSE,
                            .name_repair = "minimal")
  m <- as.matrix(raw)

  hdr   <- as.character(m[5, ])
  qcols <- which(!is.na(hdr) & grepl("^[0-9]{4} Q[1-4]$", hdr))
  if (length(qcols) == 0) stop("No 'YYYY Qn' quarter headers in the Lárétt sheet")
  labels <- stringr::str_squish(as.character(m[, 1]))

  out <- purrr::imap_dfr(BOP_ROWS, function(code, label) {
    r <- which(labels == label)[1]
    if (is.na(r)) stop("BoP row not found in workbook: ", label)
    tibble::tibble(
      quarter = hdr[qcols],
      series  = code,
      value   = suppressWarnings(as.numeric(m[r, qcols]))
    )
  }) |>
    dplyr::mutate(
      date = lubridate::make_date(
        as.integer(substr(.data$quarter, 1, 4)),
        (as.integer(substr(.data$quarter, 7, 7)) - 1L) * 3L + 1L, 1L)
    ) |>
    dplyr::filter(!is.na(.data$value)) |>
    dplyr::select("date", "series", "value") |>
    dplyr::arrange(.data$series, .data$date)

  # The current account IS the sum of its four components. Checking it here turns
  # a silent mis-read (a drifted row label matching the wrong line) into a loud
  # failure, which is the whole reason the previous source went unnoticed.
  chk <- out |>
    tidyr::pivot_wider(names_from = "series", values_from = "value") |>
    dplyr::filter(!is.na(.data$CURRENT_ACCOUNT)) |>
    dplyr::mutate(diff = abs(.data$CURRENT_ACCOUNT -
                               (.data$TRADE_BALANCE + .data$SERVICES_BALANCE +
                                  .data$PRIMARY_INCOME + .data$SECONDARY_INCOME)))
  if (any(chk$diff > 1, na.rm = TRUE)) {
    stop("BoP identity failed: current account != sum of components in ",
         sum(chk$diff > 1, na.rm = TRUE), " quarter(s)")
  }
  out
}

current_account_tbl <- get_cbi_balance_of_payments()

db_ensure_table(con, "current_account",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))

# One-off cleanup of the rows the old SDDS feed wrote. An upsert on (date, series)
# overwrites the quarters the workbook also carries, but would silently leave
# behind any quarter it does not — so delete anything under the CURRENT_ACCOUNT
# key outside the span this run just fetched. Bounded by the fetched range, so it
# can never remove a quarter the workbook still has.
ca_dates <- current_account_tbl$date[current_account_tbl$series == "CURRENT_ACCOUNT"]
DBI::dbExecute(con,
  "DELETE FROM current_account WHERE series = 'CURRENT_ACCOUNT' AND date > $1",
  params = list(max(ca_dates)))

db_upsert(con, "current_account", current_account_tbl,
          conflict_cols = c("date", "series"))
