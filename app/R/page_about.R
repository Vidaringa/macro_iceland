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

      htmltools::tags$h2("Þjóðhagsspár"),
      htmltools::tags$p(
        "Sama BVAR-líkan og spáir stýrivöxtum spáir samtímis verðbólgu, ",
        "hitastigi hagkerfisins, framleiðsluspennu og gengisbreytingu. Það er ",
        "eitt líkan, svo spárnar eru innbyrðis samkvæmar: þær lýsa einni ",
        "framtíð, ekki fjórum óskyldum."),
      htmltools::tags$p(
        "Spárnar eru ", htmltools::tags$b("dreifispár", .noWS = "after"), ". ",
        "Bilið — hversu ólíkar útkomur eru líklegar — er niðurstaðan; ",
        "miðgildið er samantekt á dreifingunni en ekki fullyrðing um hvað ",
        "gerist."),

      htmltools::tags$h2("Gengisspá krónunnar"),
      htmltools::tags$p(
        "Sérstakt BVAR-líkan metur óvissu um mánaðarlega gengisbreytingu út frá ",
        "vaxtamun við evrusvæðið, viðskiptajöfnuði, viðskiptakjörum og ",
        "hitastigi hagkerfisins. Það er aðskilið frá vaxtalíkaninu af því að ",
        "það spáir breytingu en ekki stöðu, og getur því notað ferskari gögn."),
      htmltools::tags$details(
        htmltools::tags$summary("Hvað líkanið gerir EKKI"),
        htmltools::tags$ul(
          htmltools::tags$li(
            htmltools::tags$b("Það spáir ekki fyrir um átt gengisbreytinga."),
            " Prófun utan úrtaks — líkanið endurmetið í hverjum mánuði og ",
            "borið saman við það sem raunverulega gerðist — sýnir enga ",
            "marktæka hæfni umfram hreina tilviljun þegar leiðrétt er fyrir ",
            "fjölda prófana, og líkanið slær ekki út einfalda viðmiðunarspá um ",
            "óbreytt gengi. Þetta er birt vegna þess að það er satt, ekki þrátt ",
            "fyrir það: mánaðarlegar gengisbreytingar eru að mestu ",
            "ófyrirsjáanlegar."),
          htmltools::tags$li(
            "Gagnlega niðurstaðan er ", htmltools::tags$b("óvissubilið", .noWS = "after"),
            ": hversu stórar hreyfingar eru líklegar á næstu mánuðum. Það ",
            "nýtist við ákvarðanir um gengisvarnir þótt áttin sé óþekkt."),
          htmltools::tags$li(
            "Krónan er stýrt fljótandi. Seðlabankinn hefur átt viðskipti á ",
            "gjaldeyrismarkaði í meirihluta mánaða á tímabilinu, og inngrip ",
            "hans ráðast af gengishreyfingum. Spáin er því skilyrt því að ",
            "bankinn bregðist ekki við."))),

      htmltools::tags$h2("Vaxtaferlar og verðbólguálag"),
      htmltools::tags$p(
        "Ferlar eru lagaðir að ávöxtunarkröfu ríkisbréfa með Nelson-Siegel ",
        "aðferð: einn ferill úr óverðtryggðum RIKB-bréfum og annar úr ",
        "verðtryggðum RIKS-bréfum. Munurinn á þeim er ",
        htmltools::tags$b("verðbólguálagið", .noWS = "after"), " — sú ",
        "verðbólga sem þarf að ganga eftir til að bréfin tvö skili sömu ávöxtun."),
      htmltools::tags$details(
        htmltools::tags$summary("Aðferð og fyrirvarar"),
        htmltools::tags$ul(
          htmltools::tags$li(
            "Nelson-Siegel, ekki Svensson. Svensson hefur sex stika en aðeins ",
            "sjö nothæf óverðtryggð bréf eru í boði; þá er nánast ekkert svigrúm ",
            "eftir. Þriggja þátta ferill er það sem gögnin bera."),
          htmltools::tags$li(
            "Lögunarstikinn (lambda) er ", htmltools::tags$b("fastur", .noWS = "after"),
            ", ekki endurmetinn daglega. Frjáls stiki lækkar frávik dagsins en ",
            "lætur ferilinn sveiflast milli daga, og þá er ekki hægt að bera ",
            "saman ferla frá degi til dags."),
          htmltools::tags$li(
            "Bréf með innan við þrjá mánuði til gjalddaga eru undanskilin. Þau ",
            "hreyfast eftir eigin framboði en ekki eftir ferlinum."),
          htmltools::tags$li(
            "Ferlarnir eru aldrei birtir styttra en stysta bréfið sem þeir byggja ",
            "á. Stysta verðtryggða bréfið er um þriggja ára, og neðan við eigin ",
            "gögn ræðst lögun ferilsins af stikanum einum — að birta tölu ",
            "þar væri að búa hana til."),
          htmltools::tags$li(
            "Frávik hvers bréfs frá eigin ferli er birt sem ",
            "ódýrt/dýrt-mælikvarði. Það er lýsandi stærð, ekki ráðgjöf."))),

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
        htmltools::tags$li("Seðlabanki Íslands — vextir, gengi, forði, ríkisbréfaeign, greiðslujöfnuður"),
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
