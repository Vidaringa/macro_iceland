# App constants ----
#
# These live in app/R/ rather than app.R because shiny::loadSupport() sources
# this directory into the app environment BEFORE app.R runs, and the data layer
# and theme read these constants at load time. The filename sorts first so the
# values exist before any other support file uses them.

SITE_NAME       <- "Hagsjá"   # masthead wordmark — placeholder, see plan
APP_LANG        <- "is"       # "is" | "en"; every string lives in labels.R
REFRESH_SECONDS <- 300        # data poll; models land ~17:30 daily
ASSET_VERSION   <- "8"        # bump to bust the CSS/JS/font cache
