import argparse
import json
import time
import subprocess
import os
import sys

def one_line(s: str, limit: int = 180) -> str:
    s = (s or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    line = s.split("\n")[0].strip() if s else ""
    return (line[:limit] + "…") if len(line) > limit else line

def run_ping_check(port, python_exe, baud):
    script_path = os.path.join(os.path.dirname(__file__), "esp_provision_json.py")
    cmd = [python_exe, script_path, "--port", port, "--baud", str(baud), "--ping-only"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            try:
                out = json.loads(res.stdout.strip())
                if out.get("ok"):
                    return True, out.get("message", "@PONG OK"), out.get("tail_log", [])
            except:
                pass
    except Exception:
        pass
    return False, "NO_PONG", []

def run_chip_detect(port, python_exe, baud):
    cmd = [python_exe, "-m", "esptool", "--port", port, "--baud", str(baud), "--connect-attempts", "7", "chip_id"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
        output = res.stdout + res.stderr
        if res.returncode == 0:
            if "ESP8266" in output:
                return True, "ESP8266", output
            elif "ESP32-C6" in output:
                return True, "ESP32-C6", output
        return False, "UNKNOWN", output
    except Exception as e:
        return False, "ERROR", str(e)

def flash_firmware(port, baud, chip, python_exe):
    firmware_dir = os.path.join(os.path.dirname(__file__), "firmware")
    
    if not os.path.exists(firmware_dir) or not os.path.isdir(firmware_dir):
        return False, f"MISSING_FIRMWARE: Klasör bulunamadı ({firmware_dir})"
        
    if chip == "ESP8266":
        bin_file = "stub_esp8266.bin"
        offset = "0x00000"
    elif chip == "ESP32-C6":
        bin_file = "stub_esp32c6.bin"
        offset = "0x00000"
    else:
        return False, f"UNSUPPORTED_CHIP: {chip}"

    bin_path = os.path.join(firmware_dir, bin_file)
    if not os.path.exists(bin_path):
        return False, f"MISSING_FIRMWARE: Dosya bulunamadı ({bin_path})"

    cmd = [
        python_exe, "-m", "esptool",
        "--port", port,
        "--baud", str(baud),
        "write_flash", offset, bin_path
    ]

    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=40)
        out = res.stdout + res.stderr
        if res.returncode == 0 and ("Hash of data verified" in out or "Leaving" in out):
            return True, "FLASH_SUCCESS"
        return False, f"FLASH_FAILED: {one_line(out)}"
    except subprocess.TimeoutExpired:
        return False, "FLASH_TIMEOUT"
    except Exception as e:
        return False, f"FLASH_ERROR: {str(e)}"

def main():
    ap = argparse.ArgumentParser(description="ILKSET Flash Stub Helper")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--timeout", type=float, default=10.0)
    args, _ = ap.parse_known_args()

    t0 = time.time()
    tail_log = []
    python_exe = sys.executable

    def output_json(ok, chip, message):
        print(json.dumps({
            "port": args.port,
            "ok": ok,
            "chip": chip,
            "message": message,
            "baud": args.baud,
            "stage": "flash",
            "elapsed_ms": int((time.time() - t0) * 1000),
            "tail_log": tail_log[-20:]
        }, ensure_ascii=False))

    try:
        # 1. Stub var mı?
        has_stub, pong_msg, p_logs = run_ping_check(args.port, python_exe, args.baud)
        tail_log.extend(p_logs)
        if has_stub:
            output_json(True, "UNKNOWN", "STUB_ALREADY_PRESENT")
            return

        # 2. Chip Tespiti
        detect_ok, chip, detect_out = run_chip_detect(args.port, python_exe, args.baud)
        tail_log.extend(detect_out.splitlines()[-5:])
        if not detect_ok:
            output_json(False, chip, f"CHIP_DETECT_FAILED: {chip}")
            return

        # 3. Yükleme
        flash_ok, flash_msg = flash_firmware(args.port, args.baud, chip, python_exe)
        tail_log.append(flash_msg)
        if not flash_ok:
            output_json(False, chip, flash_msg)
            return

        # 4. Doğrulama
        time.sleep(2.0)
        verify_ok, verify_msg, v_logs = run_ping_check(args.port, python_exe, 115200) # Stub default 115200'de açılır
        tail_log.extend(v_logs)

        if verify_ok:
            output_json(True, chip, "FLASH_OK")
        else:
            output_json(False, chip, "FLASH_DONE_BUT_NO_PONG")

    except Exception as e:
        output_json(False, "UNKNOWN", f"FATAL_ERROR: {str(e)}")

if __name__ == "__main__":
    main()
