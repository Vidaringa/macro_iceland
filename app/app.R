# Icelandic fixed-income & macro platform — Shiny presentation layer ----
#
# The app reads exclusively from Postgres and holds no model code: everything
# on screen was computed by R/models/ and upserted by the scheduled runners.
#
# Run from the repo root so the repo .Renviron supplies the libpq variables:
#   Rscript -e "shiny::runApp('app', port = 3838)"
#
# shiny::loadSupport() sources app/R/*.R (non-recursively, C-sorted) before
# this file, so every file there is already loaded by the time ui/server run.

library(shiny)
library(dplyr)
library(tidyr)
library(tibble)
library(lubridate)
library(htmltools)
library(echarts4r)
library(reactable)
library(DBI)
library(RPostgres)

# db_connect() — the repo's single DB helper, shared with the ingest runners.
source(file.path("..", "R", "db", "db_helpers.R"))

# SITE_NAME / APP_LANG / REFRESH_SECONDS / ASSET_VERSION come from R/config.R,
# which loadSupport() sources before this file.

options(
  reactable.theme = REACTABLE_THEME,
  reactable.language = REACTABLE_LANG,
  # A stack trace in the browser would be both ugly and a disclosure; figures
  # carry their own empty state instead.
  shiny.sanitize.errors = TRUE
)

# Fill the cache before the port binds, then keep it warm on a timer.
data_refresh()

# Config handed to the client: the ECharts theme and locale (so no colour or
# month name is duplicated in JS), page slugs for the router, and the few UI
# strings the client needs.
app_config <- function() {
  jsonlite::toJSON(list(
    siteName = SITE_NAME,
    theme    = ECHARTS_THEME,
    locale   = ECHARTS_LOCALE_IS,
    pages    = lapply(seq_len(nrow(PAGES)), function(i) list(
      slug = PAGES$slug[i], label = PAGES[[APP_LANG]][i])),
    strings  = list(disconnected = lbl("disconnected"))
  ), auto_unbox = TRUE, null = "null")
}

ui <- function(req) {
  nav <- lapply(seq_len(nrow(PAGES)), function(i) {
    tags$a(href = paste0("#/", PAGES$slug[i]), PAGES[[APP_LANG]][i])
  })

  vint <- dat("vintages")
  vint_txt <- if (nrow(vint)) {
    paste0("Gögn uppfærð ",
           format(max(as.Date(vint$data_to), na.rm = TRUE), "%d.%m.%Y"), ".")
  } else ""

  htmlTemplate(
    file.path("templates", "index.html"),
    site_name       = SITE_NAME,
    site_tagline    = lbl("site_tagline"),
    nav_label       = lbl("nav_label"),
    nav             = tagList(nav),
    tokens_css      = HTML(TOKENS_CSS),
    app_config_json = HTML(app_config()),
    asset_version   = ASSET_VERSION,
    disclaimer      = lbl("disclaimer"),
    vintages        = vint_txt,
    overview        = page_overview_ui(),
    heat            = page_heat_ui(),
    policy          = page_policy_ui(),
    markets         = page_markets_ui(),
    forecasts       = page_forecasts_ui(),
    about           = page_about_ui()
  )
}

server <- function(input, output, session) {
  # "force" is required: plain TRUE only reconnects under Shiny Server/Connect.
  # A forced reconnect opens a fresh session and replays inputs; outputs then
  # re-render from the in-memory cache, so recovery is near-instant.
  session$allowReconnect("force")

  page_overview_server()
  page_heat_server(input)
  page_heat_inputs_server(output)
  page_policy_server()
  page_policy_table_server(output)
  page_markets_server()
  page_markets_tables_server(output)
  page_forecasts_server()

  # Hidden pages are suspended while they are hidden, which is what keeps the
  # first paint cheap. Once the visible page has flushed, un-suspend the rest so
  # they are already drawn when the reader navigates — no per-page wait.
  session$onFlushed(function() {
    for (nm in names(outputOptions(output))) {
      outputOptions(output, nm, suspendWhenHidden = FALSE)
    }
  }, once = TRUE)
}

shinyApp(ui, server)
