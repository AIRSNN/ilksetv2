#include <Preferences.h> // EEPROM yerine Preferences (NVS) kullanımı
#include <WiFi.h>


// =========================
// CONFIG (Preferences)
// =========================
static const char *PREFS_NAMESPACE = "ilkset";
Preferences prefs;

struct NetCfg {
  uint16_t version;
  char ssid[33];
  char pass[65];
  uint8_t useStatic; // 0/1
  uint8_t ip[4];
  uint8_t gw[4];
  uint8_t mask[4];
  uint8_t dns1[4];
  uint8_t dns2[4];
};

NetCfg g_cfg;

// =========================
// ASYNC WIFI STATE MACHINE
// =========================
enum WifiState {
  STATE_IDLE,
  STATE_CONNECTING,
  STATE_CONNECTED,
  STATE_AP_FALLBACK
};

WifiState currentWifiState = STATE_IDLE;
uint32_t connectionStartTime = 0;
const uint32_t CONNECTION_TIMEOUT_MS = 20000;

static uint32_t msNow() { return millis(); }

static void cfgDefault() {
  memset(&g_cfg, 0, sizeof(g_cfg));
  g_cfg.version = 1;
  g_cfg.useStatic = 1;

  g_cfg.ip[0] = 192;
  g_cfg.ip[1] = 168;
  g_cfg.ip[2] = 55;
  g_cfg.ip[3] = 27;
  g_cfg.gw[0] = 192;
  g_cfg.gw[1] = 168;
  g_cfg.gw[2] = 55;
  g_cfg.gw[3] = 1;
  g_cfg.mask[0] = 255;
  g_cfg.mask[1] = 255;
  g_cfg.mask[2] = 255;
  g_cfg.mask[3] = 0;
  g_cfg.dns1[0] = 192;
  g_cfg.dns1[1] = 168;
  g_cfg.dns1[2] = 55;
  g_cfg.dns1[3] = 1;
  g_cfg.dns2[0] = 8;
  g_cfg.dns2[1] = 8;
  g_cfg.dns2[2] = 8;
  g_cfg.dns2[3] = 8;
}

static bool cfgLoad() {
  prefs.begin(PREFS_NAMESPACE, true); // Read-only
  if (!prefs.isKey("version")) {
    prefs.end();
    return false;
  }
  g_cfg.version = prefs.getUShort("version", 1);
  prefs.getBytes("ssid", g_cfg.ssid, sizeof(g_cfg.ssid));
  prefs.getBytes("pass", g_cfg.pass, sizeof(g_cfg.pass));
  g_cfg.useStatic = prefs.getUChar("useStatic", 0);
  prefs.getBytes("ip", g_cfg.ip, 4);
  prefs.getBytes("gw", g_cfg.gw, 4);
  prefs.getBytes("mask", g_cfg.mask, 4);
  prefs.getBytes("dns1", g_cfg.dns1, 4);
  prefs.getBytes("dns2", g_cfg.dns2, 4);
  prefs.end();
  return true;
}

static void cfgSave() {
  prefs.begin(PREFS_NAMESPACE, false); // Read-write
  prefs.putUShort("version", g_cfg.version);
  prefs.putBytes("ssid", g_cfg.ssid, sizeof(g_cfg.ssid));
  prefs.putBytes("pass", g_cfg.pass, sizeof(g_cfg.pass));
  prefs.putUChar("useStatic", g_cfg.useStatic);
  prefs.putBytes("ip", g_cfg.ip, 4);
  prefs.putBytes("gw", g_cfg.gw, 4);
  prefs.putBytes("mask", g_cfg.mask, 4);
  prefs.putBytes("dns1", g_cfg.dns1, 4);
  prefs.putBytes("dns2", g_cfg.dns2, 4);
  prefs.end();
}

static void cfgErase() {
  cfgDefault();
  prefs.begin(PREFS_NAMESPACE, false);
  prefs.clear();
  prefs.end();
}

// =========================
// WIFI CONTROL
// =========================
static String macSuffix4() {
  uint8_t m[6];
  WiFi.macAddress(m);
  char buf[5];
  snprintf(buf, sizeof(buf), "%02X%02X", m[4], m[5]);
  return String(buf);
}

static IPAddress ipFrom4(const uint8_t a[4]) {
  return IPAddress(a[0], a[1], a[2], a[3]);
}

static void startAPFallback() {
  WiFi.mode(WIFI_AP);
  String ap = "ILKSET-" + macSuffix4();
  WiFi.softAP(ap.c_str());
  IPAddress apIP(192, 168, 4, 1);
  IPAddress apGW(192, 168, 4, 1);
  IPAddress apMask(255, 255, 255, 0);
  WiFi.softAPConfig(apIP, apGW, apMask);

  Serial.println("@INFO AP_MODE");
  Serial.print("@INFO SSID ");
  Serial.println(ap);
  Serial.print("@INFO IP ");
  Serial.println(WiFi.softAPIP().toString());
  currentWifiState = STATE_AP_FALLBACK;
}

static void startConnectSTA() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);

  if (g_cfg.useStatic) {
    IPAddress ip = ipFrom4(g_cfg.ip);
    IPAddress gw = ipFrom4(g_cfg.gw);
    IPAddress mk = ipFrom4(g_cfg.mask);
    IPAddress d1 = ipFrom4(g_cfg.dns1);
    IPAddress d2 = ipFrom4(g_cfg.dns2);

    bool ok = WiFi.config(ip, gw, mk, d1, d2);
    Serial.print("@INFO STATICCFG ");
    Serial.println(ok ? "OK" : "FAIL");
  }

  if (strlen(g_cfg.ssid) == 0) {
    Serial.println("@INFO NO_SSID");
    startAPFallback();
    return;
  }

  WiFi.begin(g_cfg.ssid, g_cfg.pass);
  currentWifiState = STATE_CONNECTING;
  connectionStartTime = msNow();
}

// =========================
// UART LINE PARSER
// =========================
static String lineBuf;

static void sendInfo() {
  Serial.println("@INFO OK");
  Serial.print("@INFO CHIP ESP32C6\n");
  Serial.print("@INFO MAC ");
  Serial.println(WiFi.macAddress());
  Serial.print("@INFO MODE ");
  Serial.println((WiFi.getMode() == WIFI_STA) ? "STA" : "AP");
  Serial.print("@INFO WIFI_STATUS ");
  Serial.println((int)WiFi.status());
  Serial.print("@INFO IP ");
  Serial.println((WiFi.getMode() == WIFI_STA) ? WiFi.localIP().toString()
                                              : WiFi.softAPIP().toString());
  if (WiFi.getMode() == WIFI_STA && WiFi.status() == WL_CONNECTED) {
    Serial.print("@INFO SSID ");
    Serial.println(WiFi.SSID());
    Serial.print("@INFO RSSI ");
    Serial.println(WiFi.RSSI());
  }
}

static bool jsonGetString(const String &js, const char *key, char *out,
                          size_t outSz) {
  String k = String("\"") + key + "\"";
  int i = js.indexOf(k);
  if (i < 0)
    return false;
  i = js.indexOf(':', i);
  if (i < 0)
    return false;
  int q1 = js.indexOf('"', i + 1);
  if (q1 < 0)
    return false;
  int q2 = js.indexOf('"', q1 + 1);
  if (q2 < 0)
    return false;
  String v = js.substring(q1 + 1, q2);
  v.trim();
  if (v.length() >= (int)outSz)
    v = v.substring(0, outSz - 1);
  strncpy(out, v.c_str(), outSz);
  out[outSz - 1] = 0;
  return true;
}

static bool parseIPv4(const String &s, uint8_t out[4]) {
  int p1 = s.indexOf('.');
  int p2 = s.indexOf('.', p1 + 1);
  int p3 = s.indexOf('.', p2 + 1);
  if (p1 < 0 || p2 < 0 || p3 < 0)
    return false;

  int a = s.substring(0, p1).toInt();
  int b = s.substring(p1 + 1, p2).toInt();
  int c = s.substring(p2 + 1, p3).toInt();
  int d = s.substring(p3 + 1).toInt();
  if (a < 0 || a > 255 || b < 0 || b > 255 || c < 0 || c > 255 || d < 0 ||
      d > 255)
    return false;

  out[0] = a;
  out[1] = b;
  out[2] = c;
  out[3] = d;
  return true;
}

static bool jsonGetIP(const String &js, const char *key, uint8_t out[4]) {
  char tmp[32] = {0};
  if (!jsonGetString(js, key, tmp, sizeof(tmp)))
    return false;
  return parseIPv4(String(tmp), out);
}

static bool jsonGetBool(const String &js, const char *key, bool &out) {
  String k = String("\"") + key + "\"";
  int i = js.indexOf(k);
  if (i < 0)
    return false;
  i = js.indexOf(':', i);
  if (i < 0)
    return false;
  String tail = js.substring(i + 1);
  tail.trim();
  if (tail.startsWith("true")) {
    out = true;
    return true;
  }
  if (tail.startsWith("false")) {
    out = false;
    return true;
  }
  if (tail.startsWith("1")) {
    out = true;
    return true;
  }
  if (tail.startsWith("0")) {
    out = false;
    return true;
  }
  return false;
}

static void handleCfg(const String &payloadJson) {
  char ssid[33] = {0}, pass[65] = {0};
  bool hasSsid = jsonGetString(payloadJson, "ssid", ssid, sizeof(ssid));
  bool hasPass = jsonGetString(payloadJson, "pass", pass, sizeof(pass));

  if (hasSsid)
    strncpy(g_cfg.ssid, ssid, sizeof(g_cfg.ssid));
  if (hasPass)
    strncpy(g_cfg.pass, pass, sizeof(g_cfg.pass));

  bool st;
  if (jsonGetBool(payloadJson, "static", st))
    g_cfg.useStatic = st ? 1 : 0;

  uint8_t tmp[4];
  if (jsonGetIP(payloadJson, "ip", tmp))
    memcpy(g_cfg.ip, tmp, 4);
  if (jsonGetIP(payloadJson, "gw", tmp))
    memcpy(g_cfg.gw, tmp, 4);
  if (jsonGetIP(payloadJson, "mask", tmp))
    memcpy(g_cfg.mask, tmp, 4);
  if (jsonGetIP(payloadJson, "dns1", tmp))
    memcpy(g_cfg.dns1, tmp, 4);
  if (jsonGetIP(payloadJson, "dns2", tmp))
    memcpy(g_cfg.dns2, tmp, 4);

  cfgSave();

  Serial.println("@ACK OK");
  Serial.println("@INFO APPLYING");

  startConnectSTA();
}

static void handleLine(String ln) {
  ln.trim();
  if (ln.length() == 0)
    return;

  if (ln == "@PING") {
    Serial.println("@PONG ESP32C6");
    return;
  }
  if (ln == "@INFO") {
    sendInfo();
    return;
  }
  if (ln == "@REBOOT") {
    Serial.println("@ACK OK");
    delay(100);
    ESP.restart();
    return;
  }
  if (ln == "@ERASE") {
    cfgErase();
    Serial.println("@ACK OK");
    Serial.println("@INFO ERASED");
    return;
  }

  if (ln.startsWith("@CFG")) {
    int brace = ln.indexOf('{');
    if (brace < 0) {
      Serial.println("@ACK ERR BAD_CFG_NO_JSON");
      return;
    }
    String js = ln.substring(brace);
    js.trim();
    if (!js.startsWith("{") || !js.endsWith("}")) {
      Serial.println("@ACK ERR BAD_CFG_JSON");
      return;
    }
    handleCfg(js);
    return;
  }

  Serial.println("@ACK ERR UNKNOWN_CMD");
}

// USB CDC (Native USB) için bekleme fonksiyonu
void waitForSerial(uint32_t timeoutMs) {
  uint32_t start = millis();
  while (!Serial && (millis() - start) < timeoutMs) {
    delay(10);
  }
}

// =========================
// SETUP / LOOP
// =========================
void setup() {
  Serial.begin(115200);
  Serial.setTxBufferSize(1024); // Tamponu genişlet
  waitForSerial(2000);          // USB Enumeration için bekle

  Serial.println();
  Serial.println("@BOOT ILKSET_PROD_ESP32C6 v3_CDC_STABLE");

  bool ok = cfgLoad();
  if (!ok) {
    cfgDefault();
    cfgSave();
    Serial.println("@INFO CFG_DEFAULTED");
  } else {
    Serial.println("@INFO CFG_LOADED");
  }

  startConnectSTA();
  Serial.println("@READY");
}

void loop() {
  // 1. Seri Port Okuma (Öncelikli)
  while (Serial && Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\r')
      continue;
    if (c == '\n') {
      String ln = lineBuf;
      lineBuf = "";
      handleLine(ln);
    } else {
      if (lineBuf.length() < 300)
        lineBuf += c;
    }
  }

  // 2. Asenkron WiFi Durum Kontrolü
  if (currentWifiState == STATE_CONNECTING) {
    if (WiFi.status() == WL_CONNECTED) {
      currentWifiState = STATE_CONNECTED;
      Serial.println("@INFO WIFI_CONNECTED");
      Serial.print("@INFO IP ");
      Serial.println(WiFi.localIP().toString());
      Serial.print("@INFO RSSI ");
      Serial.println(WiFi.RSSI());
      Serial.println("@ACK OK WIFI_JOINED");
    } else if (msNow() - connectionStartTime > CONNECTION_TIMEOUT_MS) {
      currentWifiState = STATE_AP_FALLBACK;
      Serial.print("@INFO WIFI_FAIL ");
      Serial.println((int)WiFi.status());
      Serial.println("@ACK ERR WIFI_JOIN_FAIL");
      startAPFallback();
    }
  }

  delay(1);
  yield();
}
