# Aðferðafræði — what the numbers are and where they come from ----
#
# A reader who trades on these numbers is entitled to know how they are made and
# what they do not do. The limitations are stated plainly rather than buried:
# the BVAR's blindness to announced policy turns and the thin pre-2004 panel are
# both material to how the page should be read.

page_about_ui <- function() {
  vint <- dat("vintages")
  mods <- dat("models")
  std  <- dat("heat_std")

  ref <- if (nrow(std)) paste0(format(std$ref_start[1], "%Y"), "–",
                               format(std$ref_end[1], "%Y")) else "2010–2019"

  htmltools::tagList(
    htmltools::tags$div(
      class = "page__head",
      htmltools::tags$h1(lbl("about")),
      htmltools::tags$p(class = "lede",
                        "Hvernig tölurnar á þessum vef eru reiknaðar, úr hvaða ",
                        "gögnum og með hvaða fyrirvörum.")
    ),

    htmltools::tags$div(
      class = "prose",

      htmltools::tags$h2("Hitastig hagkerfisins"),
      htmltools::tags$p(
        "Hitastigið er samfallandi vísitala: hún dregur saman 19 mánaðarlegar ",
        "hagtölur í eina tölu sem lýsir því hversu heitt eða kalt hagkerfið er ",
        # .noWS keeps htmltools from inserting a space before the full stop.
        "um þessar mundir. Hún er ",
        htmltools::tags$b("ekki spá", .noWS = "after"), "."),
      htmltools::tags$p(
        "Hver vísir er staðalfærður með miðgildi og miðgildisfráviki (MAD) yfir ",
        paste0("viðmiðunartímabilið ", ref, ", og útgildi eru klippt. Þessi aðferð, "),
        "frekar en meðaltal og staðalfrávik, gerir það að verkum að samstilltur ",
        "skellur eins og 2020 verður ekki óhóflega stór í samanburði við aðrar ",
        "niðursveiflur."),
      htmltools::tags$p(
        "Tveir þættir eru metnir og vegnir saman eftir skýrðum breytileika: ",
        "hátíðnilegur umsvifaþáttur og hægari væntinga- og fjármálaþáttur. ",
        "Þannig koma bæði snöggir raunskellir og lengri niðursveiflur fram."),
      htmltools::tags$details(
        htmltools::tags$summary("Fyrirvarar"),
        htmltools::tags$ul(
          htmltools::tags$li(
            "Nýjasti mánuðurinn byggir aðeins á þeim vísum sem þegar hafa verið ",
            "birtir. Hann er merktur sem bráðabirgðatala og sýndur með brotinni ",
            "línu; hann tekur breytingum eftir því sem fleiri tölur berast."),
          htmltools::tags$li(
            "Fyrir 2004 er gagnasafnið þunnt. Þau ár eru merkt sérstaklega og ",
            "dregin upp í daufum lit."),
          htmltools::tags$li(
            "Staðalfærslubreytur eru fastar og eru aðeins endurreiknaðar þegar ",
            "útgáfa líkansins breytist — annars væri samanburður milli ",
            "útgáfudaga ekki marktækur.")
        )),

      htmltools::tags$h2("Stýrivaxtaspá"),
      htmltools::tags$p("Tvær ólíkar spár eru birtar hlið við hlið:"),
      htmltools::tags$ul(
        htmltools::tags$li(
          htmltools::tags$b("BVAR-dreifispá"), " — Bayesískt VAR-líkan með ",
          "stýrivöxtum, verðbólgu, hitastigi, framleiðsluspennu, vöxtum ECB og ",
          "gengi. Spáin er dreifing, ekki eitt gildi; birt eru miðgildi og 68% ",
          "og 90% óvissubil, 18 mánuði fram."),
        htmltools::tags$li(
          htmltools::tags$b("Markaðsvænting"), " — lesin úr ",
          "REIBOR-millibankaferlinum að frádregnum áhættuálögum sem eru fastar ",
          "frá 2015–2019. Nær sex mánuði fram; lengra nær ferillinn ekki.")),
      htmltools::tags$details(
        htmltools::tags$summary("Fyrirvarar"),
        htmltools::tags$ul(
          htmltools::tags$li(
            "BVAR-líkanið er metið á vaxtaröð sem er mjög þrálát. Það þýðir að ",
            "spáin ", htmltools::tags$b("tekur ekki mið af boðuðum vaxtaákvörðunum"),
            " og bregst seint við vendipunktum. Markaðsvæntingin verðleggur slíka ",
            "vendipunkta og er því oft á undan."),
          htmltools::tags$li(
            "Spárnar hafa hvor sinn upphafsmánuð, því þær byggja á mismunandi ",
            "gögnum. Þær eru ekki tvær útgáfur af sama hlutnum."),
          htmltools::tags$li(
            "Þriðja lesningin — viðbragðsfall með líkum á hækkun, óbreyttum ",
            "vöxtum eða lækkun á hverjum fundi — er í vinnslu."))),

      htmltools::tags$h2("Markaðsgögn"),
      htmltools::tags$p(
        "Ávöxtunarkrafa ríkisbréfa er dagslokakrafa frá Nasdaq Iceland. Dagar ",
        "þar sem markaður var lokaður eru síaðir frá. Engin ferilaðlögun er ",
        "gerð: hver punktur er eitt bréf. Verðtryggð bréf (RIKS) bera ",
        htmltools::tags$b("raunávöxtun"), " og eru því aldrei sýnd á sama ás og ",
        "óverðtryggð bréf (RIKB)."),

      htmltools::tags$h2("Gögn og útgáfur"),
      if (nrow(vint)) htmltools::tags$ul(
        lapply(seq_len(nrow(vint)), function(i) htmltools::tags$li(
          paste0(overview_vintage_label(vint$tbl[i]), ": "),
          htmltools::tags$b(format(as.Date(vint$data_to[i]), "%d.%m.%Y"))))),
      if (nrow(mods)) htmltools::tagList(
        htmltools::tags$p(style = "margin-top:12px", "Útgáfur líkana:"),
        htmltools::tags$ul(
          lapply(seq_len(nrow(mods)), function(i) htmltools::tags$li(
            paste0(lbl(mods$module[i]), ": ", mods$model_version[i],
                   " (reiknað ",
                   format(as.Date(mods$computed_at[i]), "%d.%m.%Y"), ")"))))),

      htmltools::tags$h2("Heimildir"),
      htmltools::tags$ul(
        htmltools::tags$li("Seðlabanki Íslands — vextir, gengi, forði, ríkisbréfaeign"),
        htmltools::tags$li("Hagstofa Íslands — verðlag, vinnumarkaður, þjóðhagsreikningar, utanríkisviðskipti"),
        htmltools::tags$li("Nasdaq Iceland — ávöxtunarkrafa ríkisbréfa"),
        htmltools::tags$li("Gallup — væntingavísitala")),

      htmltools::tags$h2("Fyrirvari"),
      htmltools::tags$p(
        htmltools::tags$b(lbl("disclaimer")),
        " Tölurnar eru birtar eins og þær eru reiknaðar, án ábyrgðar á ",
        "villum í undirliggjandi gögnum eða á ákvörðunum sem á þeim eru teknar.")
    )
  )
}
