# ILKSET – Provisioning & Flash Pipeline Context (FAZ 2)

## 1. Proje Özeti
ILKSET projesi, seri port (UART) üzerinden ESP tabanlı cihazların:

1. Otomatik olarak algılanması (Probe)
2. Gerekirse stub firmware ile flash edilmesi
3. WiFi konfigürasyonunun (SSID/Password + opsiyonel IP bilgileri) provision edilmesi

amaçlarını taşıyan bir Flutter + Python helper zincirinden oluşmaktadır.

Sistem tamamen lokal çalışacak şekilde tasarlanmıştır (Windows 10 + Python venv + Flutter Desktop).

---

## 2. Proje Yapısı

```
C:\GitProje\ilkset\
│
├── helper\
│   ├── venv\
│   ├── esp_probe_json.py
│   ├── esp_flash_stub_json.py
│   ├── esp_provision_json.py
│   └── firmware\
│       ├── stub_esp8266.bin
│       └── stub_esp32c6.bin
│
└── ilkset_app\
    └── lib\
        └── main.dart
```

---

## 3. Mevcut Mimari

### 3.1 Flutter Uygulaması
- Seri portları listeler.
- "Probe" ile cihazın programlanabilir olup olmadığını test eder.
- "Provision" butonu ile otomatik zincir başlatır.
- Python helper scriptlerini Process.start ile çalıştırır.
- Script çıktısı JSON olarak parse edilir.
- UI log alanında maskeleme uygulanır (şifre loga açık düşmez).

---

### 3.2 Python Helper Scriptleri

#### esp_probe_json.py
Amaç:
- Seri porta bağlanır
- @PING gönderir
- @PONG bekler
- JSON çıktı üretir

JSON Kontratı:
```
{
  "stage": "probe",
  "port": "COMx",
  "ok": true/false,
  "chip": "ESP8266/ESP32",
  "message": "...",
  "baud": 115200,
  "elapsed_ms": 123,
  "tail_log": []
}
```

---

#### esp_flash_stub_json.py
Amaç:
- firmware klasöründe uygun .bin dosyasını arar
- Cihaz tipine göre stub firmware flash eder
- Başarılıysa ok:true döndürür

Beklenen firmware yolu:
```
helper\firmware\stub_esp8266.bin
helper\firmware\stub_esp32c6.bin
```

Hata senaryosu:
```
MISSING_FIRMWARE
```

---

#### esp_provision_json.py
Amaç:
- @PING
- @CFG {json}
- @ACK OK bekleme
- Tek satır geçerli JSON çıktısı üretme

Örnek başarılı çıktı:
```
{
  "stage": "provision",
  "port": "COM8",
  "ok": true,
  "message": "@ACK OK",
  "baud": 115200,
  "elapsed_ms": 1239,
  "tail_log": ["@PONG ESP8266", "@ACK OK"]
}
```

---

## 4. Stub Firmware Durumu

### 4.1 ESP8266
- Arduino IDE ile derlendi
- Tek .bin dosya üretildi
- firmware klasörüne kopyalandı
- UART protokolü stabil çalışıyor

Protokol:
- @PING → @PONG ESP8266
- @CFG → EEPROM yazımı → @ACK OK

Durum: Çalışır ve test edildi.

---

### 4.2 ESP32-C6
- NVS (Preferences) tabanlı stub yazıldı
- Arduino IDE üzerinden .bin üretildi
- firmware klasörüne stub_esp32c6.bin eklendi

Not:
Arduino IDE’de C6 board desteği sürüme bağlı olabilir.
Şu an üretim yöntemi C3 tabanlı derleme üzerinden test edilmiştir.
Gelecekte ESP-IDF ile native C6 derleme önerilir.

---

## 5. Provision Zinciri (Hedef Akış)

Provision Butonu Basıldığında:

1. esp_flash_stub_json.py çalışır
2. ok:true ise
3. esp_provision_json.py çalışır
4. Sonuç UI’da gösterilir

Akış:

```
[Provision Click]
        ↓
[Flash Stub]
   ok:false → UI Error
   ok:true  →
        ↓
[Provision]
        ↓
[Success / Fail]
```

---

## 6. Çözülen Problemler

- Boot settle süresi eklendi
- Seri port temizleme eklendi
- JSON çıktısı tek satır ve parse edilebilir hale getirildi
- Password log masking kurgulandı
- Firmware klasörü manuel yaratma gerekliliği netleştirildi

---

## 7. Bekleyen İşler

- Flash → Provision zincirinin Flutter içinde otomatikleştirilmesi
- Tüm helper scriptlerinde JSON kontratının tam standardizasyonu
- ESP32-C6 için üretim derleme sürecinin netleştirilmesi
- Path bağımlılıklarının sabitlenmesi (Directory.current bağımlılığı kaldırılmalı)
- Hata mesajlarının kullanıcı dostu hale getirilmesi

---

## 8. Test Komutları

### Manuel Provision Testi
```
cd C:\GitProje\ilkset\helper
venv\Scripts\python.exe esp_provision_json.py --port COM8 --ssid test --pass 12345678
```

### Manuel Flash Testi
```
venv\Scripts\python.exe esp_flash_stub_json.py --port COM8
```

---

## 9. Mevcut Stabilite

UART tabanlı Probe ve Provision akışı ESP8266 üzerinde %100 stabil.

Flash + Provision zinciri yapılandırma aşamasında.

---

Bu doküman, yeni bir sohbet başlatıldığında projenin bağlamını hızlıca yeniden kurmak için hazırlanmıştır.

