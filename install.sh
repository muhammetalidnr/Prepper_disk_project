#!/usr/bin/env bash
# PrepperPi kurulum betiği — Raspberry Pi 4 (1 GB) + Raspberry Pi OS Lite (64-bit, Bookworm/Trixie)
#
#   sudo ./install.sh                         Temel kurulum
#   sudo ./install.sh --content wiki-tr-nopic,wikimed-en --maps turkiye
#
# Seçenekler:
#   --wikipedia SÜRÜM Türkçe Wikipedia: resimli | resimsiz | ozet
#   --content K1,K2   Kurulumdan sonra bu içerikleri indir (liste: config/catalog.txt)
#   --maps BÖLGE      Çevrimdışı harita indir (turkiye | istanbul | ankara | izmir | W,S,E,N)
#   --no-tune         Bellek/SD kart optimizasyonlarını atla
#   --start-ap        wlan0 bir ağa bağlı olsa bile erişim noktasını hemen aç
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=/opt/prepperpi
WEB_ROOT=/var/www/prepper

MAPLIBRE_VER=5.24.0
PMTILES_VER=4.4.1
BASEMAPS_VER=5.7.2

CONTENT=""; WIKI=""; MAPS=""; TUNE=1; START_AP=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --content) CONTENT=${2:?}; shift 2 ;;
    --wikipedia) WIKI=${2:?}; shift 2 ;;
    --maps) MAPS=${2:?}; shift 2 ;;
    --no-tune) TUNE=0; shift ;;
    --start-ap) START_AP=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $1" >&2; exit 1 ;;
  esac
done

info() { printf '\e[32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[33m!!\e[0m  %s\n' "$*" >&2; }
die()  { printf '\e[31mHATA:\e[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "root olarak çalıştırın: sudo ./install.sh"
command -v apt-get >/dev/null || die "Debian tabanlı bir sistem gerekli (Raspberry Pi OS)."

ARCH=$(uname -m)
case $ARCH in
  aarch64) KIWIX_ARCH=aarch64 ;;
  armv7l|armv6l) KIWIX_ARCH=armv6; warn "32-bit sistem algılandı; 64-bit Raspberry Pi OS Lite önerilir." ;;
  x86_64) KIWIX_ARCH=x86_64; warn "Raspberry Pi değil (x86_64) — test amaçlı kurulum." ;;
  *) die "Desteklenmeyen mimari: $ARCH" ;;
esac

MEM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
# shellcheck disable=SC1091
info "Sistem: $(. /etc/os-release && echo "$PRETTY_NAME"), $ARCH, ${MEM_MB} MB RAM"

# ---------------------------------------------------------------- 1) Paketler
info "Paketler kuruluyor..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  nginx curl wget unzip ca-certificates network-manager dnsmasq-base iw rfkill zram-tools >/dev/null

systemctl is-active -q NetworkManager || {
  systemctl enable --now NetworkManager
  warn "NetworkManager yeni etkinleştirildi. (Bookworm ve sonrası varsayılan olarak kullanır.)"
}

# ---------------------------------------------------------------- 2) Kiwix
install_kiwix() {
  local tmp url
  url="https://download.kiwix.org/release/kiwix-tools/kiwix-tools_linux-${KIWIX_ARCH}.tar.gz"
  tmp=$(mktemp -d)
  if curl -fsSL --retry 3 -o "$tmp/k.tgz" "$url" && tar -xzf "$tmp/k.tgz" -C "$tmp"; then
    local b
    for b in kiwix-serve kiwix-manage kiwix-search; do
      install -m 755 "$(find "$tmp" -type f -name "$b" | head -1)" "/usr/local/bin/$b"
    done
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  warn "Resmi kiwix-tools indirilemedi, Debian paketi deneniyor..."
  apt-get install -y -qq kiwix-tools >/dev/null || return 1
  ln -sf "$(command -v kiwix-serve)" /usr/local/bin/kiwix-serve 2>/dev/null || true
  ln -sf "$(command -v kiwix-manage)" /usr/local/bin/kiwix-manage 2>/dev/null || true
}
if [[ ! -x /usr/local/bin/kiwix-serve ]]; then
  info "kiwix-tools kuruluyor..."
  install_kiwix || die "kiwix-tools kurulamadı."
fi
info "$(/usr/local/bin/kiwix-serve --version 2>&1 | head -1)"

# ---------------------------------------------------------------- 3) Dosyalar
id prepper >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin prepper

mkdir -p "$PREFIX"
cp -r "$SRC/config" "$SRC/web" "$PREFIX/"
install -m 755 "$SRC/bin/prepper" "$SRC/bin/prepper-status" /usr/local/bin/
[[ -f /etc/prepper.conf ]] || install -m 640 -g prepper "$SRC/config/prepper.conf" /etc/prepper.conf
# kiwix-serve (prepper kullanıcısı) DATA_DIR ayarını okuyabilsin
chgrp prepper /etc/prepper.conf && chmod 640 /etc/prepper.conf

# shellcheck source=/dev/null
. /etc/prepper.conf
DATA_DIR=${DATA_DIR:-/srv/prepper}
mkdir -p "$DATA_DIR"/{zim,maps,map-assets,files}
[[ -f $DATA_DIR/maps/index.json ]] || echo '[]' >"$DATA_DIR/maps/index.json"
[[ -f $DATA_DIR/files/BENİOKU.txt ]] || cat >"$DATA_DIR/files/BENİOKU.txt" <<EOF
Bu klasöre koyduğunuz her dosya (PDF, e-kitap, video...) portaldaki "Dosyalar"
bölümünde listelenir. Klasör: $DATA_DIR/files
EOF
chown -R prepper:prepper "$DATA_DIR"

mkdir -p "$WEB_ROOT/maps/vendor"
cp -r "$SRC/web/." "$WEB_ROOT/"
fetch_vendor() {
  local url=$1 out=$2
  [[ -s $out ]] && return 0
  curl -fsSL --retry 3 -o "$out.tmp" "$url" && mv "$out.tmp" "$out"
}
info "Harita kütüphaneleri indiriliyor (cihaza kaydedilir, sonrasında internet gerekmez)..."
vendor_ok=1
for spec in \
  "maplibre-gl@$MAPLIBRE_VER/dist/maplibre-gl.js" \
  "maplibre-gl@$MAPLIBRE_VER/dist/maplibre-gl.css" \
  "pmtiles@$PMTILES_VER/dist/pmtiles.js" \
  "@protomaps/basemaps@$BASEMAPS_VER/dist/basemaps.js"; do
  fetch_vendor "https://unpkg.com/$spec" "$WEB_ROOT/maps/vendor/${spec##*/}" || vendor_ok=0
done
(( vendor_ok )) || warn "Harita kütüphaneleri indirilemedi; internet varken install.sh'i tekrar çalıştırın."

install -m 644 "$SRC/config/prepper-status.service" "$SRC/config/prepper-status.timer" /etc/systemd/system/

# ---------------------------------------------------------------- 4) 1 GB RAM / SD kart ayarları
if (( TUNE )); then
  info "Bellek ve SD kart optimizasyonları uygulanıyor..."

  # Sıkıştırılmış RAM takası (zram): SD karta yazmadan ~1,5 GB'a kadar efektif bellek
  cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
  systemctl restart zramswap 2>/dev/null || true
  # SD kartı yıpratan dosya takasını kapat
  if systemctl list-unit-files dphys-swapfile.service >/dev/null 2>&1; then
    dphys-swapfile swapoff 2>/dev/null || true
    systemctl disable --now dphys-swapfile 2>/dev/null || true
  fi
  systemctl disable --now rpi-swap 2>/dev/null || true   # Trixie dosya takası

  cat >/etc/sysctl.d/90-prepper.conf <<'EOF'
# zram ile takas ucuzdur; anonim belleği oraya it, dosya önbelleğini (ZIM okumaları) koru
vm.swappiness=150
vm.page-cluster=0
vm.vfs_cache_pressure=80
EOF
  sysctl -q --system >/dev/null 2>&1 || true

  # Günlükleri RAM'de tut (SD karta yazma yok), boyutu sınırla
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/prepper.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF
  systemctl restart systemd-journald || true

  # Ekransız kullanımda GPU belleğini küçült, Bluetooth'u kapat
  BOOTCFG=/boot/firmware/config.txt; [[ -f $BOOTCFG ]] || BOOTCFG=/boot/config.txt
  if [[ -f $BOOTCFG ]] && ! grep -q '^# PrepperPi' "$BOOTCFG"; then
    cat >>"$BOOTCFG" <<'EOF'

# PrepperPi
[all]
gpu_mem=16
dtoverlay=disable-bt
EOF
  fi

  # Gereksiz servisleri kapat
  for s in bluetooth hciuart ModemManager triggerhappy cups cups-browsed; do
    systemctl disable --now "$s" >/dev/null 2>&1 || true
  done

  # nginx: 2 işçi işlem yeter, belleği koru
  sed -i -E 's/^worker_processes .*/worker_processes 2;/' /etc/nginx/nginx.conf
fi

# ---------------------------------------------------------------- 5) İçerik (internet varken)
if [[ -n $WIKI ]]; then
  /usr/local/bin/prepper wikipedia "$WIKI" || warn "Wikipedia indirilemedi."
fi
if [[ -n $CONTENT ]]; then
  IFS=',' read -r -a keys <<<"$CONTENT"
  /usr/local/bin/prepper content install "${keys[@]}" || warn "Bazı içerikler indirilemedi."
fi
if [[ -n $MAPS ]]; then
  /usr/local/bin/prepper maps install "$MAPS" || warn "Harita indirilemedi."
fi

# ---------------------------------------------------------------- 6) Servisleri ve Wi-Fi'yi aç
info "Servisler ve erişim noktası yapılandırılıyor..."
PREPPER_FORCE_AP=$START_AP /usr/local/bin/prepper apply

cat <<EOF

  ✔ PrepperPi kuruldu.

    Wi-Fi ağı : ${WIFI_SSID:-PrepperPi}   (şifre /etc/prepper.conf içinde)
    Portal    : http://${AP_IP:-10.42.0.1}/   veya   http://prepper.lan/

  Sonraki adımlar (internet bağlantısı varken, tercihen Ethernet ile):
    sudo prepper content list
    sudo prepper wikipedia resimli        # veya: resimsiz / ozet
    sudo prepper content install wikimed-en medicine-en
    sudo prepper maps install turkiye
    sudo reboot
EOF
(( TUNE )) && echo "  Not: gpu_mem ve Bluetooth ayarları için yeniden başlatma gerekir."
