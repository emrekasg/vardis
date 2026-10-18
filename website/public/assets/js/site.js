/* Live numbers in the product picture. Fictional data; starts after load; stops when hidden or off screen. */
(function () {
  "use strict";
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var seed = 7;
  function rnd() { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }
  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function fmt(n, d) { return n.toFixed(d); }
  var defs = {
    cpu: { base: 24, vol: 8, min: 3, max: 90, d: 0, s: 100, top: function (v) { return Math.round(v * .5) + "%"; } },
    mem: { base: 21.4, vol: .25, min: 20, max: 23, d: 1, s: 6, o: 17.5, top: function (v) { return fmt(v * .32, 1) + " GB"; } },
    gpu: { base: 18, vol: 6, min: 2, max: 70, d: 0, s: 100, top: function (v) { return Math.round(v * .45) + "%"; } },
    disk: { base: 3.2, vol: 1.6, min: .1, max: 20, d: 1, s: 20, top: function (v) { return fmt(v * .7, 1) + " MB/s"; } },
    net: { base: 1.2, vol: .5, min: .1, max: 6, d: 1, s: 6, top: function (v) { return fmt(v * .8, 1) + " MB/s"; } },
    bat: { base: 84, vol: 0, min: 84, max: 84, d: 0, s: 100, flat: true }
  };
  var tiles = Array.prototype.map.call(document.querySelectorAll("[data-tile]"), function (el) {
    var d = defs[el.getAttribute("data-tile")], sp = el.querySelector("[data-spark]"), bars = [], ser = [], v = d.base;
    for (var i = 0; i < 28; i++) {
      v = clamp(v + (rnd() - .5) * d.vol * 2, d.min, d.max);
      ser.push(d.flat ? .3 + rnd() * .4 : clamp((v - (d.o || 0)) / d.s, .05, 1));
      var b = document.createElement("i"); sp.appendChild(b); bars.push(b);
    }
    return { d: d, bars: bars, ser: ser, v: v, out: el.querySelector("[data-v]"), top: el.querySelector("[data-top]") };
  });
  function paint(t) { t.bars.forEach(function (b, i) { b.style.transform = "scaleY(" + t.ser[i].toFixed(3) + ")"; }); }
  tiles.forEach(function (t) { if (!t.d.flat) { t.out.textContent = fmt(t.v, t.d.d); t.top.textContent = t.d.top(t.v); } paint(t); });
  if (reduce) return;
  var timer = 0, visible = true;
  function tick() {
    tiles.forEach(function (t) {
      var d = t.d;
      if (d.flat) { t.ser.push(.3 + rnd() * .4); }
      else {
        var v = clamp(t.v + (rnd() - .5) * d.vol * 2, d.min, d.max);
        t.v = v + (d.base - v) * .15;
        t.ser.push(clamp((v - (d.o || 0)) / d.s, .05, 1));
        t.out.textContent = fmt(v, d.d); t.top.textContent = d.top(v);
      }
      t.ser.shift(); paint(t);
    });
  }
  function run() {
    var go = visible && !document.hidden;
    if (go && !timer) timer = setInterval(tick, 1000);
    if (!go && timer) { clearInterval(timer); timer = 0; }
  }
  window.addEventListener("load", function () {
    var pic = document.querySelector(".pic");
    if (pic && "IntersectionObserver" in window) new IntersectionObserver(function (e) { visible = e[0].isIntersecting; run(); }).observe(pic);
    document.addEventListener("visibilitychange", run);
    run();
  });
})();
