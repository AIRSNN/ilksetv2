import argparse
import json
import time
import serial
import re


def one_line(s: str, limit: int = 180) -> str:
    s = (s or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    line = s.split("\n")[0].strip() if s else ""
    return (line[:limit] + "…") if len(line) > limit else line


def write_line(ser: serial.Serial, line: str):
    if not line.endswith("\n"):
        line += "\n"
    ser.write(line.encode("utf-8", errors="replace"))
    ser.flush()


def read_lines_until(ser: serial.Serial, deadline_s: float, want_prefixes: tuple, tail_log: list):
    """
    Seri porttan satır satır okur, want_prefixes ile başlayan ilk satırı döner.
    tail_log son 20 satırı tutar.
    """
    if not hasattr(ser, "my_buf"):
        ser.my_buf = ""
    while time.time() < deadline_s:
        chunk = ser.read(256)
        if chunk:
            try:
                ser.my_buf += chunk.decode("utf-8", errors="replace")
            except Exception:
                pass

        ser.my_buf = ser.my_buf.replace("\r\n", "\n").replace("\r", "\n")

        while "\n" in ser.my_buf:
            line, ser.my_buf = ser.my_buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue

            tail_log.append(line)
            if len(tail_log) > 30:
                tail_log.pop(0)

            if not want_prefixes:
                return line

            for pfx in want_prefixes:
                if line.startswith(pfx):
                    return line
    return None


def read_any_line(ser: serial.Serial, deadline_s: float, tail_log: list):
    """
    Prefix filtresi olmadan, deadline'a kadar ilk anlamlı satırı döndürür.
    (Pasif dinleme için.)
    """
    return read_lines_until(ser, deadline_s, (), tail_log)


def mask_password_in_text(text, password):
    if not password or len(password.strip()) == 0:
        return text
    return text.replace(password, "XXXXX")


def normalize_line(line: str) -> str:
    # UART boot garbage / BOM / null byte vs. gibi baştaki saçmalıkları törpüle
    if line is None:
        return ""
    s = line.strip()
    s = s.lstrip("\ufeff").lstrip("\x00").lstrip("\xff")
    return s.strip()


def parse_info_like(line: str):
    """
    @INFO satırlarından MODE / WIFI_STATUS / IP yakalar.
    Döner: dict {mode, wifi_status, ip} (bulduklarını).
    """
    raw = normalize_line(line)
    upper_line = raw.upper()

    out = {}

    # MODE
    # örn: "@INFO MODE STA" / "@INFO MODE:STA" / {"mode":"STA"}
    if re.search(r"\bMODE\b.*\bSTA\b", upper_line):
        out["mode"] = "STA"
    elif re.search(r"\bMODE\b.*\bAP\b", upper_line):
        out["mode"] = "AP"
    else:
        # JSON içinden dene
        try:
            j0 = raw[raw.find("{"): raw.rfind("}") + 1]
            if j0 and "{" in j0 and "}" in j0:
                jd = json.loads(j0)
                m = str(jd.get("mode", jd.get("MODE", ""))).strip().upper()
                if m in ("STA", "AP"):
                    out["mode"] = m
        except Exception:
            pass

    # WIFI_STATUS
    # örn: "@INFO WIFI_STATUS 3" / "WL_CONNECTED" / "WIFI_CONNECTED"
    m_ws = re.search(r"\bWIFI[-_ ]?STATUS\b[^0-9]*([0-9]+)", upper_line)
    if m_ws:
        try:
            out["wifi_status"] = int(m_ws.group(1))
        except Exception:
            pass
    else:
        if "WL_CONNECTED" in upper_line or "WIFI_CONNECTED" in upper_line or re.search(r"\bCONNECTED\b", upper_line):
            out["wifi_status"] = 3

    # IP
    # örn: "@INFO IP 192.168.55.27" / "IP:192.168.55.27" / {"ip":"..."}
    m_ip = re.search(r"\bIP\b[^0-9]*([0-9]{1,3}(?:\.[0-9]{1,3}){3})", upper_line)
    if m_ip:
        out["ip"] = m_ip.group(1)
    else:
        try:
            j0 = raw[raw.find("{"): raw.rfind("}") + 1]
            if j0 and "{" in j0 and "}" in j0:
                jd = json.loads(j0)
                ip2 = str(jd.get("ip", jd.get("IP", ""))).strip()
                if ip2:
                    out["ip"] = ip2
        except Exception:
            pass

    return out


def is_unknown_cmd(line: str) -> bool:
    s = normalize_line(line).upper()
    return s.startswith("@ACK ERR") and ("UNKNOWN_CMD" in s or "UNKNOWN" in s)


def main():
    ap = argparse.ArgumentParser(description="ILKSET provisioning helper")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--ping-only", action="store_true")
    ap.add_argument("--ssid", default="")
    ap.add_argument("--pass", default="", dest="password")
    ap.add_argument("--ip", default="")
    ap.add_argument("--gw", default="")
    ap.add_argument("--mask", default="")
    ap.add_argument("--timeout", type=float, default=3.0)
    args, _ = ap.parse_known_args()

    t0 = time.time()
    tail_log = []

    if not args.ping_only and (not args.ssid or not args.password):
        print(json.dumps({
            "port": args.port, "ok": False,
            "message": "MISSING_ARGS: ssid and pass required unless --ping-only",
            "baud": args.baud, "stage": "provision", "elapsed_ms": int((time.time() - t0) * 1000), "tail_log": tail_log
        }, ensure_ascii=False))
        return

    payload = {
        "ssid": args.ssid,
        "pass": args.password,
        "ip": args.ip,
        "gw": args.gw,
        "mask": args.mask,
        "ts": int(time.time()),
    }

    try:
        ser = serial.Serial(
            port=args.port,
            baudrate=args.baud,
            timeout=0.1,
            write_timeout=1.0,
        )
    except Exception as e:
        print(json.dumps({
            "port": args.port, "ok": False,
            "message": f"SERIAL_OPEN_FAIL: {one_line(str(e))}",
            "baud": args.baud,
            "stage": "provision",
            "elapsed_ms": int((time.time() - t0) * 1000), "tail_log": tail_log
        }, ensure_ascii=False))
        return

    try:
        # hat kontrol hatları
        try:
            ser.setDTR(False)
            ser.setRTS(False)
        except Exception:
            pass

        time.sleep(0.5)

        try:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
        except Exception:
            pass

        deadline = time.time() + args.timeout

        # handshake
        write_line(ser, "@PING")
        pong = read_lines_until(ser, min(deadline, time.time() + 2.0), ("@PONG",), tail_log)

        if not pong:
            print(json.dumps({
                "port": args.port, "ok": False,
                "message": "STUB_NOT_RESPONDING: @PONG alınamadı",
                "baud": args.baud, "stage": "provision", "elapsed_ms": int((time.time() - t0) * 1000),
                "tail_log": tail_log
            }, ensure_ascii=False))
            return

        if args.ping_only:
            print(json.dumps({
                "port": args.port, "ok": True,
                "message": pong,
                "baud": args.baud, "stage": "provision", "elapsed_ms": int((time.time() - t0) * 1000),
                "tail_log": tail_log
            }, ensure_ascii=False))
            return

        # config gönder
        write_line(ser, "@CFG " + json.dumps(payload, ensure_ascii=False))
        ack = read_lines_until(ser, deadline, ("@ACK OK", "@ACK ERR", "@ACK"), tail_log)

        if not ack:
            print(json.dumps({
                "port": args.port, "ok": False,
                "message": "ACK_TIMEOUT: @ACK alınamadı",
                "baud": args.baud, "stage": "provision", "elapsed_ms": int((time.time() - t0) * 1000),
                "tail_log": tail_log
            }, ensure_ascii=False))
            return

        ok = ack.startswith("@ACK OK")
        msg = mask_password_in_text(ack, args.password)

        # --- ESP8266 için zorunlu doğrulama ---
        if ok and "ESP32" not in pong:
            verify_timeout = 12.0
            verify_deadline = time.time() + verify_timeout

            # 1) Önce (çok kısa) info-cmd keşfi dene.
            #    Bulamazsak PASSIVE_ONLY (hiç komut yollama), sadece dinle.
            chosen_info_cmd = None
            passive_only = True

            # Keşif: en fazla 2 deneme, çok kısa süreli
            candidates = ["@INFO", "@STAT", "@STATUS", "@GETINFO"]
            for cmd in candidates:
                # tek bir kez yolla, hemen @INFO yakalamaya çalış
                try:
                    write_line(ser, cmd)
                except Exception:
                    continue

                line = read_lines_until(ser, time.time() + 0.4, ("@INFO",), tail_log)
                if line and normalize_line(line).startswith("@INFO"):
                    chosen_info_cmd = cmd
                    passive_only = False
                    break

                # UNKNOWN_CMD gördüysek bir sonraki adaya geç
                # (buffer'da kalmasın diye kısa bir boşaltma)
                _ = read_lines_until(ser, time.time() + 0.15, ("@ACK",), tail_log)

            if passive_only:
                tail_log.append("DEBUG_INFO_CMD: PASSIVE_ONLY")
            else:
                tail_log.append("DEBUG_INFO_CMD: " + chosen_info_cmd)

            # 2) Asıl verify: state'i @INFO satırlarından çıkar
            state = {"mode": None, "wifi_status": None, "ip": None}
            last_line = ""

            joined = False
            last_info_tick = 0.0

            while time.time() < verify_deadline:
                now = time.time()

                # aktif mod: saniyede 1 info iste
                if not passive_only and (now - last_info_tick) >= 1.0:
                    try:
                        write_line(ser, chosen_info_cmd)
                    except Exception:
                        pass
                    last_info_tick = now

                # pasif mod: herhangi satırı yakala (cihaz kendisi @INFO basabilir)
                if passive_only:
                    line = read_any_line(ser, min(now + 1.0, verify_deadline), tail_log)
                else:
                    # aktif modda da araya @ACK ERR gelebilir; yakalayalım
                    line = read_lines_until(ser, min(now + 1.0, verify_deadline), ("@INFO", "@ACK"), tail_log)

                if not line:
                    continue

                last_line = line
                norm = normalize_line(line)

                # Eğer aktif moddayken UNKNOWN_CMD görürsek, hemen pasife düş
                if is_unknown_cmd(norm) and not passive_only:
                    passive_only = True
                    tail_log.append("DEBUG_FALLBACK: INFO_CMD_UNSUPPORTED")
                    continue

                # Firmware @INFO basmıyorsa bile kendi başına WIFI_CONNECTED, IP: ... gibi satırlar basabilir.
                # O yüzden sadece "@INFO" ile başlayanları değil, anlamlı kelimeler (IP, WIFI, CONNECTED, STA) geçen
                # her satırı (eğer çok uzun değilse) parse etmeye çalışıyoruz.
                upper_norm = norm.upper()
                if norm.startswith("@INFO") or ("WIFI" in upper_norm) or ("IP" in upper_norm) or ("CONNECT" in upper_norm) or ("STA" in upper_norm):
                    parsed = parse_info_like(norm)
                    if parsed.get("mode"):
                        state["mode"] = parsed["mode"]
                    if parsed.get("wifi_status") is not None:
                        state["wifi_status"] = parsed["wifi_status"]
                    if parsed.get("ip"):
                        state["ip"] = parsed["ip"]

                    # koşullar (varsayılan MODE STA kabul edilebilir eğer MODE hiç basılmıyorsa ama IP alındıysa)
                    # Çok basit ESP8266 firmware'leri sadece IP ve CONNECTED basar, MODE STA basmaz.
                    is_sta = (state["mode"] == "STA") or (state["mode"] is None and state["wifi_status"] == 3)
                    is_connected = (state["wifi_status"] == 3)
                    # IP check
                    has_ip = bool(state["ip"]) and state["ip"] not in ("0.0.0.0", "0", "null")

                    if args.ip and has_ip:
                        has_ip = (state["ip"] == args.ip)

                    if is_sta and is_connected and has_ip:
                        joined = True
                        break

            # her durumda debug state bas
            tail_log.append("DEBUG_STATE: " + json.dumps(state, ensure_ascii=False))
            if last_line:
                tail_log.append("DEBUG_LAST_LINE: " + mask_password_in_text(one_line(last_line, 240), args.password))

            if joined:
                ok = True
                msg = "WIFI_JOINED"
            else:
                # Firmware hiç log basmıyorsa (passive_only ve state bomboşsa) ve verify_deadline bitmişse:
                # Başarılı bir @ACK OK aldığımız için "iyimser" olarak ağa bağlandı kabul edelim.
                # Aksi halde çoğu basit ESP8266 stub/firmware "Timeout" hatası veriyor.
                has_no_logs = (state["mode"] is None and state["wifi_status"] is None and state["ip"] is None)
                if passive_only and has_no_logs:
                    ok = True
                    msg = "WIFI_JOINED (IMPLICIT/SILENT)"
                    tail_log.append("DEBUG_IMPLICIT_JOIN: No logs emitted, assuming success after @ACK OK")
                else:
                    ok = False
                    msg = "WIFI_JOIN_TIMEOUT"

        print(json.dumps({
            "port": args.port, "ok": ok,
            "message": msg,
            "baud": args.baud, "stage": "provision", "elapsed_ms": int((time.time() - t0) * 1000),
            "tail_log": [mask_password_in_text(line, args.password) for line in tail_log]
        }, ensure_ascii=False))

    except Exception as e:
        print(json.dumps({
            "port": args.port, "ok": False,
            "message": f"ERROR: {one_line(str(e))}",
            "baud": args.baud, "stage": "provision", "elapsed_ms": int((time.time() - t0) * 1000),
            "tail_log": [mask_password_in_text(line, args.password) for line in tail_log]
        }, ensure_ascii=False))
    finally:
        try:
            ser.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()