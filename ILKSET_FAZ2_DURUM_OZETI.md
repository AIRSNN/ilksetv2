# ILKSET — FAZ2 Durum Özeti ve Devam Dokümanı (Yeni Sohbet İçin)

> Amaç: Yeni bir sohbet açıldığında “bağlam kaybı / tıkanma” yaşamadan ILKSET projesine kaldığımız yerden devam edebilmek.

---

## 1) Proje Ne Yapıyor?

ILKSET, Windows 10 üzerinde çalışan **Flutter Desktop UI** + **Python helper** zinciriyle, USB üzerinden bağlı ESP cihazlarını:

1. **Port tarama (Scan Ports)**
2. **Probe** ile cihazı doğrulama (UART @PING/@PONG)
3. Gerekirse **stub firmware flash**
4. Ardından **WiFi / network bilgilerini provision etme** (@CFG → @ACK OK)

akışıyla yönetir.

---

## 2) Çalışan Bileşenler (Stabil)

### 2.1 Python Helper Scriptleri
- `esp_probe_json.py` ✅  
  - Seri porta bağlanır
  - `@PING` gönderir
  - `@PONG` bekler
  - Tek satır JSON döndürür

- `esp_provision_json.py` ✅  
  - `@PING` → `@CFG {json}` → `@ACK OK`
  - Tek satır JSON üretir
  - Flutter tarafı JSON’u parse eder
  - Password masking (logda şifre görünmez) korunur

- `esp_flash_stub_json.py` ✅/🟡  
  - Firmware klasöründeki uygun `.bin` dosyasını bulur
  - Flash işlemini yapar
  - Son durumda ESP8266 üzerinde “FLASH OK / READY” + provision başarılı görüldü (ekran görüntüsü).

> Not: Bazı denemelerde “write_flash is deprecated” gibi esptool uyarıları görülebiliyordu. Son başarılı akışta flash + provision OK.

---

## 3) Firmware Durumu

### 3.1 Firmware klasör yapısı (kritik)
Aşağıdaki klasör ve dosyalar **mutlaka** var olmalı:

```
C:\GitProje\ilkset\helper\firmware\
  stub_esp8266.bin
  stub_esp32c6.bin
```

Bu iki dosya “MISSING_FIRMWARE” hatasını engeller.

### 3.2 ESP8266
- Stub firmware: ✅ stabil
- UART protokol: ✅ @PING/@PONG/@CFG/@ACK OK doğrulandı

### 3.3 ESP32-C6
- Stub `.bin` üretimi geçmişte “C3 board seçilerek” test amaçlı alınmıştı.
- Uzun vadede: ESP-IDF ile native C6 build önerilir.

---

## 4) UI / Flutter Tarafı (FAZ2 UI Refactor Tamam)

### 4.1 UI Hedefi
Kullanıcının çizdiği skeçlere göre iki ekranlı yapı:

**Ekran A — Ports Dashboard**
- Üst bar: “ILKSET”, “Ports: N”, “Scan Ports (N)”
- COM portlar kart olarak grid (responsive: 3/2/1)
- Kart içinde:
  - Port adı (COMx)
  - Status (Unknown / Programmable / Not Programmable)
  - Favori (Star)
  - Büyük **Play** butonu (Port detay ekranına geçiş)
  - Probe butonu (probe çağırır)
- Alt panel: “Açıklama / Probe Çıktısı (COMx)” → son 8 satır log

**Ekran B — Port Detay / Provision**
- AppBar: “ILKSET / COMx”, status badge (Programmable vs)
- SSID / Password girişleri
- IP / Gateway / Mask alanları (ops.)
- Büyük “KAYDET / PROVISION” butonu
- Alt panel: “Console / Tail Log” (200 satıra kadar)

### 4.2 Kritik düzeltme: CardTheme derleme hatası
AG tarafından yazılan kodda:
- `ThemeData.cardTheme: CardTheme(...)` kullanılmıştı.
- Bu Flutter sürümünde hata verdi:
  - `CardTheme` yerine `CardThemeData` kullanılmalı.

Bu düzeltmeyle proje derlenip çalıştı.

### 4.3 Advanced / Gelişmiş kaldırıldı
Kullanıcı isteği:
- IP/Gateway/Mask alanları “Advanced” altında katlanmasın
- Hepsi tek seferde görünür olsun

Bu doğrultuda:
- `_showAdvanced`, InkWell ve AnimatedSize bölümü kaldırıldı
- IP/Gateway/Mask her zaman görünür

---

## 5) Son Görülen Başarılı Akış (Ekran Log)

Başarılı örnek (ESP8266, COM7):

- Probe OK (Programmable)
- Provision zinciri:
  - “FLASH OK / READY”
  - “PROVISION: @ACK OK”

Masking:
- `--pass XXXXX` logda görülüyor (şifre gizleniyor) ✅

---

## 6) Mevcut Kaynaklar / Dosyalar

### 6.1 Dizinler
```
C:\GitProje\ilkset\helper\
  venv\
  esp_probe_json.py
  esp_flash_stub_json.py
  esp_provision_json.py
  firmware\ (stub bin’ler burada)

C:\GitProje\ilkset\ilkset_app\lib\main.dart
```

### 6.2 Önemli not
- Flutter tarafında Python helper çalıştırma: `Process.run` (20s timeout)
- stdout içinde JSON satırı “{...}” yakalanıp parse ediliyor (log karışıklığına dayanıklı)

---

## 7) Bilinen Riskler / Teknik Borç (FAZ2 Sonrası)

1. **Flash helper’ın esptool argümanları**
   - Esptool sürümlerinde `write_flash` → `write-flash` geçişi gibi uyarılar çıkabilir.
   - Bazı senaryolarda bu uyarılar “fail” gibi görünüp akışı kesebilir.
   - Çözüm: `esp_flash_stub_json.py` içinde kullanılan esptool komutlarını stabilize etmek.

2. **ESP32-C6 üretim derleme**
   - C3 üzerinden alınan `.bin` test amaçlı.
   - Gerçek C6 için ESP-IDF pipeline netleştirilmeli.

3. **Path/Working directory bağımlılıkları**
   - Helper scriptleri mümkünse `__file__` bazlı absolute path kullanmalı.
   - (Şu an sabit absolute path ile çalışıyor: C:\GitProje\ilkset\helper\...)

4. **Flash → Provision otomatik akış**
   - UI tarafında buton ile zincir çalışıyor; daha “fail-safe” hale getirilebilir (retry, settle delay, port reset handling).

---

## 8) Sonraki Adımlar (Önerilen)

### A) Flash tarafını “production hardening”
- `esp_flash_stub_json.py` içinde:
  - Esptool komut satırını standardize et
  - Uyarıları fail gibi işaretlemeyecek şekilde ayrıştır
  - Timeout / reset / boot settle sürelerini netleştir

### B) Cihaz durum modelini güçlendir
- Port başına:
  - lastProbe timestamp
  - lastProvision timestamp
  - lastError
  - “Connected / Disconnected” state

### C) UI mikro-iyileştirmeler
- Dashboard’da kartın altındaki log paneline:
  - “Copy” butonu
  - “Clear logs” butonu
- Port detail’de:
  - “Probe” butonunu formun üstüne daha yakınlaştırma
  - Provision success sonrası dashboard’a dönüş + kart status güncelleme

---

## 9) Yeni Sohbette Başlarken (Kopya Mesaj Önerisi)

Yeni sohbetin ilk mesajı olarak şunu kullan:

- “ILKSET FAZ2’deyim. Flutter UI refactor tamamlandı (dashboard kart grid + play ile detay ekranı + console log). ESP8266 üzerinde flash+provision çalışıyor ve @ACK OK alıyorum. Şu an hedefim esp_flash_stub_json.py’yi production-hardening yapmak (esptool write_flash/write-flash ve uyarı/exitCode ayrıştırması). Klasör yapım C:\GitProje\ilkset\helper\firmware altında stub_esp8266.bin ve stub_esp32c6.bin mevcut. main.dart CardThemeData fixli.”

---

## 10) Hızlı Kontrol Komutları

### Helper tarafı
```powershell
cd C:\GitProje\ilkset\helper
venv\Scripts\python.exe esp_probe_json.py --port COM7
venv\Scripts\python.exe esp_flash_stub_json.py --port COM7
venv\Scripts\python.exe esp_provision_json.py --port COM7 --ssid test --pass 12345678
```

### Flutter tarafı
```powershell
cd C:\GitProje\ilkset\ilkset_app
flutter clean
flutter pub get
flutter run -d windows
```

---

**Doküman Bitiş.**
