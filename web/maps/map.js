// PrepperPi çevrimdışı harita: PMTiles dosyası tarayıcıda çizilir, Pi sadece dosya parçalarını gönderir.
(function () {
  "use strict";
  var origin = location.origin;
  var protocol = new pmtiles.Protocol();
  maplibregl.addProtocol("pmtiles", protocol.tile);

  var dark = window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches;
  var flavorName = dark ? "dark" : "light";
  var map, lang = "tr";

  function styleFor(file) {
    return {
      version: 8,
      glyphs: origin + "/data/map-assets/fonts/{fontstack}/{range}.pbf",
      sprite: origin + "/data/map-assets/sprites/v4/" + flavorName,
      sources: {
        protomaps: {
          type: "vector",
          url: "pmtiles://" + origin + "/data/maps/" + file,
          attribution: "© OpenStreetMap katkıcıları · Protomaps"
        }
      },
      layers: basemaps.layers("protomaps", basemaps.namedFlavor(flavorName), { lang: lang })
    };
  }

  function show(file) {
    var url = origin + "/data/maps/" + file;
    var p = new pmtiles.PMTiles(url);
    protocol.add(p);
    p.getHeader().then(function (h) {
      var bounds = [[h.minLon, h.minLat], [h.maxLon, h.maxLat]];
      if (!map) {
        map = new maplibregl.Map({ container: "map", style: styleFor(file), bounds: bounds, maxZoom: h.maxZoom + 3, hash: true });
        map.addControl(new maplibregl.NavigationControl(), "top-right");
        map.addControl(new maplibregl.ScaleControl({ unit: "metric" }));
        var coord = document.getElementById("coord");
        map.on("click", function (e) {
          coord.hidden = false;
          coord.textContent = e.lngLat.lat.toFixed(5) + ", " + e.lngLat.lng.toFixed(5);
        });
      } else {
        map.setStyle(styleFor(file));
        map.fitBounds(bounds, { animate: false });
      }
    });
  }

  function fail() { document.getElementById("msg").style.display = "flex"; }

  Promise.all([
    fetch("/maps/config.json").then(function (r) { return r.ok ? r.json() : {}; }).catch(function () { return {}; }),
    fetch("/data/maps/index.json", { cache: "no-store" }).then(function (r) { if (!r.ok) throw r; return r.json(); })
  ]).then(function (res) {
    if (res[0].lang) lang = res[0].lang;
    var files = res[1];
    if (!files.length) return fail();
    var sel = document.getElementById("region");
    if (files.length > 1) {
      files.forEach(function (f) {
        var o = document.createElement("option");
        o.value = f; o.textContent = f.replace(/\.pmtiles$/, "");
        sel.appendChild(o);
      });
      sel.hidden = false;
      sel.onchange = function () { show(sel.value); };
    }
    show(files[0]);
  }).catch(fail);
})();
