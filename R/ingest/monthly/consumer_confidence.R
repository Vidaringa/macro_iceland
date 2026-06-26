# Monthly — Gallup consumer confidence (Væntingavísitala Gallup, VVG) ----
# Household sentiment index, monthly from 2001-03. A heat-index input (SPEC A1)
# and the single most important crisis signal we have: VVG collapsed from ~145
# (mid-2007) to ~20 (early 2009) in the GFC and is the keystone that lets the
# heat-index factor read persistent crises (the GFC) at full force.
#
# Source: Gallup Iceland's public Looker dashboard, embedded at
#   https://www.gallup.is/data/geytenbq/sso/
# The page loads an SSO-signed Looker embed (gogn.gallup.is) as an iframe; the VVG
# tile is backed by a Looker query whose data is exposed at /explore/<slug>.csv,
# fetchable only from inside the (anonymous, authorised) embed session. We drive
# the page headless with chromote, capture the tile's query slug live off the
# dashboard's own network calls (it changes when Gallup rebuilds the dashboard, so
# it is NOT hard-coded), then fetch the CSV from inside the iframe. Approach ported
# from hagdeild/thjodhagslikan (R/data/09_gallup_confidence.R).
#
# FRAGILE BY NATURE: this depends on Gallup's dashboard DOM and Looker internals.
# If it breaks (slug not captured, iframe not attached), the runner logs it as a
# failed source and the last stored values remain (ragged-edge rule) — VVG is a
# slow series so a missed month is harmless.
#
# Sourced by run_monthly.R (provides `con`; tidyverse + httr2 attached; DB helpers
# + sedlabanki.R sourced, so chromote is available). Target table:
# consumer_confidence (date, series, value), upsert on (date, series).

GALLUP_EMBED <- "https://www.gallup.is/data/geytenbq/sso/"

# Drive the embed headless and return the VVG tile CSV as a string.
get_gallup_vvg_csv <- function(page = GALLUP_EMBED, timeout = 90) {
  b <- chromote::ChromoteSession$new(wait_ = TRUE)
  on.exit(b$close(), add = TRUE)
  b$default_timeout <- timeout

  # Capture the VVG tile's Looker query slug from the dashboard's own calls.
  store <- new.env(); store$slug <- NULL
  b$Network$enable()
  b$Network$responseReceived(function(msg) {
    u <- msg$response$url
    if (grepl("/api/internal/queries/[A-Za-z0-9]{10,}", u)) {
      store$slug <- sub(".*/queries/([A-Za-z0-9]+).*", "\\1", u)
    }
  })

  b$Page$navigate(page)
  b$Page$loadEventFired(wait_ = TRUE)

  # Find the gogn.gallup.is embed iframe (poll until it attaches).
  child <- NULL
  for (i in 1:30) {
    Sys.sleep(1)
    ft <- b$Page$getFrameTree()
    for (c in ft$frameTree$childFrames %||% list())
      if (grepl("gogn.gallup.is", c$frame$url)) child <- c$frame
    if (!is.null(child)) break
  }
  if (is.null(child)) stop("Gallup embed iframe never attached on ", page)
  Sys.sleep(8)  # let the Looker dashboard render its tiles

  world <- b$Page$createIsolatedWorld(frameId = child$id, worldName = "vvg")
  ctx   <- world$executionContextId
  ev <- function(js) b$Runtime$evaluate(
    expression = js, returnByValue = TRUE, contextId = ctx, awaitPromise = TRUE
  )$result$value

  # Trigger the VVG tile's "Download data" action so its query runs (surfacing
  # the slug on the wire). Pump the event loop so the network callback fires.
  ev(paste0(
    "(function(){var e=Array.from(document.querySelectorAll('[aria-label]'))",
    ".find(x=>(x.getAttribute('aria-label')||'')",
    ".indexOf('V\\u00e6ntingav\\u00edsitala Gallup - Tile actions')>-1);e&&e.click();})()"
  ))
  for (i in 1:4) { Sys.sleep(1); ev("1") }
  ev(paste0(
    "(function(){var m=Array.from(document.querySelectorAll('[role=menuitem]'))",
    ".filter(e=>/Download data/i.test(e.textContent||''));m.length&&m[m.length-1].click();})()"
  ))
  for (i in 1:15) { Sys.sleep(1); ev("1"); if (!is.null(store$slug)) break }
  if (is.null(store$slug)) stop("Could not capture the VVG Looker query slug")

  # Fetch the tile data as CSV from inside the embed (same-origin, authorised).
  js <- sprintf(paste0(
    "(async()=>{const r=await fetch('/explore/%s.csv?apply_formatting=true",
    "&apply_vis=true&download=yes&limit=5000',{credentials:'include'});",
    "return await r.text();})()"), store$slug)
  csv <- ev(js)
  if (is.null(csv) || !grepl("VVG", csv)) stop("VVG CSV fetch failed (slug ", store$slug, ")")
  csv
}

# Columns: "  Month" (YYYY-MM), "Miðlína" (constant ref line, dropped), "VVG".
# Icelandic decimal commas.
consumer_confidence_tbl <- get_gallup_vvg_csv() |>
  I() |>
  readr::read_csv(show_col_types = FALSE,
                  locale = readr::locale(decimal_mark = ",", grouping_mark = ".")) |>
  dplyr::rename_with(stringr::str_trim) |>
  dplyr::transmute(
    date   = lubridate::make_date(stringr::str_sub(Month, 1, 4),
                                  stringr::str_sub(Month, 6, 7), 1L),
    series = "CONSUMER_CONFIDENCE",
    value  = as.numeric(VVG)
  ) |>
  dplyr::filter(!is.na(value)) |>
  dplyr::arrange(date)

db_ensure_table(con, "consumer_confidence",
                cols = c(date = "DATE", series = "TEXT", value = "DOUBLE PRECISION"),
                pk = c("date", "series"))
db_upsert(con, "consumer_confidence", consumer_confidence_tbl,
          conflict_cols = c("date", "series"))
