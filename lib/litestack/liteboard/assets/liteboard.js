/* Liteboard progressive enhancement — local SVG charts, no eval, no remote deps */
(function () {
  "use strict";

  var COLORS = ["#078", "#e67e22", "#8e44ad", "#27ae60", "#c0392b", "#2980b9"];

  function parseJson(text) {
    if (text == null) return null;
    var raw = String(text).trim();
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch (e) {
      // Ruby Array#inspect is close to JSON for simple string/number rows
      try {
        return JSON.parse(
          raw
            .replace(/=>/g, ":")
            .replace(/\bnil\b/g, "null")
            .replace(/:([a-zA-Z_][a-zA-Z0-9_]*)/g, '"$1"')
        );
      } catch (e2) {
        return null;
      }
    }
  }

  function isTooltipHeader(cell) {
    return cell && typeof cell === "object" && !Array.isArray(cell) && (cell.role === "tooltip" || cell["role"] === "tooltip");
  }

  /** Google-Charts-style rows: first row headers, rest data. Tooltip columns skipped. */
  function parseSeriesTable(raw) {
    if (!raw || !Array.isArray(raw) || raw.length === 0) return null;
    var header = raw[0];
    if (!Array.isArray(header)) {
      // [[t, v], ...] without header
      return {
        labels: raw.map(function (r, i) {
          return Array.isArray(r) ? String(r[0]) : String(i);
        }),
        series: [
          {
            name: "value",
            values: raw.map(function (r) {
              return Array.isArray(r) ? Number(r[1]) || 0 : Number(r) || 0;
            })
          }
        ]
      };
    }

    var colMeta = [];
    for (var c = 0; c < header.length; c++) {
      if (c === 0) {
        colMeta.push({ type: "label" });
      } else if (isTooltipHeader(header[c])) {
        colMeta.push({ type: "skip" });
      } else if (typeof header[c] === "object" && header[c] !== null) {
        colMeta.push({ type: "skip" });
      } else {
        colMeta.push({ type: "series", name: String(header[c]) });
      }
    }

    var labels = [];
    var series = colMeta
      .map(function (m, idx) {
        if (m.type !== "series") return null;
        return { name: m.name, col: idx, values: [] };
      })
      .filter(Boolean);

    for (var r = 1; r < raw.length; r++) {
      var row = raw[r];
      if (!Array.isArray(row)) continue;
      labels.push(row[0] == null ? String(r) : String(row[0]));
      series.forEach(function (s) {
        var v = row[s.col];
        s.values.push(typeof v === "number" ? v : Number(v) || 0);
      });
    }

    return { labels: labels, series: series };
  }

  function parsePieTable(raw) {
    if (!raw || !Array.isArray(raw) || raw.length === 0) return null;
    var start = 0;
    if (Array.isArray(raw[0]) && (raw[0][0] === "name" || raw[0][0] === "Name")) {
      start = 1;
    }
    var items = [];
    for (var i = start; i < raw.length; i++) {
      var row = raw[i];
      if (!Array.isArray(row) || row.length < 2) continue;
      items.push({ name: String(row[0]), value: Number(row[1]) || 0 });
    }
    return items;
  }

  function svgEl(name, attrs) {
    var el = document.createElementNS("http://www.w3.org/2000/svg", name);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        el.setAttribute(k, attrs[k]);
      });
    }
    return el;
  }

  function maxOf(series) {
    var m = 0;
    series.forEach(function (s) {
      s.values.forEach(function (v) {
        if (v > m) m = v;
      });
    });
    return m > 0 ? m : 1;
  }

  function buildLegend(series) {
    var wrap = document.createElement("div");
    wrap.className = "lb-chart-legend";
    series.forEach(function (s, i) {
      var item = document.createElement("span");
      item.className = "lb-chart-legend-item";
      var sw = document.createElement("span");
      sw.className = "lb-chart-swatch";
      sw.style.background = COLORS[i % COLORS.length];
      item.appendChild(sw);
      item.appendChild(document.createTextNode(s.name));
      wrap.appendChild(item);
    });
    return wrap;
  }

  function renderLineChart(parsed, opts) {
    opts = opts || {};
    var w = opts.width || 480;
    var h = opts.height || 180;
    var padL = 40;
    var padR = 12;
    var padT = 12;
    var padB = 28;
    var iw = w - padL - padR;
    var ih = h - padT - padB;
    var n = parsed.labels.length;
    if (n === 0) return emptyNote("No time-series points yet");

    var max = maxOf(parsed.series);
    var host = document.createElement("div");
    host.className = "lb-chart-wrap";

    var svg = svgEl("svg", {
      viewBox: "0 0 " + w + " " + h,
      width: "100%",
      height: String(h),
      class: "lb-chart-svg",
      role: "img",
      "aria-label": opts.label || "Line chart"
    });

    // grid
    for (var g = 0; g <= 4; g++) {
      var gy = padT + (ih * g) / 4;
      svg.appendChild(
        svgEl("line", {
          x1: padL,
          y1: gy,
          x2: padL + iw,
          y2: gy,
          class: "lb-chart-grid"
        })
      );
      var val = max * (1 - g / 4);
      var t = svgEl("text", {
        x: padL - 6,
        y: gy + 3,
        class: "lb-chart-axis",
        "text-anchor": "end"
      });
      t.textContent = formatTick(val);
      svg.appendChild(t);
    }

    parsed.series.forEach(function (s, si) {
      var color = COLORS[si % COLORS.length];
      var pts = [];
      for (var i = 0; i < s.values.length; i++) {
        var x = padL + (n === 1 ? iw / 2 : (iw * i) / (n - 1));
        var y = padT + ih - (s.values[i] / max) * ih;
        pts.push(x + "," + y);
      }
      if (pts.length > 1) {
        svg.appendChild(
          svgEl("polyline", {
            points: pts.join(" "),
            fill: "none",
            stroke: color,
            "stroke-width": "2",
            "stroke-linejoin": "round",
            "stroke-linecap": "round",
            class: "lb-chart-line"
          })
        );
      }
      // points
      for (var j = 0; j < s.values.length; j++) {
        var px = padL + (n === 1 ? iw / 2 : (iw * j) / (n - 1));
        var py = padT + ih - (s.values[j] / max) * ih;
        var c = svgEl("circle", {
          cx: px,
          cy: py,
          r: n > 40 ? "1.5" : "3",
          fill: color
        });
        var title = document.createElementNS("http://www.w3.org/2000/svg", "title");
        title.textContent = s.name + " @ " + parsed.labels[j] + ": " + s.values[j];
        c.appendChild(title);
        svg.appendChild(c);
      }
    });

    // x labels (sparse)
    var step = Math.max(1, Math.ceil(n / 6));
    for (var li = 0; li < n; li += step) {
      var lx = padL + (n === 1 ? iw / 2 : (iw * li) / (n - 1));
      var lt = svgEl("text", {
        x: lx,
        y: h - 8,
        class: "lb-chart-axis",
        "text-anchor": "middle"
      });
      lt.textContent = shortLabel(parsed.labels[li]);
      svg.appendChild(lt);
    }

    host.appendChild(svg);
    if (parsed.series.length > 1) host.appendChild(buildLegend(parsed.series));
    return host;
  }

  function renderBarChart(items, opts) {
    opts = opts || {};
    if (!items || items.length === 0) return emptyNote("No breakdown data yet");
    var total = items.reduce(function (a, b) {
      return a + (b.value > 0 ? b.value : 0);
    }, 0);
    if (total <= 0) total = 1;

    var w = opts.width || 320;
    var rowH = 28;
    var h = Math.max(80, items.length * rowH + 16);
    var padL = 8;
    var padR = 8;
    var barMax = w - padL - padR - 100;

    var host = document.createElement("div");
    host.className = "lb-chart-wrap";

    var svg = svgEl("svg", {
      viewBox: "0 0 " + w + " " + h,
      width: "100%",
      height: String(h),
      class: "lb-chart-svg",
      role: "img",
      "aria-label": opts.label || "Bar chart"
    });

    items.forEach(function (item, i) {
      var y = 8 + i * rowH;
      var bw = Math.max(2, (Math.max(0, item.value) / total) * barMax);
      var color = COLORS[i % COLORS.length];

      var label = svgEl("text", {
        x: padL,
        y: y + 14,
        class: "lb-chart-bar-label"
      });
      label.textContent = item.name;
      svg.appendChild(label);

      svg.appendChild(
        svgEl("rect", {
          x: padL + 90,
          y: y + 2,
          width: bw,
          height: 16,
          rx: "3",
          fill: color,
          class: "lb-chart-bar"
        })
      );

      var pct = ((item.value / total) * 100).toFixed(0);
      var val = svgEl("text", {
        x: padL + 94 + bw,
        y: y + 14,
        class: "lb-chart-axis"
      });
      val.textContent = formatTick(item.value) + " (" + pct + "%)";
      svg.appendChild(val);
    });

    host.appendChild(svg);
    return host;
  }

  function renderSparkline(points) {
    // points: [[t, v], ...] or numbers
    var values = points.map(function (p) {
      return Array.isArray(p) ? Number(p[1]) || 0 : Number(p) || 0;
    });
    var labels = points.map(function (p, i) {
      return Array.isArray(p) ? String(p[0]) : String(i);
    });
    return renderLineChart(
      {
        labels: labels,
        series: [{ name: "count", values: values }]
      },
      { height: 72, width: 280, label: "Activity sparkline" }
    );
  }

  function emptyNote(msg) {
    var p = document.createElement("p");
    p.className = "lb-muted lb-chart-empty";
    p.textContent = msg;
    return p;
  }

  function formatTick(v) {
    if (v >= 1e6) return (v / 1e6).toFixed(1) + "M";
    if (v >= 1e3) return (v / 1e3).toFixed(1) + "k";
    if (Math.abs(v) < 0.01 && v !== 0) return v.toExponential(1);
    if (Number.isInteger(v)) return String(v);
    return v.toFixed(2);
  }

  function shortLabel(s) {
    s = String(s);
    if (s.length <= 10) return s;
    // epoch seconds
    var n = Number(s);
    if (!isNaN(n) && n > 1e9) {
      try {
        return new Date(n * 1000).toISOString().slice(11, 16);
      } catch (e) {
        /* fallthrough */
      }
    }
    return s.slice(0, 8) + "…";
  }

  function replaceWithChart(el, chartNode) {
    el.classList.remove("hidden");
    el.classList.add("lb-chart-host");
    el.setAttribute("data-enhanced", "true");
    // Keep raw data in a script-friendly place for debugging
    var raw = el.textContent;
    el.textContent = "";
    el.appendChild(chartNode);
    if (raw && raw.length < 2000) {
      el.setAttribute("data-raw-len", String(raw.length));
    }
  }

  function chartPayload(el) {
    var attr = el.getAttribute("data-chart-json");
    if (attr != null && attr !== "") return parseJson(attr);
    return parseJson(el.textContent);
  }

  function enhanceLegacyCharts() {
    document.querySelectorAll(".inlinecolumn, .inlinestackedcolumn").forEach(function (el) {
      if (el.getAttribute("data-enhanced")) return;
      var raw = chartPayload(el);
      var parsed = parseSeriesTable(raw);
      if (!parsed || !parsed.series.length) {
        el.classList.remove("hidden");
        el.classList.add("lb-chart-host");
        el.setAttribute("data-enhanced", "true");
        el.textContent = "";
        el.appendChild(emptyNote("No series data yet"));
        return;
      }
      replaceWithChart(el, renderLineChart(parsed, { label: el.getAttribute("data-label") || "Time series" }));
    });

    document.querySelectorAll(".inlinepie").forEach(function (el) {
      if (el.getAttribute("data-enhanced")) return;
      var raw = chartPayload(el);
      var items = parsePieTable(raw);
      if (!items || !items.length) {
        el.classList.remove("hidden");
        el.classList.add("lb-chart-host");
        el.setAttribute("data-enhanced", "true");
        el.textContent = "";
        el.appendChild(emptyNote("No breakdown data yet"));
        return;
      }
      replaceWithChart(el, renderBarChart(items, { label: el.getAttribute("data-label") || "Breakdown" }));
    });
  }

  function enhanceDataCharts() {
    document.querySelectorAll("[data-chart]").forEach(function (node) {
      if (node.getAttribute("data-enhanced") === "svg") return;
      var rawAttr = node.getAttribute("data-chart");
      var data = null;
      try {
        data = JSON.parse(rawAttr);
      } catch (e) {
        data = parseJson(rawAttr);
      }
      if (!data || !Array.isArray(data) || data.length === 0) return;

      var spark = renderSparkline(data);
      spark.classList.add("lb-sparkline");
      if (!node.querySelector(".lb-sparkline, .lb-chart-wrap")) {
        node.insertBefore(spark, node.firstChild);
      }
      node.setAttribute("data-enhanced", "svg");
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
              status.textContent =
                "live · " + (data.topic || "stream") + " · " + new Date().toLocaleTimeString();
            }
          } else if (status) {
            status.textContent = "inactive" + (data.reason ? " · " + data.reason : "");
          }
        })
        .catch(function () {
          if (status) status.textContent = "poll error";
        });
    }

    if (tbody) {
      setInterval(tick, pollMs);
    }
  }

  function boot() {
    enhanceLegacyCharts();
    enhanceDataCharts();
    pollLifecycle();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
