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

  function formatLifecycleTime(at) {
    if (at == null || at === "") return "—";
    try {
      var d = new Date(Number(at) * 1000);
      if (isNaN(d.getTime())) return String(at);
      return d.toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
    } catch (e) {
      return String(at);
    }
  }

  function escapeHtml(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function renderLifecycleRows(events) {
    if (!events || events.length === 0) {
      return '<tr><td colspan="6" class="lb-muted">Stream is empty — enqueue a job to see events.</td></tr>';
    }
    // Newest first
    var rows = events.slice().reverse();
    return rows
      .map(function (ev) {
        var detail = ev.error || (ev.delay != null ? "delay=" + ev.delay : "");
        return (
          "<tr>" +
          "<td>" +
          escapeHtml(formatLifecycleTime(ev.at)) +
          "</td>" +
          "<td><code>" +
          escapeHtml(ev.event) +
          "</code></td>" +
          "<td><code>" +
          escapeHtml(ev.job_id) +
          "</code></td>" +
          "<td>" +
          escapeHtml(ev.klass) +
          "</td>" +
          "<td>" +
          escapeHtml(ev.queue) +
          "</td>" +
          '<td class="lb-muted">' +
          escapeHtml(detail) +
          "</td>" +
          "</tr>"
        );
      })
      .join("");
  }

  function pollLifecycle() {
    var card = document.getElementById("lifecycle-card");
    if (!card) return;
    var url = card.getAttribute("data-lifecycle-url");
    var tbody = document.getElementById("lifecycle-tbody");
    var status = document.getElementById("lifecycle-status");
    if (!url || !tbody) return;

    var pollMs = parseInt(card.getAttribute("data-lifecycle-poll") || "5000", 10);
    if (isNaN(pollMs) || pollMs < 2000) pollMs = 5000;

    function tick() {
      fetch(url, { credentials: "same-origin", headers: { Accept: "application/json" } })
        .then(function (r) {
          return r.json();
        })
        .then(function (data) {
          if (!data) return;
          if (data.enabled) {
            tbody.innerHTML = renderLifecycleRows(data.events || []);
            if (status) {
              status.textContent = "live · " + (data.topic || "stream") + " · " + new Date().toLocaleTimeString();
            }
          } else if (status) {
            status.textContent = "inactive" + (data.reason ? " · " + data.reason : "");
          }
        })
        .catch(function () {
          if (status) status.textContent = "poll error";
        });
    }

    // Only auto-poll when the feed was already active on first paint
    // (tbody present means enabled path).
    if (tbody) {
      setInterval(tick, pollMs);
    }
  }

  function boot() {
    enhanceCharts();
    pollLifecycle();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();

