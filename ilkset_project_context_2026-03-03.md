# ILKSET Project Context (Güncel Özet) — 2026-03-03

Bu dosya, yeni bir sohbete **ILKSET** projesini hızlı ve doğru şekilde “kaldığımız yerden” tanıtmak için hazırlanmıştır.

---

## 1) Proje amacı (1 cümle)
Windows 10 üzerinde çalışan **ilkset_app** (Flutter) + **helper Python scriptleri** ile ESP8266 / ESP32 cihazlarını **USB serial üzerinden** tespit edip (probe), gerekiyorsa **stub firmware flashlayıp**, ardından WiFi + statik IP ayarlarını **provision** ederek cihazı yerel ağa dahil etmek.

---

## 2) Ortam / klasörler

- Repo: `C:\GitProje\ilkset`
- Helper dizini: `C:\GitProje\ilkset\helper`
- Firmware dizini (manuel oluşturuldu):
  - `C:\GitProje\ilkset\helper\firmware\stub_esp8266.bin`
  - `C:\GitProje\ilkset\helper\firmware\stub_esp32c6.bin`
- Kullanılan kart:
  - **ESP8266** (NodeMCU 1.0 / ESP-12E), seri port örnekleri: COM6 / COM7
- Router / LAN:
  - Subnet: `192.168.55.0/24`
  - Gateway: `192.168.55.1`
  - Static IP denemeleri: `192.168.55.20, .22, .25, .28, .29, .33, .37, .38` vb.
  - SSID: `sllama` (2.4 GHz olduğu doğrulandı)

---

## 3) Çalışan parçalar (kanıtlı)

### 3.1 ESP probe akışı OK
`esp_probe_json.py` seri porttan konuşabiliyor.
Örnek:
- `@PING` → `@PONG ESP8266`
- Uygulama logu:
  - `✅ PROBE: PROGRAMLANABİLİR`
  - `chip: ESP8266 | mac: 40:91:51:58:70:6e`

### 3.2 Stub flash OK / READY
Uygulama tarafında flash aşaması geçiyor:
- `✅ FLASH OK / READY`

### 3.3 Arduino IDE “WiFi test sketch” ile ağ bağlantısı OK
Aynı cihazda Arduino test sketch yüklendiğinde:
- `WIFI CONNECTED`
- `IP: 192.168.55.27`
- Ping alınabildi (Windows PowerShell):
  - `Reply from 192.168.55.27: bytes=32 time=... TTL=255`

Bu, **WiFi/Router/SSID/2.4 GHz** tarafının temelde çalıştığını gösteriyor.

---

## 4) Sorun: Provision doğrulama akışı tutarsız / timeout

### 4.1 Uygulama logu
`ilkset_app` içinde “Kaydet/Provision” sonrası:
- `❌ PROVISION: WIFI_JOIN_TIMEOUT` (bazı denemelerde ~12s, bazen ~60s civarı)

### 4.2 Script JSON tail_log bulguları
Örnek hata çıktıları:

**A)** Çok sayıda unknown cmd:
```json
{
  "ok": false,
  "message": "WIFI_JOIN_TIMEOUT",
  "tail_log": [
    "@PONG ESP8266",
    "@ACK OK",
    "@ACK ERR:UNKNOWN_CMD",
    "@ACK ERR:UNKNOWN_CMD"
  ]
}
```

**B)** Debug state boş kalıyor (INFO yakalanmıyor):
```json
{
  "ok": false,
  "message": "WIFI_JOIN_TIMEOUT",
  "tail_log": [
    "@PONG ESP8266",
    "@ACK OK",
    "@ACK ERR:UNKNOWN_CMD",
    "DEBUG_STATE: {\"mode\": null, \"wifi_status\": null, \"ip\": null}",
    "DEBUG_LAST_LINE: @ACK ERR:UNKNOWN_CMD"
  ]
}
```

Bu çıktılar şunu düşündürüyor:
- Cihaz firmware/stub tarafında script’in gönderdiği **info komutu** (örn. `@INFO`) desteklenmiyor **veya**
- Script, cihazın bastığı `@INFO ...` satırlarını beklediği prefix/format ile yakalayamıyor.

Not: ESP8266 firmware tarafında manuel serial komutla `@INFO` çalıştığı da gözlemlendi (Arduino IDE’de farklı sketch/prod firmware ile `@INFO` çıktıları görüldü). Ancak helper tarafındaki stub/akış ile tam uyum sorgulanıyor.

---

## 5) Yapılan yazılım değişikliği: esp_provision_json.py (ESP8266 doğrulama eklendi)

Dosya:
- `C:\GitProje\ilkset\helper\esp_provision_json.py`

İstenen/uygulanan mantık:
1) `@PING` / `@PONG` handshake kalsın  
2) `@CFG <json>` gönder  
3) `@ACK OK` gelirse **mutlaka doğrula**  
   - En fazla 12 sn boyunca her 1 sn’de bir `@INFO` benzeri komut iste  
   - Dönen satırlardan:
     - `MODE` = `STA`
     - `WIFI_STATUS` = `3` (WL_CONNECTED)
     - `IP` boş değil ve `--ip` verildiyse aynı
   - Sağlanırsa `ok=true`, `message="WIFI_JOINED"`
   - Timeout olursa `ok=false`, `message="WIFI_JOIN_TIMEOUT"`
4) JSON şeması bozulmayacak (ok/message/stage/tail_log vs.)  
5) Parola masking korunacak  
6) ESP32 yoluna dokunulmayacak (yalnız ESP8266’da uygulanacak)

Güncel durumda script, doğrulama döngüsünde `@INFO` gönderdiğinde cihazdan sıklıkla:
- `@ACK ERR:UNKNOWN_CMD`
dönüyor ve `state` dolmuyor (mode/wifi_status/ip null kalıyor).

---

## 6) Önemli gözlemler (debug için kritik)

- Bazı denemelerde kullanıcı “kayıt ediyor gibi bekletti” ve mesajlar **yaklaşık 1 dk sonra** geldi.
  - 12 sn doğrulama penceresi kısa olabilir.
- Arduino IDE Serial Monitor’da bazen ilk açılışta “garbage” karakterler görüldü; baud/boot mesajları karışabiliyor.
- Aynı cihazda Arduino test sketch ile STA bağlantısı + ping OK olduğundan:
  - “WiFi çalışmıyor” değil,
  - “ILKSET stub/provision protokol uyumu + doğrulama yöntemi” sorunu öne çıkıyor.

---

## 7) Şu anki hedef (bir sonraki adımlar)

### Hedef-1: Stub/firmware ile helper protokolünü netleştir
- ESP8266 stub firmware **hangi komutları destekliyor?**
  - `@PING`, `@CFG`, `@INFO` / `@STAT` / `@STATUS` vb.
- `@ACK ERR:UNKNOWN_CMD` hangi komuta geliyor netleştir:
  - Script doğrulamada `@INFO` gönderiyor → unknown ise demek ki firmware tarafı `@INFO` komutunu tanımıyor.

### Hedef-2: Doğrulama stratejisini sağlamlaştır
- Eğer stub `@INFO` desteklemiyorsa:
  - Alternatif bir komut setine geç (firmware tarafı)
  - veya doğrulamayı **ağ üzerinden** yap (örn. IP’ye ping / HTTP health endpoint)
- Timeout süreleri (örn. 12s → 60s) gerçek gözlemlere göre ayarlanmalı.

### Hedef-3: ESP8266 ve ESP32 akışlarını ayrıştırma
- Repo yapısı zaten iki farklı cihaz yolu için hazırlanıyordu.
- ESP8266 doğrulama/komut seti kesinleşince ESP32 yoluna dokunmadan ilerle.

---

## 8) Hızlı komut referansı (kanıt çıktılar)

Cihazdan görülen örnek (başarılı WiFi join sonrası):
```
@INFO MODE AP
@INFO WIFI_STATUS 7
@INFO IP 192.168.4.1
@ACK OK
@INFO APPLYING
@INFO STATICCFG OK
@INFO WIFI_CONNECTED
@INFO IP 192.168.55.27
@INFO RSSI -50
@ACK OK WIFI_JOINED
```

Uygulama + helper üzerinden görülen sorunlu örnek:
```
@PONG ESP8266
@ACK OK
@ACK ERR:UNKNOWN_CMD   (çok tekrar)
-> WIFI_JOIN_TIMEOUT
```

---

## 9) Mevcut durum cümlesi (Yeni sohbet açarken kullan)
“ILKSET’te ESP8266 için probe + stub flash çalışıyor, fakat provision sonrası WiFi join doğrulaması timeout’a düşüyor. Arduino test sketch ile aynı cihazın STA bağlanıp ping aldığını doğruladık. Helper doğrulama döngüsünde `@INFO` komutuna karşılık firmware `@ACK ERR:UNKNOWN_CMD` döndürüyor ve state dolmuyor; bu nedenle stub/firmware komut seti ile helper doğrulamasını uyumlu hale getirip (gerekirse ağ üzerinden doğrulama ekleyip) akışı stabilize etmek istiyoruz.”

---
