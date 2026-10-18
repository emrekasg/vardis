/* Vardis site. No dependencies, no network, no storage that matters. */
(function () {
  "use strict";
  var doc = document, root = doc.documentElement;
  var mq = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
  var userPaused = false;
  try { userPaused = window.localStorage.getItem("vardis-motion") === "off"; } catch (e) {}
  var listeners = [];
  function motion() { return !mq.matches && !userPaused; }
  // Loops start only after the load event, so they never hold up page load or headless capture.
  var loaded = doc.readyState === "complete";
  function live() { return loaded && motion(); }
  window.addEventListener("load", function () { setTimeout(function () { loaded = true; listeners.forEach(function (fn) { fn(motion()); }); }, 250); });
  function onMotionChange(fn) { listeners.push(fn); }
  function emitMotion() { root.classList.toggle("no-motion", !motion()); listeners.forEach(function (fn) { fn(motion()); }); syncToggles(); }
  if (mq.addEventListener) mq.addEventListener("change", emitMotion);

  function $(s, el) { return (el || doc).querySelector(s); }
  function $$(s, el) { return Array.prototype.slice.call((el || doc).querySelectorAll(s)); }
  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function ease(t) { return t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }
  function fmt(n, d) { return n.toLocaleString("en-US", { minimumFractionDigits: d || 0, maximumFractionDigits: d || 0 }); }
  // Seeded random so the page looks the same on every load.
  var seed = 7;
  function rnd() { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }

  /* ---------- motion toggles ---------- */
  var toggles = $$("[data-motion-toggle]");
  function syncToggles() {
    toggles.forEach(function (b) {
      var off = !motion();
      b.setAttribute("aria-pressed", off ? "true" : "false");
      var label = off ? "Play motion" : "Pause motion";
      var span = $("span", b);
      if (span) span.textContent = label; else b.textContent = label;
      b.setAttribute("aria-label", label.replace("motion", "animations"));
      var use = $("use", b);
      if (use) use.setAttribute("href", off ? "#i-play" : "#i-pause");
      b.hidden = mq.matches && b.classList.contains("motion-btn");
    });
  }
  toggles.forEach(function (b) {
    b.addEventListener("click", function () {
      userPaused = !userPaused;
      try { window.localStorage.setItem("vardis-motion", userPaused ? "off" : "on"); } catch (e) {}
      emitMotion();
    });
  });

  syncToggles();
  root.classList.toggle("no-motion", !motion());

  /* ---------- visibility helper ---------- */
  function watch(el, fn, margin) {
    if (!el) return;
    if (!("IntersectionObserver" in window)) { fn(true); return; }
    new IntersectionObserver(function (es) { es.forEach(function (e) { fn(e.isIntersecting); }); }, { rootMargin: margin || "0px" }).observe(el);
  }

  /* ---------- reveal on scroll (only for things below the fold, so nothing flashes) ---------- */
  var reveals = $$(".reveal");
  if ("IntersectionObserver" in window && motion()) {
    var vh = window.innerHeight;
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { rootMargin: "0px 0px -8% 0px" });
    reveals.forEach(function (el) {
      if (el.getBoundingClientRect().top > vh) { el.classList.add("pending"); io.observe(el); }
      else el.classList.add("in");
    });
  } else reveals.forEach(function (el) { el.classList.add("in"); });

  /* ---------- hero: live tiles ---------- */
  var tileDefs = {
    cpu: { base: 41, vol: 9, min: 4, max: 96, d: 0, fmtTop: function (v) { return Math.max(1, Math.round(v * .52)) + "%"; } },
    mem: { base: 21.4, vol: .25, min: 19, max: 24, d: 1, scale: 36, fmtTop: function (v) { return fmt(v * .32, 1) + " GB"; } },
    gpu: { base: 31, vol: 8, min: 3, max: 90, d: 0, fmtTop: function (v) { return Math.round(v * .45) + "%"; } },
    disk: { base: 6.8, vol: 3, min: .1, max: 40, d: 1, scale: 40, fmtTop: function (v) { return fmt(v * .75, 1) + " MB/s"; } },
    net: { base: 2.4, vol: .9, min: .1, max: 9, d: 1, scale: 9, fmtTop: function (v) { return fmt(v * .8, 1) + " MB/s"; } },
    bat: { base: 84, vol: 0, min: 83, max: 85, d: 0, scale: 12, power: true }
  };
  var tiles = $$("[data-tile]").map(function (el) {
    var def = tileDefs[el.getAttribute("data-tile")], spark = $("[data-spark]", el), bars = [], series = [];
    var n = 30, v = def.base;
    for (var i = 0; i < n; i++) {
      v = clamp(v + (rnd() - .5) * def.vol * 2, def.min, def.max);
      if (def.power) series.push(.35 + rnd() * .4); else series.push(v);
      var b = doc.createElement("i"); spark.appendChild(b); bars.push(b);
    }
    return { el: el, def: def, bars: bars, series: series, val: v, out: $("[data-v]", el), top: $("[data-top]", el), bat: 84 };
  });
  function norm(t, v) { var s = t.def.scale || 100; return clamp(v / s, .04, 1); }
  function paintTile(t) { t.bars.forEach(function (b, i) { b.style.transform = "scaleY(" + (t.def.power ? t.series[i] : norm(t, t.series[i])).toFixed(3) + ")"; }); }
  tiles.forEach(paintTile);
  var ll = $("[data-ll]"), llApp = $("[data-ll-app]"), llVerb = $("[data-ll-verb]"), llNum = $("[data-ll-num]"), llTail = $("[data-ll-tail]");
  var llItems = [
    ["Xcode", "is using", function () { return Math.round(tiles[0].val) + "%"; }, "of the CPU."],
    ["Google Chrome", "is holding", function () { return fmt(6.6 + rnd() * .4, 1) + " GB"; }, "of memory."],
    ["OrbStack", "is writing", function () { return fmt(4.6 + rnd() * 1.2, 1) + " MB/s"; }, "to disk."],
    ["Figma", "is using", function () { return Math.round(12 + rnd() * 5) + "%"; }, "of the GPU."],
    ["Chrome", "is drawing", function () { return fmt(2.8 + rnd() * .6, 1) + " W"; }, "on battery."]
  ], llI = 0;
  function llShow(i) { var it = llItems[i]; llApp.textContent = it[0]; llVerb.textContent = it[1]; llNum.textContent = it[2](); llTail.textContent = it[3]; }
  function llTick() {
    if (!ll) return;
    if (tickN % 4 === 0) { ll.classList.add("out"); setTimeout(function () { llI = (llI + 1) % llItems.length; llShow(llI); ll.classList.remove("out"); }, 360); }
    else llNum.textContent = llItems[llI][2]();
  }
  var mbCpu = $$('[data-mb="cpu"]'), mbMem = $$('[data-mb="mem"]'), mbCl = $$('[data-mb="cl"]');
  var qOut = $("[data-q]"), qBar = $("[data-qbar]"), quota = 62, heroTimer = null, heroVisible = true, tickN = 0;
  function heroTick() {
    tickN++;
    tiles.forEach(function (t) {
      var d = t.def, v;
      if (d.power) { v = .3 + rnd() * .45; t.series.push(v); t.series.shift(); if (tickN % 40 === 0 && t.bat > 60) t.bat--; t.out.textContent = t.bat; if (t.top) t.top.textContent = fmt(2.4 + rnd() * 1.4, 1) + " W"; }
      else {
        var spike = d === tileDefs.cpu && rnd() < .08 ? 40 : 0;
        v = clamp(t.val + (rnd() - .5) * d.vol * 2 + spike, d.min, d.max);
        if (!spike) t.val = v + (d.base - v) * .15;
        t.series.push(v); t.series.shift();
        t.out.textContent = fmt(v, d.d);
        if (t.top && d.fmtTop) t.top.textContent = d.fmtTop(v);
        if (d === tileDefs.cpu) mbCpu.forEach(function (m) { m.textContent = Math.round(v) + "%"; });
        if (d === tileDefs.mem) mbMem.forEach(function (m) { m.textContent = fmt(v, 1) + "G"; });
      }
      paintTile(t);
    });
    if (tickN % 6 === 0 && quota < 70) {
      quota++;
      if (qOut) qOut.textContent = quota;
      if (qBar) qBar.style.transform = "scaleX(" + quota / 100 + ")";
      mbCl.forEach(function (m) { m.textContent = quota + "%"; });
    }
    llTick();
  }
  function heroRun() {
    var go = live() && heroVisible && !doc.hidden;
    if (go && !heroTimer) heroTimer = setInterval(heroTick, 1000);
    if (!go && heroTimer) { clearInterval(heroTimer); heroTimer = null; }
  }
  watch($(".hero-stage"), function (v) { heroVisible = v; heroRun(); });
  doc.addEventListener("visibilitychange", heroRun);
  onMotionChange(heroRun);
  heroRun();

  /* ---------- count-up stats ---------- */
  var counted = false;
  watch($(".strip"), function (v) {
    if (!v || counted || !motion()) return;
    counted = true;
    var els = $$("[data-count]"), t0 = performance.now();
    (function step(now) {
      var p = clamp((now - t0) / 1100, 0, 1), e = 1 - Math.pow(1 - p, 3);
      els.forEach(function (el) { el.textContent = Math.round(+el.getAttribute("data-count") * e); });
      if (p < 1) requestAnimationFrame(step);
    })(t0);
  });

  /* ---------- apps: processes collapse into apps ---------- */
  (function () {
    var cv = $("[data-flow]"); if (!cv) return;
    var ctx = cv.getContext("2d"); if (!ctx) return;
    var apps = [
      { n: "Google Chrome", p: 41, m: "6.8 GB", c: "#1a6dcb", l: "C", w: .2 },
      { n: "Xcode", p: 18, m: "4.1 GB", c: "#111113", l: "X", w: .14 },
      { n: "Docker Desktop", p: 12, m: "2.9 GB", c: "#111113", l: "D", w: .11 },
      { n: "Slack", p: 9, m: "1.2 GB", c: "#111113", l: "S", w: .09 },
      { n: "Figma", p: 7, m: "980 MB", c: "#111113", l: "F", w: .08 },
      { n: "Spotify", p: 6, m: "410 MB", c: "#111113", l: "S", w: .07 },
      { n: "54 more apps", p: 1393, m: "", c: "#9a9ca1", l: "+", w: .31 }
    ];
    var COLS = 38, ROWS = 39, N = 1486, dots = [], W = 600, H = 460, dpr = 1, raf = 0, visible = false, t0 = 0;
    for (var i = 0; i < N; i++) {
      var r = rnd(), acc = 0, a = 0;
      for (var k = 0; k < apps.length; k++) { acc += apps[k].w; if (r <= acc) { a = k; break; } a = k; }
      dots.push({ a: a, col: i % COLS, row: Math.floor(i / COLS), delay: rnd() * 1.8, tw: rnd() * 6.28 });
    }
    function size() {
      var rect = cv.getBoundingClientRect(); if (!rect.width) return;
      dpr = Math.min(window.devicePixelRatio || 1, 2); W = rect.width; H = rect.width * 460 / 600;
      cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    function layout() {
      var gx = 6, gw = W * .38, gy = 8, gh = H - 16;
      var rx = W * .5, rowH = (H - 16) / apps.length;
      return { gx: gx, sx: gw / COLS, gy: gy, sy: gh / ROWS, rx: rx, rowH: rowH, top: 8 };
    }
    function rr(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }
    var font = '-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif';
    function draw(t) {
      var L = layout(), small = W < 480;
      ctx.clearRect(0, 0, W, H);
      // Cycle: 0-1.2 idle, 1.2-5 flow, 5-8 hold, 8-9 fade back.
      var cyc = 9.2, s = t % cyc, filled = apps.map(function () { return 0; });
      var dot = Math.max(1.1, L.sx * .26);
      for (var i = 0; i < dots.length; i++) {
        var d = dots[i], ax = L.gx + d.col * L.sx + L.sx / 2, ay = L.gy + d.row * L.sy + L.sy / 2;
        var tyRow = L.top + d.a * L.rowH + L.rowH / 2, tx = L.rx - 4;
        var p = clamp((s - 1.2 - d.delay) / 1.4, 0, 1), alpha;
        if (s > 8.2) { p = 0; alpha = clamp((s - 8.2) / 1, 0, 1) * (d.a === 0 ? .75 : .3); }
        else if (p >= 1) { filled[d.a]++; ctx.globalAlpha = .07; ctx.fillStyle = "#111113"; ctx.fillRect(ax - dot / 2, ay - dot / 2, dot, dot); continue; }
        else alpha = (d.a === 0 ? .75 : .3) + .12 * Math.sin(t * 2 + d.tw);
        ctx.globalAlpha = .07; ctx.fillStyle = "#111113"; ctx.fillRect(ax - dot / 2, ay - dot / 2, dot, dot);
        var e = ease(p), x, y;
        if (p > 0) {
          var mx = (ax + tx) / 2;
          // cubic bezier: start, (mx, ay), (mx, ty), end
          var u = 1 - e; x = u * u * u * ax + 3 * u * u * e * mx + 3 * u * e * e * mx + e * e * e * tx; y = u * u * u * ay + 3 * u * u * e * ay + 3 * u * e * e * tyRow + e * e * e * tyRow;
          alpha = .9;
        } else { x = ax; y = ay; }
        ctx.globalAlpha = alpha; ctx.fillStyle = apps[d.a].c; ctx.fillRect(x - dot / 2, y - dot / 2, dot, dot);
      }
      ctx.globalAlpha = 1;
      var counts = apps.map(function (a, k) { return s > 8.2 ? 0 : filled[k]; });
      var totalByApp = dots.reduce(function (acc, d) { acc[d.a]++; return acc; }, apps.map(function () { return 0; }));
      for (var k = 0; k < apps.length; k++) {
        var a = apps[k], cy = L.top + k * L.rowH + L.rowH / 2, frac = totalByApp[k] ? counts[k] / totalByApp[k] : 0;
        if (s <= 1.2 || s > 8.2) frac = s > 8.2 ? 1 - clamp((s - 8.2) / .8, 0, 1) : 0;
        var x0 = L.rx, rw = W - L.rx - 4, rh = L.rowH - 8;
        ctx.globalAlpha = .5 + .5 * frac; ctx.fillStyle = "#f3f2ee"; rr(x0, cy - rh / 2, rw, rh, 10); ctx.fill();
        ctx.globalAlpha = .3 + .7 * frac;
        var isz = small ? 18 : 22; ctx.fillStyle = a.c; rr(x0 + 10, cy - isz / 2, isz, isz, 5); ctx.fill();
        ctx.fillStyle = "#fff"; ctx.font = "700 " + (small ? 10 : 12) + "px " + font; ctx.textAlign = "center"; ctx.textBaseline = "middle"; ctx.fillText(a.l, x0 + 10 + isz / 2, cy + .5);
        ctx.textAlign = "left"; ctx.fillStyle = "#111113"; ctx.font = "600 " + (small ? 11.5 : 14) + "px " + font; ctx.fillText(a.n, x0 + isz + 20, cy - (small ? 6 : 7));
        ctx.fillStyle = "#696c73"; ctx.font = "400 " + (small ? 10 : 12) + "px " + font;
        var shown = Math.round(a.p * frac);
        ctx.fillText(k === apps.length - 1 ? "the rest of the Mac" : shown + (shown === 1 ? " process" : " processes"), x0 + isz + 20, cy + (small ? 7 : 9));
        if (a.m && !small) { ctx.textAlign = "right"; ctx.fillStyle = "#111113"; ctx.font = "600 13px " + font; ctx.fillText(a.m, x0 + rw - 12, cy); }
      }
      ctx.globalAlpha = 1;
    }
    function frame(now) { draw((now - t0) / 1000); raf = requestAnimationFrame(frame); }
    function run() {
      var go = visible && live() && !doc.hidden;
      if (go && !raf) { t0 = performance.now(); raf = requestAnimationFrame(frame); }
      if (!go && raf) { cancelAnimationFrame(raf); raf = 0; }
      if (!go) draw(6.5);
    }
    size(); draw(6.5);
    window.addEventListener("resize", function () { size(); if (!raf) draw(6.5); });
    watch(cv, function (v) { visible = v; run(); }, "100px");
    doc.addEventListener("visibilitychange", run);
    onMotionChange(run);
  })();

  /* ---------- black box timeline ---------- */
  (function () {
    var tl = $("[data-tl]"); if (!tl) return;
    var M = 1439, STEP = 10;
    function bell(t, c, w, h) { var x = (t - c) / w; return h * Math.exp(-x * x); }
    function xcode(t) { return (t > 600 && t < 760 ? 22 + 6 * Math.sin(t / 9) : 0) + bell(t, 872, 14, 66) + (t > 960 && t < 1090 ? 14 + 5 * Math.sin(t / 7) : 0); }
    function chrome(t) { return t < 480 ? 1 : 9 + 6 * Math.sin(t / 50) + bell(t, 1150, 30, 10) + (t > 1380 ? -6 : 0); }
    function other(t) { var night = t < 420 || t > 1400; return (night ? 3 : 8) + 2 * Math.sin(t / 31) + bell(t, 120, 60, 3); }
    var pts = [];
    for (var t = 0; t <= M; t += STEP) pts.push([t, other(t), chrome(t), xcode(t)]);
    function Y(v) { return 226 - v * 2.05; }
    function X(t) { return t / M * 1000; }
    function smooth(arr) {
      var d = "M" + arr[0][0].toFixed(1) + " " + arr[0][1].toFixed(1);
      for (var i = 0; i < arr.length - 1; i++) {
        var p0 = arr[i - 1] || arr[i], p1 = arr[i], p2 = arr[i + 1], p3 = arr[i + 2] || p2;
        d += " C" + (p1[0] + (p2[0] - p0[0]) / 6).toFixed(1) + " " + (p1[1] + (p2[1] - p0[1]) / 6).toFixed(1) + " " + (p2[0] - (p3[0] - p1[0]) / 6).toFixed(1) + " " + (p2[1] - (p3[1] - p1[1]) / 6).toFixed(1) + " " + p2[0].toFixed(1) + " " + p2[1].toFixed(1);
      }
      return d;
    }
    function area(fn) { var line = pts.map(function (p) { return [X(p[0]), Y(fn(p))]; }); return smooth(line) + " L1000 226 L0 226 Z"; }
    $('[data-area="else"]', tl).setAttribute("d", area(function (p) { return p[1]; }));
    $('[data-area="chrome"]', tl).setAttribute("d", area(function (p) { return p[1] + p[2]; }));
    $('[data-area="xcode"]', tl).setAttribute("d", area(function (p) { return p[1] + p[2] + p[3]; }));
    var evAt = [100, 610, 870, 1140, 1275], evWrap = $("[data-events]", tl);
    var evEls = evAt.map(function (m) { var i = doc.createElement("i"); i.style.left = (m / M * 100) + "%"; evWrap.appendChild(i); return i; });
    var head = $("[data-head]", tl), tip = $("[data-tip]", tl), tipT = $("[data-tip-t]", tl), tipX = $("[data-tip-x]", tl);
    var stood = $$("[data-stood] li"), whyT = $("[data-why-t]"), whyLine = $("[data-why-line]"), whyApps = $("[data-why-apps]");
    var width = tl.clientWidth, cur = -1;
    function hhmm(m) { m = Math.round(m); var h = Math.floor(m / 60), mm = m % 60; return (h < 10 ? "0" : "") + h + ":" + (mm < 10 ? "0" : "") + mm; }
    function describe(m) {
      var x = xcode(m), c = chrome(m), o = other(m), cpu = Math.round(x + c + o);
      var memShort = (m > 1135 && m < 1160) || (m > 1265 && m < 1290);
      var awake = m > 100 && m < 188;
      var tip, line;
      if (x > 45) { tip = "Xcode build, CPU " + cpu + "%"; line = "Your Mac slowed down because Xcode was building and the CPU was busy."; }
      else if (memShort) { tip = "Memory ran short"; line = "Your Mac slowed down because memory ran out. Chrome held 14 GB."; }
      else if (awake) { tip = "Kept awake by WhatsApp"; line = "The Mac should have slept. WhatsApp asked macOS to stay awake."; }
      else if (cpu < 14) { tip = "Quiet, CPU " + cpu + "%"; line = "Nothing unusual. The Mac was mostly idle."; }
      else { var top = x > c ? "Xcode" : "Chrome"; tip = top + " busiest, CPU " + cpu + "%"; line = "Running normally. " + top + " did most of the work."; }
      var list = [["Xcode", x], ["Google Chrome", c], ["Everything else", o]].sort(function (a, b) { return b[1] - a[1]; });
      return { tip: tip, line: line, list: list };
    }
    function set(m) {
      m = clamp(m, 0, M);
      head.style.transform = "translateX(" + (m / M * width).toFixed(1) + "px)";
      tip.classList.toggle("flip", m / M * width + 14 + (tip.offsetWidth || 180) > width);
      var r = Math.round(m / STEP) * STEP;
      if (r === cur) return; cur = r;
      var info = describe(r), t = hhmm(r);
      tipT.textContent = t; tipX.textContent = info.tip;
      tl.setAttribute("aria-valuenow", r); tl.setAttribute("aria-valuetext", t + ", " + info.tip);
      whyT.textContent = t; whyLine.textContent = info.line;
      whyApps.innerHTML = "";
      info.list.forEach(function (a) { var li = doc.createElement("li"); var s = doc.createElement("span"); s.textContent = a[0]; var b = doc.createElement("b"); b.textContent = Math.max(0, Math.round(a[1])) + "%"; li.appendChild(s); li.appendChild(b); whyApps.appendChild(li); });
      evEls.forEach(function (e, i) { e.classList.toggle("hit", Math.abs(evAt[i] - r) <= 40); });
      stood.forEach(function (li) { li.classList.toggle("on", Math.abs(+li.getAttribute("data-at") - r) <= 60); });
    }
    var pos = 870; set(pos);
    window.addEventListener("resize", function () { width = tl.clientWidth; cur = -1; set(pos); });
    // Autoplay: sweep, hold on the spike, sweep, rewind.
    var plan = [{ to: 870, d: 7000 }, { hold: 2600 }, { to: M, d: 5200 }, { hold: 1200 }, { to: 0, d: 1400 }, { hold: 600 }];
    var step = 0, stepStart = 0, from = 0, raf = 0, visible = false, userUntil = 0;
    function frame(now) {
      raf = requestAnimationFrame(frame);
      if (now < userUntil) return;
      var s = plan[step], el = now - stepStart;
      if (s.hold !== undefined) { if (el >= s.hold) { step = (step + 1) % plan.length; stepStart = now; from = pos; } return; }
      var p = clamp(el / s.d, 0, 1); pos = from + (s.to - from) * ease(p); set(pos);
      if (p >= 1) { step = (step + 1) % plan.length; stepStart = now; from = pos; }
    }
    function run() {
      var go = visible && live() && !doc.hidden;
      if (go && !raf) { pos = 0; from = 0; step = 0; stepStart = performance.now(); raf = requestAnimationFrame(frame); }
      if (!go && raf) { cancelAnimationFrame(raf); raf = 0; pos = 870; set(pos); }
    }
    function user(m) {
      userUntil = performance.now() + 8000; pos = clamp(m, 0, M); set(pos);
      var i = plan.findIndex(function (p) { return p.to !== undefined && p.to > pos; });
      step = i < 0 ? 4 : i; from = pos; stepStart = userUntil;
    }
    function fromEvent(e) { var r = tl.getBoundingClientRect(); return (e.clientX - r.left) / r.width * M; }
    var dragging = false;
    tl.addEventListener("pointerdown", function (e) { dragging = true; tl.setPointerCapture && tl.setPointerCapture(e.pointerId); user(fromEvent(e)); });
    tl.addEventListener("pointermove", function (e) { if (dragging || e.pointerType === "mouse") user(fromEvent(e)); });
    tl.addEventListener("pointerup", function () { dragging = false; });
    tl.addEventListener("pointercancel", function () { dragging = false; });
    tl.addEventListener("keydown", function (e) {
      var k = e.key, d = 0;
      if (k === "ArrowRight" || k === "ArrowUp") d = STEP; else if (k === "ArrowLeft" || k === "ArrowDown") d = -STEP;
      else if (k === "PageUp") d = 60; else if (k === "PageDown") d = -60;
      else if (k === "Home") { e.preventDefault(); user(0); return; } else if (k === "End") { e.preventDefault(); user(M); return; }
      if (d) { e.preventDefault(); user(Math.round(pos / STEP) * STEP + d); }
    });
    watch(tl, function (v) { visible = v; run(); });
    doc.addEventListener("visibilitychange", run);
    onMotionChange(run);
  })();

  /* ---------- disk cleanup ---------- */
  (function () {
    var cu = $("[data-cu]"); if (!cu) return;
    var items = $$(".cu-list li[data-gb]", cu), total = $("[data-cu-total]", cu), sel = $("[data-cu-sel]", cu);
    var go = $("[data-cu-go]", cu), toast = $("[data-toast]", cu), undo = $("b", toast), trash = $("[data-cu-trash]", cu);
    var timers = [], visible = false, running = false, shown = 0;
    function later(ms, fn) { timers.push(setTimeout(fn, ms)); }
    function clear() { timers.forEach(clearTimeout); timers = []; }
    function setTotal(v) { shown = v; total.textContent = fmt(v, 1); sel.style.transform = "scaleX(" + (v / 23.4).toFixed(3) + ")"; go.textContent = v ? "Move " + fmt(v, 1) + " GB to Trash" : "Move to Trash"; }
    function tween(to, ms) {
      var a = shown, t0 = performance.now();
      (function s(now) { var p = clamp((now - t0) / ms, 0, 1); setTotal(a + (to - a) * ease(p)); if (p < 1 && running) requestAnimationFrame(s); })(t0);
    }
    function finalState() { items.forEach(function (li) { li.classList.add("sel"); li.classList.remove("gone"); }); setTotal(23.4); toast.classList.remove("show"); }
    function cycle() {
      if (!running) return;
      items.forEach(function (li) { li.classList.remove("sel", "gone"); }); toast.classList.remove("show"); setTotal(0);
      var t = 700, sum = 0;
      items.forEach(function (li) { later(t, function () { li.classList.add("sel"); sum += +li.getAttribute("data-gb"); tween(sum, 380); }); t += 520; });
      t += 500; later(t, function () { go.classList.add("press"); }); later(t + 160, function () { go.classList.remove("press"); });
      t += 260; items.forEach(function (li, i) { later(t + i * 110, function () { li.classList.add("gone"); }); });
      later(t + 450, function () { trash.classList.add("gulp"); }); later(t + 900, function () { trash.classList.remove("gulp"); });
      t += 900; later(t, function () { toast.classList.add("show"); });
      t += 1900; later(t, function () { undo.classList.add("press"); }); later(t + 200, function () { undo.classList.remove("press"); toast.classList.remove("show"); items.forEach(function (li, i) { later(i * 90, function () { li.classList.remove("gone"); }); }); });
      t += 2600; later(t, cycle);
    }
    function run() {
      var should = visible && live() && !doc.hidden;
      if (should && !running) { running = true; cycle(); }
      if (!should && running) { running = false; clear(); finalState(); }
    }
    finalState();
    watch(cu, function (v) { visible = v; run(); });
    doc.addEventListener("visibilitychange", run);
    onMotionChange(run);
  })();

  /* ---------- Claude Code tabs ---------- */
  (function () {
    var cc = $("[data-cc]"); if (!cc) return;
    var tabs = $$("[data-cc-tab]", cc), panels = $$("[data-cc-panel]", cc), DUR = 8000;
    var idx = 0, autoTimer = 0, auto = true, visible = false, timers = [];
    function later(ms, fn) { timers.push(setTimeout(fn, ms)); }
    function clearT() { timers.forEach(clearTimeout); timers = []; }
    var scenes = [sceneSessions, sceneUsage, sceneLive, sceneAccounts];
    function select(i, fromUser) {
      idx = i; clearT();
      tabs.forEach(function (t, k) {
        var on = k === i; t.setAttribute("aria-selected", on ? "true" : "false"); t.tabIndex = on ? 0 : -1;
        var bar = $(".cc-prog", t); bar.style.transition = "none"; bar.style.transform = "scaleX(0)";
      });
      panels.forEach(function (p, k) { p.hidden = k !== i; });
      if (fromUser) { auto = false; tabs[i].focus(); }
      scenes[i](live() && visible);
      schedule();
    }
    function schedule() {
      clearTimeout(autoTimer);
      if (!auto || !live() || !visible || doc.hidden) return;
      var bar = $(".cc-prog", tabs[idx]);
      void bar.offsetWidth;
      bar.style.transition = "transform " + DUR + "ms linear"; bar.style.transform = "scaleX(1)";
      autoTimer = setTimeout(function () { select((idx + 1) % tabs.length); }, DUR);
    }
    tabs.forEach(function (t, i) {
      t.addEventListener("click", function () { select(i, true); });
      t.addEventListener("keydown", function (e) {
        var k = e.key, n = tabs.length, j = -1;
        if (k === "ArrowRight" || k === "ArrowDown") j = (i + 1) % n; else if (k === "ArrowLeft" || k === "ArrowUp") j = (i - 1 + n) % n; else if (k === "Home") j = 0; else if (k === "End") j = n - 1;
        if (j >= 0) { e.preventDefault(); select(j, true); }
      });
    });
    doc.addEventListener("visibilitychange", function () { if (doc.hidden) clearTimeout(autoTimer); else schedule(); });
    watch(cc, function (v) { var was = visible; visible = v; if (v && !was) select(idx); if (!v) { clearTimeout(autoTimer); clearT(); } });
    onMotionChange(function () { select(idx); });

    function sceneSessions(anim) {
      var p = panels[0], typed = $("[data-typed]", p), lis = $$("[data-ss] li", p), res = $("[data-resume]", p), word = "flaky";
      function done() { typed.textContent = word; lis.forEach(function (li, k) { li.classList.toggle("dim", li.getAttribute("data-k") !== "flaky"); li.classList.toggle("pick", k === 0); }); res.classList.add("show"); }
      if (!anim) return done();
      typed.textContent = ""; res.classList.remove("show"); lis.forEach(function (li) { li.classList.remove("dim", "pick"); });
      word.split("").forEach(function (ch, k) { later(500 + k * 140, function () { typed.textContent = word.slice(0, k + 1); }); });
      later(1400, function () { lis.forEach(function (li) { li.classList.toggle("dim", li.getAttribute("data-k") !== "flaky"); }); });
      later(2300, function () { lis[0].classList.add("pick"); });
      later(2900, function () { res.classList.add("show"); });
    }
    var usBars = $("[data-usbars]", cc), usVals = [];
    if (usBars) { for (var d = 0; d < 31; d++) { var v = d < 18 ? .15 + rnd() * .85 : 0; if (d === 9) v = 1; usVals.push(v); usBars.appendChild(doc.createElement("i")); } }
    function sceneUsage(anim) {
      var p = panels[1], bars = $$("i", usBars), usd = $("[data-usd]", p);
      p.classList.remove("on-stage");
      bars.forEach(function (b, k) { b.style.transition = anim ? "transform .7s cubic-bezier(.2,.7,.2,1) " + (k * 30) + "ms" : "none"; b.style.transform = "scaleY(" + (anim ? 0 : usVals[k] || .015) + ")"; });
      if (!anim) { usd.textContent = "1,284"; p.classList.add("on-stage"); return; }
      later(60, function () { bars.forEach(function (b, k) { b.style.transform = "scaleY(" + (usVals[k] || .015) + ")"; }); p.classList.add("on-stage"); });
      var t0 = performance.now();
      (function s(now) { var q = clamp((now - t0) / 1400, 0, 1); usd.textContent = fmt(1284 * ease(q)); if (q < 1) requestAnimationFrame(s); })(t0);
    }
    function sceneLive(anim) {
      var p = panels[2], ctxs = $$("[data-ctx]", p), vals = $$("[data-ctxv]", p), tool = $("[data-tool]", p), kids = $("[data-kids]", p);
      var base = ctxs.map(function (c) { return +c.getAttribute("data-ctx"); });
      ctxs.forEach(function (c, k) { c.style.transform = "scaleX(" + (anim ? 0 : base[k] / 100) + ")"; vals[k].textContent = base[k] + "%"; });
      if (!anim) return;
      later(80, function () { ctxs.forEach(function (c, k) { c.style.transform = "scaleX(" + base[k] / 100 + ")"; }); });
      var steps = [["Reading checkout.test.ts", "node"], ["Editing cart.ts", "node"], ["Running tests", "node, vitest"], ["Running tests", "node, vitest, chrome"]];
      steps.forEach(function (s, k) {
        later(1500 + k * 1500, function () {
          tool.textContent = s[0]; kids.textContent = s[1];
          var v = base[0] + (k + 1) * 2; ctxs[0].style.transform = "scaleX(" + v / 100 + ")"; vals[0].textContent = v + "%";
        });
      });
    }
    function sceneAccounts(anim) {
      var p = panels[3], lis = $$("[data-acc]", p), bars = $$("[data-acbar]", p), vals = $$("[data-acv]", p), note = $("[data-acnote]", p);
      var start = [62, 12, 4];
      function setA(k, v) { bars[k].style.transform = "scaleX(" + v / 100 + ")"; vals[k].textContent = Math.round(v) + "%"; bars[k].classList.toggle("hot", v >= 90); }
      function active(k) { lis.forEach(function (li, j) { li.classList.toggle("active", j === k); }); }
      if (!anim) { setA(0, 90); setA(1, 14); setA(2, 4); active(1); note.textContent = "Personal reached 90%. New sessions now start on Work."; note.classList.add("hl"); return; }
      start.forEach(function (v, k) { setA(k, v); }); active(0); note.textContent = "New sessions start on the active account."; note.classList.remove("hl");
      var t0 = performance.now() + 700;
      function rise(now) {
        if (!visible || idx !== 3) return;
        var q = clamp((now - t0) / 3200, 0, 1); setA(0, 62 + 28 * q);
        if (q < 1) requestAnimationFrame(rise);
        else {
          active(1); note.textContent = "Personal reached 90%. New sessions now start on Work."; note.classList.add("hl");
          later(900, function () { setA(1, 13); }); later(1900, function () { setA(1, 14); });
        }
      }
      requestAnimationFrame(rise);
    }
    // Initial static paint for no-visibility state.
    scenes.forEach(function (s, k) { if (k !== 0) s(false); });
    sceneSessions(false);
  })();
})();
