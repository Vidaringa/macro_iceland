/* ===========================================================================
   Client runtime: ECharts theme/locale registration, the hash router, the
   Icelandic number/date formatters used by chart tooltips, and the connection
   banner. Everything configurable arrives from R through #app-config, so this
   file holds no colours and no strings that belong in labels.R.
   =========================================================================== */
(function () {
  "use strict";

  var cfgEl = document.getElementById("app-config");
  var CFG = cfgEl ? JSON.parse(cfgEl.textContent) : {};

  var APP = window.APP = {
    config: CFG,
    pages: CFG.pages || [],
    strings: CFG.strings || {},
    defaultPage: (CFG.pages && CFG.pages[0] && CFG.pages[0].slug) || "yfirlit"
  };

  /* --- ECharts theme + locale -------------------------------------------
     Registered from here rather than via e_theme(), which would attach a
     dependency on a themes/<name>.js file that does not exist inside the
     installed package. Charts then reference the theme by name. */
  if (window.echarts) {
    if (CFG.theme)  echarts.registerTheme("editorial", CFG.theme);
    if (CFG.locale) echarts.registerLocale("IS", CFG.locale);
  }

  /* --- formatters --------------------------------------------------------
     Intl with is-IS gives the decimal comma and thin-space grouping that an
     Icelandic reader expects, without shipping a formatting library. */
  var NUM_CACHE = {};
  function nf(digits) {
    if (!NUM_CACHE[digits]) {
      NUM_CACHE[digits] = new Intl.NumberFormat("is-IS", {
        minimumFractionDigits: digits, maximumFractionDigits: digits
      });
    }
    return NUM_CACHE[digits];
  }
  APP.fmt = function (v, digits) {
    if (v === null || v === undefined || isNaN(v)) return "—";
    return nf(digits === undefined ? 1 : digits).format(v);
  };

  /* Axis ticks: clean numbers, no trailing zeros. ECharts picks the interval,
     so the label only has to show as many decimals as that interval needs. */
  APP.fmtAxis = function (v) {
    if (v === null || v === undefined || isNaN(v)) return "";
    var d = Math.abs(v) < 1 && v !== 0 ? 2 : (Math.abs(v % 1) > 1e-9 ? 1 : 0);
    return nf(d).format(v);
  };

  var MONTHS = (CFG.locale && CFG.locale.time && CFG.locale.time.month) || [];
  APP.fmtDate = function (value, freq) {
    var d = value instanceof Date ? value : new Date(value);
    if (isNaN(d.getTime())) return String(value);
    var y = d.getUTCFullYear(), m = d.getUTCMonth(), day = d.getUTCDate();
    if (freq === "month")   return (MONTHS[m] || (m + 1)) + " " + y;
    if (freq === "quarter") return (Math.floor(m / 3) + 1) + "F " + y;
    return day + ". " + (MONTHS[m] || (m + 1)) + " " + y;
  };

  /* Tooltip: date heading, then one row per series with the VALUE FIRST and a
     colour key beside the label — identity comes from the mark, never from
     colouring the text. */
  APP.tip = function (params, opts) {
    opts = opts || {};
    var p = Array.isArray(params) ? params : [params];
    if (!p.length) return "";
    var out = '<div class="tip"><div class="tip__head">' +
              APP.fmtDate(p[0].axisValue !== undefined ? p[0].axisValue : p[0].value[0], opts.freq) +
              "</div>";
    for (var i = 0; i < p.length; i++) {
      var s = p[i];
      var v = Array.isArray(s.value) ? s.value[1] : s.value;
      if (v === null || v === undefined || isNaN(v)) continue;
      if (!s.seriesName || s.seriesName.charAt(0) === ".") continue;
      out += '<div class="tip__row">' +
             '<span class="tip__key" style="background:' + s.color + '"></span>' +
             '<span class="tip__val">' + APP.fmt(v, opts.digits) +
             (opts.unit ? " " + opts.unit : "") + "</span>" +
             '<span class="tip__lab">' + s.seriesName + "</span></div>";
    }
    return out + "</div>";
  };

  /* --- router ------------------------------------------------------------
     Visibility is CSS-driven off html[data-page] (set inline before first
     paint), so this only has to keep the attribute, nav state and title in
     sync — and resize the charts that were hidden while they rendered. */
  function currentSlug() {
    var h = (location.hash || "").replace(/^#\/?/, "").split("?")[0];
    var known = APP.pages.some(function (p) { return p.slug === h; });
    return known ? h : APP.defaultPage;
  }

  function resizeCharts(slug) {
    var sec = document.querySelector('section[data-page="' + slug + '"]');
    if (!sec || !window.HTMLWidgets) return;
    var nodes = sec.querySelectorAll(".echarts4r");
    for (var i = 0; i < nodes.length; i++) {
      var w = HTMLWidgets.find("#" + nodes[i].id);
      // Synchronous resize: ECharts sizes a canvas to a hidden element as 0,
      // and waiting for the observer leaves a visible blank beat.
      if (w && w.getChart && w.getChart()) { try { w.getChart().resize(); } catch (e) {} }
    }
  }

  function route() {
    var slug = currentSlug();
    document.documentElement.dataset.page = slug;

    var links = document.querySelectorAll(".nav a");
    for (var i = 0; i < links.length; i++) {
      var on = links[i].getAttribute("href") === "#/" + slug;
      if (on) links[i].setAttribute("aria-current", "page");
      else links[i].removeAttribute("aria-current");
    }
    var page = APP.pages.filter(function (p) { return p.slug === slug; })[0];
    if (page && CFG.siteName) document.title = page.label + " · " + CFG.siteName;

    resizeCharts(slug);
    window.scrollTo(0, 0);
  }

  window.addEventListener("hashchange", route);
  document.addEventListener("DOMContentLoaded", route);

  // Charts finishing after a route change need the same treatment.
  document.addEventListener("shiny:value", function () {
    setTimeout(function () { resizeCharts(currentSlug()); }, 0);
  });

  /* --- connection banner -------------------------------------------------
     Shiny's grey-out overlay is suppressed in CSS; this is the replacement.
     allowReconnect("force") on the server restores the session, and outputs
     re-render from the in-memory cache, so the interruption is brief. */
  var banner = document.getElementById("app-banner");
  function showBanner(msg) {
    if (!banner) return;
    banner.textContent = msg;
    banner.hidden = false;
  }
  document.addEventListener("shiny:disconnected", function () {
    showBanner(APP.strings.disconnected || "");
  });
  document.addEventListener("shiny:connected", function () {
    if (banner) banner.hidden = true;
  });
})();
