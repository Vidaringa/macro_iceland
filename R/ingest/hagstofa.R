# Shared Hagstofa PX-Web (JSON-stat) query helper
#
# Hagstofa Íslands serves its tables through a PX-Web v1 API that returns
# JSON-stat2 on a POST query. Many monthly/quarterly sources (CPI, wage index,
# national accounts, trade, LFS, ...) all hit the same API with the same shape,
# so the fetch + JSON-stat-unravel lives here once and each source file just
# supplies its table path and query selections.
#
# Sourced by run_monthly.R / run_quarterly.R, which have already attached
# tidyverse + httr2 + jsonlite.
#
# JSON-stat2 layout note (verified against VIS01000): the flat `value` array is
# row-major over the dimensions in `id` order — the FIRST id varies slowest, the
# LAST varies fastest. tidyr::expand_grid() varies its last argument fastest, so
# passing the dimension category codes in forward `id` order reproduces the exact
# cell order. (Passing them reversed silently scrambles values — it returned
# plausible-but-wrong numbers in testing, so the order matters.)

PXWEB_BASE_IS <- "https://px.hagstofa.is/pxis/api/v1/is/"

# Query a PX-Web table and return a tidy long tibble with one row per cell.
#
#   table_path : path under PXWEB_BASE_IS, e.g.
#                "Efnahagur/visitolur/1_vnv/1_vnv/VIS01000.px"
#   selections : named list, one entry per variable to filter, value = the
#                character vector of category codes to keep. Variables omitted
#                here are requested with filter "all" (every category).
#                Names are the PX variable CODES (e.g. "Vísitala", "Liður").
#
# Returns a tibble with one column per dimension (named by the dimension id,
# values are the category CODES, not labels) plus a numeric `value` column.
# The caller maps codes -> canonical English series names and dates.
hagstofa_pxweb_query <- function(table_path, selections = list()) {
  url <- paste0(PXWEB_BASE_IS, table_path)

  # Build the JSON query: for each selection, an item-filter; the API returns
  # all categories of any variable not listed.
  query_items <- purrr::imap(selections, \(vals, code) {
    list(code = code,
         selection = list(filter = "item", values = as.list(vals)))
  }) |> unname()

  body <- list(query = query_items,
               response = list(format = "json-stat2"))

  resp <- httr2::request(url) |>
    httr2::req_body_json(body) |>
    httr2::req_timeout(60) |>
    httr2::req_perform()

  js <- jsonlite::fromJSON(httr2::resp_body_string(resp), simplifyVector = FALSE)

  dim_ids <- unlist(js$id)
  # Order each dimension's category codes by their declared index position, so
  # the grid matches the value array regardless of how the JSON lists them.
  ordered_codes <- function(d) {
    idx <- js$dimension[[d]]$category$index
    names(sort(unlist(idx)))
  }
  dim_codes <- rlang::set_names(purrr::map(dim_ids, ordered_codes), dim_ids)

  grid <- rlang::exec(tidyr::expand_grid, !!!dim_codes)
  grid$value <- purrr::map_dbl(
    js$value, \(x) if (is.null(x)) NA_real_ else as.numeric(x)
  )
  grid
}

# Parse a PX-Web month code ("2026M05") to a first-of-month Date.
hagstofa_month_to_date <- function(x) lubridate::ym(x)

# Parse a PX-Web quarter code ("2026K2" / "2026Q2") to a first-of-quarter Date.
hagstofa_quarter_to_date <- function(x) {
  yr <- as.integer(stringr::str_sub(x, 1, 4))
  q  <- as.integer(stringr::str_extract(x, "(?<=[KQ])\\d"))
  lubridate::make_date(yr, (q - 1L) * 3L + 1L, 1L)
}
