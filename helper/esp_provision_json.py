import argparse
import json
import time
import serial

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
    buf = ""
    while time.time() < deadline_s:
        chunk = ser.read(256)
        if not chunk:
            continue
        try:
            buf += chunk.decode("utf-8", errors="replace")
        except Exception:
            buf += str(chunk)

        buf = buf.replace("\r\n", "\n").replace("\r", "\n")

        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue

            tail_log.append(line)
            if len(tail_log) > 20:
                tail_log.pop(0)

            for pfx in want_prefixes:
                if line.startswith(pfx):
                    return line
    return None

def mask_password_in_text(text, password):
    if not password or len(password.strip()) == 0:
        return text
    return text.replace(password, "XXXXX")


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
        print(json.dumps({
            "port": args.port, "ok": ok,
            "message": mask_password_in_text(ack, args.password),
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