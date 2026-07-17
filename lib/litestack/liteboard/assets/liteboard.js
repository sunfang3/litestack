/* Liteboard progressive enhancement — no eval, no remote deps */
(function () {
  "use strict";

  function parseData(el) {
    if (!el) return null;
    var raw = el.getAttribute("data-chart");
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch (e) {
      return null;
    }
  }

  function enhanceCharts() {
    var nodes = document.querySelectorAll("[data-chart]");
    nodes.forEach(function (node) {
      var data = parseData(node);
      if (!data || !Array.isArray(data) || data.length === 0) return;
      node.setAttribute("data-enhanced", "true");
      // HTML tables remain authoritative; mark enhancement only.
      var note = document.createElement("p");
      note.className = "chart-enhanced-note";
      note.textContent = "Chart data loaded (" + data.length + " points). Table below remains available.";
      if (!node.querySelector(".chart-enhanced-note")) {
        node.insertBefore(note, node.firstChild);
      }
    });
  }

  function locationWithParam(key, value) {
    var url = new URL(window.location.href);
    url.searchParams.set(key, value);
    return url.toString();
  }

  window.locationWithParam = locationWithParam;

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", enhanceCharts);
  } else {
    enhanceCharts();
  }
})();
