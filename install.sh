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

# Çekirdek 64-bit olsa bile kullanıcı alanı 32-bit olabilir: paket mimarisine bak
ARCH=$(dpkg --print-architecture)
case $ARCH in
  arm64) KIWIX_ARCH=aarch64 ;;
  armhf|armel) KIWIX_ARCH=armv6; warn "32-bit sistem algılandı; 64-bit Raspberry Pi OS Lite önerilir." ;;
  amd64) KIWIX_ARCH=x86_64; warn "Raspberry Pi değil (amd64) — test amaçlı kurulum." ;;
  *) die "Desteklenmeyen mimari: $ARCH" ;;
esac
# shellcheck disable=SC1091
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
case $CODENAME in
  bookworm|trixie|forky|noble|oracular|plucky) ;;
  *) warn "Sistem: '${CODENAME:-?}'. Raspberry Pi OS Bookworm veya daha yenisi önerilir (NetworkManager gerekir)." ;;
esac

MEM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
# shellcheck disable=SC1091
info "Sistem: $(. /etc/os-release && echo "$PRETTY_NAME"), $ARCH, ${MEM_MB} MB RAM"

# ---------------------------------------------------------------- 1) Paketler
info "Paketler kuruluyor..."
export DEBIAN_FRONTEND=noninteractive
PKGS=(nginx curl wget unzip ca-certificates network-manager dnsmasq-base iw rfkill)
# Trixie'deki rpi-swap zaten zram kurar; ikinci bir zram kurmayalım
dpkg -s rpi-swap >/dev/null 2>&1 || PKGS+=(zram-tools)
apt-get update -qq || die "Paket listesi indirilemedi. İnternet bağlantısını kontrol edin (Ethernet önerilir) ve saatin doğru olduğundan emin olun: date"
for svc in apache2 lighttpd; do
  if systemctl is-active -q "$svc" 2>/dev/null; then
    die "$svc çalışıyor ve 80. portu kullanıyor; nginx başlayamaz. Kapatın: sudo systemctl disable --now $svc"
  fi
done
apt-get install -y -qq --no-install-recommends "${PKGS[@]}" >/dev/null || die "Paketler kurulamadı (yukarıdaki apt hatasına bakın)."

systemctl is-active -q NetworkManager || {
  systemctl enable --now NetworkManager
  warn "NetworkManager yeni etkinleştirildi. (Bookworm ve sonrası varsayılan olarak kullanır.)"
}

# ---------------------------------------------------------------- 2) Kiwix
install_kiwix() {
  local tmp url
  url="https://download.kiwix.org/release/kiwix-tools/kiwix-tools_linux-${KIWIX_ARCH}.tar.gz"
  tmp=$(mktemp -d)
  if curl -fsSL --connect-timeout 20 --max-time 600 --retry 3 -o "$tmp/k.tgz" "$url" &&
     tar -xzf "$tmp/k.tgz" -C "$tmp"; then
    local b f ok=1
    for b in kiwix-serve kiwix-manage; do
      f=$(find "$tmp" -type f -name "$b" | head -1)
      if [[ -n $f ]]; then install -m 755 "$f" "/usr/local/bin/$b"; else ok=0; fi
    done
    rm -rf "$tmp"
    if (( ok )) && /usr/local/bin/kiwix-serve --version >/dev/null 2>&1 &&
       /usr/local/bin/kiwix-manage --version >/dev/null 2>&1; then
      return 0
    fi
    warn "İndirilen kiwix-tools bu sistemde çalışmadı."
  else
    rm -rf "$tmp"
  fi
  warn "Debian'ın kiwix-tools paketi deneniyor..."
  apt-get install -y -qq kiwix-tools >/dev/null || return 1
  ln -sf /usr/bin/kiwix-serve /usr/local/bin/kiwix-serve
  ln -sf /usr/bin/kiwix-manage /usr/local/bin/kiwix-manage
  /usr/local/bin/kiwix-serve --version >/dev/null 2>&1
}
if ! /usr/local/bin/kiwix-serve --version >/dev/null 2>&1 || ! /usr/local/bin/kiwix-manage --version >/dev/null 2>&1; then
  info "kiwix-tools kuruluyor..."
  install_kiwix || die "kiwix-tools kurulamadı."
fi
info "$(/usr/local/bin/kiwix-serve --version 2>&1 | head -1)"

# ---------------------------------------------------------------- 3) Dosyalar
id prepper >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin prepper

mkdir -p "$PREFIX"
if [[ $SRC != "$PREFIX" ]]; then
  cp -r "$SRC/config" "$SRC/web" "$PREFIX/"
fi
chmod -R a+rX "$PREFIX"
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
# Veri diski biçimini (FAT32/exFAT) ve yazma iznini indirmelerden ÖNCE denetle
/usr/local/bin/prepper check-data
chown -R prepper:prepper "$DATA_DIR" 2>/dev/null || warn "$DATA_DIR sahipliği değiştirilemedi (exFAT/NTFS?)."
# Kullanıcı Dosyalar klasörüne sudo'suz kopyalayabilsin
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
  chown -R "$SUDO_USER" "$DATA_DIR/files" 2>/dev/null || true
fi

mkdir -p "$WEB_ROOT/maps/vendor"
cp -r "$SRC/web/." "$WEB_ROOT/"
chmod -R a+rX "$WEB_ROOT"
info "Harita kütüphaneleri indiriliyor (cihaza kaydedilir, sonrasında internet gerekmez)..."
/usr/local/bin/prepper vendor || warn "Harita kütüphaneleri indirilemedi; internet varken: sudo prepper vendor"

install -m 644 "$SRC/config/prepper-status.service" "$SRC/config/prepper-status.timer" /etc/systemd/system/

# ---------------------------------------------------------------- 4) 1 GB RAM / SD kart ayarları
if (( TUNE )); then
  info "Bellek ve SD kart optimizasyonları uygulanıyor..."

  # Sıkıştırılmış RAM takası (zram): SD karta yazmadan ~1,5 GB'a kadar efektif bellek
  if [[ -d /etc/default ]] && dpkg -s zram-tools >/dev/null 2>&1; then
    cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
    systemctl restart zramswap 2>/dev/null || warn "zram başlatılamadı (yeniden başlatınca açılır)."
  fi
  # SD kartı yıpratan dosya takasını kapat
  if systemctl list-unit-files dphys-swapfile.service >/dev/null 2>&1; then
    dphys-swapfile swapoff 2>/dev/null || true
    systemctl disable --now dphys-swapfile 2>/dev/null || true
  fi

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
    cp -n "$BOOTCFG" "$BOOTCFG.prepper-yedek" 2>/dev/null || true
    cat >>"$BOOTCFG" <<'EOF'

# PrepperPi (geri almak için bu bloğu silin; yedek: config.txt.prepper-yedek)
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
  sed -i -E 's/^worker_processes .*/worker_processes 2;/' /etc/nginx/nginx.conf || true
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
