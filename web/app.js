// PrepperPi portalı: kütüphane listesi ve sistem durumu
(function () {
  "use strict";

  function el(tag, attrs, kids) {
    var e = document.createElement(tag);
    for (var k in attrs || {}) {
      if (k === "text") e.textContent = attrs[k];
      else e.setAttribute(k, attrs[k]);
    }
    (kids || []).forEach(function (c) { if (c) e.appendChild(c); });
    return e;
  }

  function bytes(n) {
    if (!n) return "0 B";
    var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return n.toFixed(n >= 10 || i === 0 ? 0 : 1) + " " + u[i];
  }

  function duration(s) {
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    return (d ? d + " g " : "") + (d || h ? h + " sa " : "") + m + " dk";
  }

  // ZIM adından sürüm türü: wikipedia_tr_all_maxi_2026-10 -> "Resimli"
  var VARIANTS = { maxi: "Resimli", nopic: "Resimsiz", mini: "Özet" };
  function variantOf(name) {
    var m = /_(maxi|nopic|mini)(_|$)/.exec(name || "");
    return m ? VARIANTS[m[1]] : "";
  }

  // --- Kiwix OPDS kataloğu -------------------------------------------------
  function loadBooks() {
    var list = document.getElementById("books");
    var select = document.getElementById("search-book");
    fetch("/wiki/catalog/v2/entries?count=-1")
      .then(function (r) { if (!r.ok) throw r; return r.text(); })
      .then(function (xml) {
        var doc = new DOMParser().parseFromString(xml, "application/xml");
        var entries = Array.prototype.slice.call(doc.getElementsByTagName("entry"));
        list.textContent = "";
        select.textContent = "";
        if (!entries.length) {
          list.appendChild(el("li", { class: "muted", text: "Henüz içerik yok. Pi üzerinde: sudo prepper content install wiki-tr-nopic" }));
          document.getElementById("search").hidden = true;
          return;
        }
        document.getElementById("search").hidden = false;
        entries.forEach(function (en) {
          var get = function (n) { var x = en.getElementsByTagName(n)[0]; return x ? x.textContent : ""; };
          var href = "", icon = "";
          Array.prototype.forEach.call(en.getElementsByTagName("link"), function (l) {
            var type = l.getAttribute("type") || "", rel = l.getAttribute("rel") || "";
            if (type === "text/html" && !href) href = l.getAttribute("href");
            if (rel.indexOf("thumbnail") !== -1) icon = l.getAttribute("href");
          });
          var name = get("name");
          var title = get("title") || name;
          // Kiwix sürümüne göre "name" tarih içermeyebilir; bağlantıdaki kitap kimliğine de bak
          // Arama, ZIM adını değil dosya adından gelen kitap kimliğini ister (ör. wikipedia_tr_all_maxi_2026-10)
          var bookId = href ? href.split("/").filter(Boolean).pop() : name;
          var variant = variantOf(name) || variantOf(bookId);
          list.appendChild(el("li", {}, [
            el("a", { href: href || "/wiki/" }, [
              icon ? el("img", { src: icon, alt: "", loading: "lazy" }) : null,
              el("span", {}, [el("div", { class: "t" }, [
                document.createTextNode(title),
                variant ? el("span", { class: "badge", text: variant }) : null
              ]), el("div", { class: "d", text: get("summary") })])
            ])
          ]));
          if (bookId) select.appendChild(el("option", { value: bookId, text: title + (variant ? " (" + variant.toLowerCase() + ")" : "") }));
        });
        document.getElementById("t-zims").textContent = entries.length + " kaynak";
      })
      .catch(function () {
        list.textContent = "";
        list.appendChild(el("li", { class: "muted", text: "Kütüphane şu an hazır değil (başlıyor olabilir). Biraz sonra sayfayı yenileyin; sürerse Pi'de: sudo prepper check" }));
        document.getElementById("search").hidden = true;
        setTimeout(loadBooks, 15000);
      });
  }

  // --- Sistem durumu -------------------------------------------------------
  function stat(label, value, pct) {
    var kids = [el("dt", { text: label }), el("dd", { text: value })];
    if (pct != null) {
      var i = el("i", { style: "width:" + Math.round(pct) + "%" });
      if (pct > 85) i.className = "hi";
      kids.push(el("div", { class: "bar" }, [i]));
    }
    return el("div", {}, kids);
  }

  function loadStatus() {
    fetch("/status.json", { cache: "no-store" })
      .then(function (r) { if (!r.ok) throw r; return r.json(); })
      .then(function (s) {
        var box = document.getElementById("status");
        box.textContent = "";
        var memUsed = s.mem_total - s.mem_avail, diskUsed = s.disk_total - s.disk_free;
        box.appendChild(stat("Bağlı cihaz", String(s.clients)));
        box.appendChild(stat("Bellek", bytes(memUsed) + " / " + bytes(s.mem_total), 100 * memUsed / s.mem_total));
        box.appendChild(stat("Depolama", bytes(s.disk_free) + " boş", s.disk_total ? 100 * diskUsed / s.disk_total : null));
        if (s.temp_c != null) box.appendChild(stat("Sıcaklık", s.temp_c + " °C", Math.min(100, s.temp_c / 85 * 100)));
        box.appendChild(stat("Çalışma süresi", duration(s.uptime_s)));
        if (s.throttled && s.throttled !== "0x0") box.appendChild(stat("Güç uyarısı", "Düşük voltaj/ısınma (" + s.throttled + ")"));
        document.getElementById("t-maps").textContent = s.maps ? s.maps + " harita bölgesi" : "Harita henüz yüklenmedi";
        document.getElementById("t-files").textContent = s.files + " dosya";
      })
      .catch(function () {});
  }

  loadBooks();
  loadStatus();
  setInterval(loadStatus, 60000);
})();
