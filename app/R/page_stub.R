# Placeholder for pages not yet built ----
#
# Keeps the router, nav and layout honest while the remaining pages are built,
# and is deleted once page_heat / page_policy / page_markets / page_about land.

page_stub_ui <- function(code) {
  htmltools::tagList(
    htmltools::tags$div(
      class = "page__head",
      htmltools::tags$h1(lbl(code)),
      htmltools::tags$p(class = "lede", "Í vinnslu.")
    )
  )
}
