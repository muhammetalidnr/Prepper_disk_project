# PrepperPi — Raspberry Pi 4 (1 GB) için çevrimdışı "prepper disk"

İnternet ve şebeke çöktüğünde bile çalışan, kendi Wi-Fi ağını yayınlayan bir bilgi sunucusu.
Telefon, tablet veya laptopla ağa bağlanan herkes tarayıcıdan şunlara ulaşır:

| Bölüm | İçerik |
|---|---|
| **Kütüphane** | Türkçe Wikipedia, WikiMed (tıp), afet tıbbı, su arıtma, gıda saklama, iFixit onarım kılavuzları… ([Kiwix](https://kiwix.org) ZIM dosyaları) |
| **Haritalar** | Türkiye (veya seçilen bölge) sokak haritası — tamamen çevrimdışı, OpenStreetMap verisi |
| **Acil durum rehberi** | 112/114, Çök-Kapan-Tutun, su kaynatma, işaretlenebilir afet çantası listesi |
| **Dosyalar** | Klasöre attığınız her PDF, e-kitap, video |

Telefonlar ağa bağlanınca "Ağda oturum açın" penceresiyle portal **otomatik açılır**.

## Neden 1 GB RAM yeter?

- **kiwix-serve** C++ ile yazılmış, ZIM dosyalarını bellek yerine diskten okur (~50–150 MB RAM).
- **Haritalar Pi'de çizilmez**: PMTiles dosyasının parçaları gönderilir, çizimi telefonun tarayıcısı yapar.
  Pi'de harita sunucusu/veritabanı yok, sadece nginx.
- Kurulum şunları da yapar: **zram** (sıkıştırılmış RAM takası), SD kart takasını kapatma,
  günlükleri RAM'de tutma, GPU belleğini 16 MB'a düşürme, Bluetooth ve gereksiz servisleri kapatma.
- kiwix-serve systemd ile 650 MB'ta sınırlanır; sistem her koşulda yanıt verir.

Boşta toplam kullanım ~200 MB civarındadır; 10–20 eşzamanlı kullanıcı rahattır.

## Gerekenler

- Raspberry Pi 4 (1 GB yeterli) + resmi 5V/3A güç adaptörü (veya powerbank / güneş paneli + batarya)
- **Depolama**: içeriğe göre — ör. Türkçe Wikipedia (resimsiz) + WikiMed + Türkiye haritası için ~64 GB yeter.
  Büyük içerik için **USB 3 SSD** önerilir (SD karttan hızlı ve dayanıklı).
- **Raspberry Pi OS Lite (64-bit)**, Bookworm veya Trixie. Raspberry Pi Imager ile yazarken SSH'ı açın.
- Kurulum ve içerik indirme sırasında internet (tercihen **Ethernet kablosu** — Wi-Fi erişim noktası olarak kullanılacak).

## Kurulum

```bash
sudo apt install -y git
git clone <bu-repo-adresi> prepperpi && cd prepperpi
sudo ./install.sh
```

İçerik ve haritayı kurulumla birlikte indirmek için:

```bash
sudo ./install.sh --content wiki-tr-nopic,wikimed-en,medicine-en,water-en --maps turkiye
sudo reboot
```

Yeniden başlattıktan sonra **PrepperPi** ağına bağlanın ve `http://10.42.0.1/` (veya `http://prepper.lan/`) adresini açın.

> **Pi'ye Wi-Fi üzerinden SSH ile bağlıysanız**: kurulum bağlantınızı koparmamak için erişim noktasını
> hemen açmaz; `sudo reboot` sonrası açılır. Sonrasında Pi'ye PrepperPi ağına bağlanıp
> `ssh <kullanıcı>@10.42.0.1` ile erişirsiniz. İnternet için Ethernet kablosu takın.

## İçerik yönetimi

```bash
prepper content list                          # katalog ve kurulu olanlar
sudo prepper content install wiki-tr-nopic    # en yeni sürümü bulur, boyutu ve boş alanı kontrol eder
sudo prepper content update                   # kurulu her şeyi yeni aylık sürüme yükseltir, eskiyi siler
sudo prepper content remove wiki-tr-nopic
prepper status                                # RAM, sıcaklık, disk, servisler
```

- İndirmeler kesilirse aynı komut **kaldığı yerden devam eder**.
- Katalog dışı bir ZIM (ör. [library.kiwix.org](https://library.kiwix.org)'dan) kullanmak için dosyayı
  `/srv/prepper/zim/` içine kopyalayıp `sudo prepper content reload` çalıştırın.
- Katalog: [`config/catalog.txt`](config/catalog.txt) — satır ekleyerek genişletebilirsiniz.

Yaklaşık boyutlar (sürüme göre değişir; komut indirmeden önce gerçek boyutu gösterir):

| Anahtar | Boyut |
|---|---|
| `wiki-tr-mini` | ~0,5 GB |
| `wiki-tr-nopic` | ~2–3 GB |
| `wiki-tr-maxi` | ~6–8 GB |
| `wikimed-en` | ~2 GB |
| `medicine-en`, `water-en`, `food-en`, `post-disaster-en` | her biri 100 MB – 1 GB |

## Haritalar

```bash
sudo prepper maps install turkiye          # tüm Türkiye, yakınlaştırma 13'e kadar (~1–2 GB)
sudo prepper maps install istanbul 15      # sadece İstanbul, bina/sokak detayında
sudo prepper maps install 26,36,45,42 12   # özel bölge: batı,güney,doğu,kuzey
```

Birden fazla bölge indirilirse harita sayfasında seçici çıkar. Haritaya tıklamak koordinat gösterir.

## Ayarlar

`/etc/prepper.conf` dosyasını düzenleyip `sudo prepper apply` çalıştırın:

- `WIFI_SSID`, `WIFI_PASS` — ağ adı ve şifresi (boş şifre = açık ağ)
- `DATA_DIR` — içeriğin yeri (varsayılan `/srv/prepper`)
- `CAPTIVE=0` — otomatik portal yönlendirmesini kapatır

### USB SSD'yi veri diski yapmak

```bash
sudo mkfs.ext4 -L prepper /dev/sda1        # DİKKAT: diski siler
sudo mkdir -p /srv/prepper
echo 'LABEL=prepper /srv/prepper ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab
sudo mount -a && sudo ./install.sh          # klasörleri yeniden oluşturur
```

## Mimari

```
 telefon/laptop ──Wi-Fi──▶ NetworkManager AP (10.42.0.1, DHCP + DNS → captive portal)
                              │
                           nginx :80 ──▶ /            portal (statik HTML)
                              │          /wiki/       → kiwix-serve 127.0.0.1:8080 → *.zim
                              │          /data/maps/  PMTiles (Range istekleri) → tarayıcıda MapLibre ile çizim
                              │          /files/      dosya listesi
                              └── prepper-status.timer → /status.json (RAM, disk, sıcaklık, bağlı cihaz)
```

| Dosya | Görev |
|---|---|
| `install.sh` | Paketler, kiwix-tools, bellek ayarları, servisler |
| `bin/prepper` | Yönetim aracı (içerik, harita, ayar uygulama) |
| `bin/prepper-status` | Portal için durum JSON'u |
| `config/` | nginx, systemd, dnsmasq şablonları, içerik kataloğu |
| `web/` | Portal, harita ve rehber sayfaları |

## İpuçları

- **Güç**: Düşük voltaj Pi'yi yavaşlatır; portaldaki "Güç uyarısı" bunu gösterir. Kaliteli kablo kullanın.
- **Isı**: Pasif soğutucu kasa önerilir; portal sıcaklığı gösterir.
- **Yedek**: SD kart imajını (`dd` / Raspberry Pi Imager) ve SSD'yi ayrı yerde saklayın.
- İnternet geldiğinde Ethernet takıp `sudo prepper content update` ile her şeyi güncelleyin.

## Lisanslar

İçerikler kendi lisanslarıyla gelir (Wikipedia: CC BY-SA, harita: © OpenStreetMap katkıcıları, ODbL).
