# A1 heat-index — verification checks (run interactively, never scheduled) ----
#
# Sanity-checks the extracted factor against the cycle and confirms the outputs
# landed in Postgres. Run from the repo root AFTER R/run_models.R:
#   source("R/models/checks/heat_index_checks.R")
# Each check prints a PASS/FAIL line; `p_index` is left as an in-memory ggplot to
# view interactively (not saved to disk). GDP is the key external anchor precisely
# because it is held OUT of the model.

library(tidyverse)
library(DBI)
library(RPostgres)

con <- DBI::dbConnect(RPostgres::Postgres())

level   <- dplyr::tbl(con, "heatindex_level") |>
  dplyr::filter(estimate_kind == "smoothed") |> dplyr::collect() |> dplyr::arrange(date)
contrib <- dplyr::tbl(con, "heatindex_contributions") |> dplyr::collect()
std     <- dplyr::tbl(con, "heatindex_standardisation") |> dplyr::collect()
inputs  <- dplyr::tbl(con, "heatindex_inputs_filtered") |> dplyr::collect()

chk <- function(label, pass, detail = "") {
  cat(sprintf("[%s] %s%s\n", if (pass) "PASS" else "FAIL", label,
              if (nzchar(detail)) paste0(" — ", detail) else ""))
}
win <- function(lo, hi) {
  v <- level$index[level$date >= as.Date(lo) & level$date <= as.Date(hi)]
  mean(v, na.rm = TRUE)
}

# 1.0.0 CRISIS DIPS ----
gfc   <- win("2008-09-01", "2009-06-01")
covid <- win("2020-02-01", "2020-08-01")
boom  <- win("2016-01-01", "2018-12-01")
recov <- win("2021-06-01", "2022-12-01")
covid_decile <- mean(level$index <= covid, na.rm = TRUE)   # share of months at/below COVID level
chk("COVID 2020 H1 is a deep trough (bottom decile)", covid < 0 && covid_decile <= 0.10,
    sprintf("covid=%.2f, %.0f%% of months <= it", covid, 100 * covid_decile))
chk("GFC 2008-09 is a real trough (< -1.5)", gfc < -1.5, sprintf("gfc=%.2f", gfc))
chk("2021-22 recovery hotter than 2016-18", recov > boom,
    sprintf("recov=%.2f vs boom=%.2f", recov, boom))

# 2.0.0 GDP CORRELATION (held-out anchor) ----
# GDP YoY is held OUT of the model, so this is genuine external validity. Tested on
# the 2010+ sample where the input panel is fully populated — pre-2010 the factor
# is thin (most monthly series start 2003-2015) and tracks GDP more loosely, which
# is expected for a coincident index and why the reference window is 2010-2019. The
# full-sample correlation is reported alongside for context.
gdp_yoy <- dplyr::tbl(con, "national_accounts") |>
  dplyr::filter(series == "GDP_yoy") |> dplyr::collect() |>
  dplyr::transmute(q = lubridate::floor_date(date, "quarter"), gdp = value)
idx_q <- level |>
  dplyr::mutate(q = lubridate::floor_date(date, "quarter")) |>
  dplyr::group_by(q) |> dplyr::summarise(index_q = mean(index), .groups = "drop")
gdp_join <- dplyr::inner_join(idx_q, gdp_yoy, by = "q")
gdp_cor_all <- stats::cor(gdp_join$index_q, gdp_join$gdp, use = "complete.obs")
gdp_recent  <- dplyr::filter(gdp_join, q >= as.Date("2010-01-01"))
gdp_cor     <- stats::cor(gdp_recent$index_q, gdp_recent$gdp, use = "complete.obs")
chk("index correlates with held-out GDP YoY, 2010+ (> 0.6)", gdp_cor > 0.6,
    sprintf("r(2010+)=%.2f, r(all)=%.2f", gdp_cor, gdp_cor_all))

# 3.0.0 SIGN ----
# Unemployment carries sign = -1, so its standardised input value_std is HIGH when
# unemployment is LOW. A hot economy has low unemployment, so in the hottest months
# the unemployment input (and hence its contribution) should be positive — low
# unemployment adds heat. (This confirms the sign orientation propagated correctly.)
unemp_hot <- inputs |>
  dplyr::filter(series == "LFS_UNEMPLOYMENT", observed) |>
  dplyr::inner_join(dplyr::select(level, date, index), by = "date") |>
  dplyr::filter(index >= stats::quantile(level$index, 0.9, na.rm = TRUE)) |>
  dplyr::summarise(m = mean(value_std)) |> dplyr::pull(m)
chk("unemployment input high (low unemployment) when index hot", unemp_hot > 0,
    sprintf("mean value_std in hot months=%.3f", unemp_hot))

# 4.0.0 DECOMPOSITION ADDS UP ----
add_diff <- level |>
  dplyr::select(date, index) |>
  dplyr::inner_join(
    contrib |> dplyr::group_by(date) |> dplyr::summarise(s = sum(contribution), .groups = "drop"),
    by = "date") |>
  dplyr::summarise(d = max(abs(index - s))) |> dplyr::pull(d)
chk("group contributions sum to index", add_diff < 1e-8, sprintf("max abs diff=%.1e", add_diff))

# 5.0.0 STANDARDISATION FROZEN ----
ref_ok <- all(std$ref_start == as.Date("2010-01-01")) &&
          all(std$ref_end   == as.Date("2019-12-31"))
has_factor <- "__FACTOR__" %in% std$series
chk("standardisation uses one fixed reference window", ref_ok)
chk("__FACTOR__ normalisation row present", has_factor)

# 6.0.0 OUTPUTS LANDED ----
chk("no NA in index", !anyNA(level$index))
chk("all 6 groups decomposed",
    setequal(unique(contrib$group),
             c("consumption", "labour", "housing", "external", "sentiment", "financial")))
chk("index current to latest data month",
    max(level$date) >= as.Date("2026-01-01"), sprintf("max date=%s", max(level$date)))

# 6.5.0 ROBUSTNESS (v2) — COVID proportionate, not 10x+ every other event ----
gfc_trough   <- min(level$index[level$date >= as.Date("2008-06-01") &
                                level$date <= as.Date("2009-12-01")], na.rm = TRUE)
covid_trough <- min(level$index[level$date >= as.Date("2020-01-01") &
                                level$date <= as.Date("2020-12-01")], na.rm = TRUE)
chk("COVID trough proportionate to GFC (robust scale; ratio < 6)",
    covid_trough / gfc_trough < 6,
    sprintf("COVID=%.2f GFC=%.2f ratio=%.1f", covid_trough, gfc_trough,
            covid_trough / gfc_trough))

# 6.6.0 LOW-CONFIDENCE FLAG (v3) — thin pre-2004 panel marked ----
# From 2004 the deep-history block (confidence, house prices, FX, card, labour,
# residential investment) is present and the GFC is genuinely observable.
chk("pre-2004 flagged low-confidence, post-2004 not",
    all(level$low_confidence[level$date <  as.Date("2004-01-01")]) &&
    !any(level$low_confidence[level$date >= as.Date("2004-01-01")]))
chk("observed-series count higher post-2004 than pre",
    median(level$n_observed[!level$low_confidence]) >
    median(level$n_observed[level$low_confidence]),
    sprintf("pre=%d post=%d",
            stats::median(level$n_observed[level$low_confidence]),
            stats::median(level$n_observed[!level$low_confidence])))

# 6.7.0 GALLUP CONFIDENCE drives the GFC (v3) — keystone signal present ----
chk("consumer confidence is an input with non-trivial loading",
    any(inputs$series == "CONSUMER_CONFIDENCE") &&
    abs(unique(inputs$loading[inputs$series == "CONSUMER_CONFIDENCE"])[1]) > 0.05)

# 7.0.0 PLOT (in-memory; view interactively) ----
recessions <- tibble::tibble(
  xmin = as.Date(c("2008-09-01", "2020-02-01")),
  xmax = as.Date(c("2009-12-01", "2020-08-01"))
)
p_index <- ggplot2::ggplot(level, ggplot2::aes(date, index)) +
  ggplot2::geom_rect(data = recessions, inherit.aes = FALSE,
                     ggplot2::aes(xmin = xmin, xmax = xmax, ymin = -Inf, ymax = Inf),
                     fill = "grey85") +
  ggplot2::geom_hline(yintercept = 0, colour = "grey50") +
  ggplot2::geom_line(linewidth = 0.5) +
  ggplot2::labs(title = "A1 heat index (coincident state of the economy)",
                subtitle = "z vs 2010-2019 normal; higher = hotter; shaded = GFC / COVID",
                x = NULL, y = "index (SD)")

DBI::dbDisconnect(con)
cat("\nView `p_index` to inspect the series interactively.\n")
