# esp_probe.py
# Amaç: Takılan kart ESP mi ve UART bootloader üzerinden programlanabilir mi? -> esptool handshake testi.
# Bu sürüm: her port/baud denemesinde timeout + takılmadan devam eder.

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import List, Optional, Tuple

try:
    import serial.tools.list_ports
except Exception:
    print("pyserial yok gibi görünüyor. Şunu çalıştır:")
    print("  python -m pip install pyserial")
    raise

BAUD_CANDIDATES = [921600, 460800, 230400, 115200]  # hızlıdan yavaşa

# Windows'ta sık görülen "cevap vermeyen" portlar:
DEFAULT_SKIP_PORTS = {"COM1"}  # istersek genişletiriz

@dataclass
class ProbeResult:
    port: str
    ok: bool
    baud: Optional[int] = None
    chip: Optional[str] = None
    mac: Optional[str] = None
    flash_size: Optional[str] = None
    raw: str = ""
    hint: str = ""

def run_esptool(args: List[str], timeout_s: int) -> subprocess.CompletedProcess:
    # venv içinde: python -m esptool ... daha güvenli
    cmd = [sys.executable, "-m", "esptool"] + args
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)

def parse_esptool_output(txt: str) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    chip = None
    mac = None
    flash_size = None

    m = re.search(r"Chip is ([^\n\r]+)", txt)
    if m:
        chip = m.group(1).strip()

    if chip is None:
        m2 = re.search(r"Detecting chip type\.\.\.\s*([^\n\r]+)", txt)
        if m2:
            chip = m2.group(1).strip()

    m3 = re.search(r"MAC:\s*([0-9a-fA-F:]{17})", txt)
    if m3:
        mac = m3.group(1)

    m4 = re.search(r"Flash size:\s*([^\n\r]+)", txt)
    if m4:
        flash_size = m4.group(1).strip()

    return chip, mac, flash_size

def friendly_hint(stderr_or_out: str) -> str:
    t = stderr_or_out.lower()
    if "access is denied" in t or "permission" in t:
        return "Port başka bir uygulama tarafından kullanılıyor olabilir."
    if "could not open port" in t:
        return "Port açılamadı (meşgul/izin/sürücü)."
    if "failed to connect" in t or "timed out" in t:
        return "Bootloader cevap vermedi (BOOT/FLASH mod gerekebilir / yanlış port)."
    if "invalid head of packet" in t:
        return "Yanlış baud/yanlış port ya da hat gürültüsü."
    if "no serial data received" in t:
        return "Hiç veri gelmedi (yanlış COM / kablo / auto-reset yok)."
    return "Detay için raw çıktıyı incele."

def list_ports(with_desc: bool = False):
    items = []
    for p in serial.tools.list_ports.comports():
        # p.device: "COM8"
        # p.description: "USB-SERIAL CH340" gibi
        # p.hwid: ...
        if with_desc:
            items.append((p.device, p.description or "", p.hwid or ""))
        else:
            items.append(p.device)
    if with_desc:
        return sorted(items, key=lambda x: x[0])
    return sorted(items)

def probe_port(port: str, baud: int, timeout_s: int, trace: bool = False) -> ProbeResult:
    # 'chip_id' çoğu çipte yeterli
    args = ["--port", port, "--baud", str(baud), "chip_id"]
    if trace:
        args.insert(0, "--trace")

    try:
        p = run_esptool(args, timeout_s=timeout_s)
        out = (p.stdout or "") + ("\n" + p.stderr if p.stderr else "")
        chip, mac, flash_size = parse_esptool_output(out)

        if p.returncode == 0:
            return ProbeResult(
                port=port, ok=True, baud=baud,
                chip=chip, mac=mac, flash_size=flash_size,
                raw=out, hint="OK"
            )

        return ProbeResult(
            port=port, ok=False, baud=baud,
            chip=chip, mac=mac, flash_size=flash_size,
            raw=out, hint=friendly_hint(out)
        )

    except subprocess.TimeoutExpired:
        return ProbeResult(
            port=port, ok=False, baud=baud,
            raw="TIMEOUT",
            hint=f"Timeout ({timeout_s}s): cevap yok."
        )
    except Exception as e:
        return ProbeResult(
            port=port, ok=False, baud=baud,
            raw=str(e),
            hint="Beklenmeyen hata."
        )

def main():
    ap = argparse.ArgumentParser(description="ESP USB/UART programlanabilir mi? -> esptool handshake probe")
    ap.add_argument("--port", help="Tek port dene (örn COM8). Vermezsen uygun portlar denenir.")
    ap.add_argument("--baud", type=int, default=0, help="Tek baud dene. 0 ise adaylar denenir.")
    ap.add_argument("--timeout", type=int, default=3, help="Her esptool denemesi için timeout (saniye).")
    ap.add_argument("--trace", action="store_true", help="esptool --trace (çok detaylı)")
    ap.add_argument("--all", action="store_true", help="COM1 gibi portları da dahil et (normalde skip).")
    ap.add_argument("--list", action="store_true", help="Portları açıklamalarıyla listele ve çık.")
    args = ap.parse_args()

    if args.list:
        print("=== PORT LIST ===")
        for dev, desc, hwid in list_ports(with_desc=True):
            print(f"{dev:6} | {desc} | {hwid}")
        return 0

    # Port seti
    if args.port:
        ports = [args.port]
    else:
        ports = list_ports()

    if not ports:
        print("Hiç seri port bulunamadı.")
        return 2

    if (not args.all) and (not args.port):
        ports = [p for p in ports if p.upper() not in DEFAULT_SKIP_PORTS]

    bauds = [args.baud] if args.baud else BAUD_CANDIDATES

    print("=== ESP PROBE ===")
    print("Ports:", ", ".join(ports))
    print("Bauds:", ", ".join(map(str, bauds)))
    print("Timeout per try:", f"{args.timeout}s")
    print()

    any_ok = False

    for port in ports:
        print(f"[{port}]")
        best_fail: Optional[ProbeResult] = None

        for b in bauds:
            r = probe_port(port, b, timeout_s=args.timeout, trace=args.trace)
            if r.ok:
                any_ok = True
                print(f"  ✅ PROGRAMLANABİLİR (esptool OK) @ {b} baud")
                if r.chip: print(f"  Chip: {r.chip}")
                if r.mac:  print(f"  MAC : {r.mac}")
                if r.flash_size: print(f"  Flash: {r.flash_size}")
                break
            else:
                if best_fail is None:
                    best_fail = r

        else:
            # hiç break olmadı => hepsi fail
            print("  ❌ EL SIKIŞMA YOK (programlanabilirliği doğrulayamadım)")
            if best_fail:
                print(f"  Hint: {best_fail.hint}")

        print()

    if any_ok:
        print("SONUÇ: En az 1 port ESP bootloader ile konuştu ✅")
        return 0

    print("SONUÇ: Hiçbir port esptool handshake vermedi ❌")
    print("Not: Bazı kartlarda BOOT/FLASH tuşuna basılı tutup RESET atarak denemek gerekir.")
    return 1

if __name__ == "__main__":
    raise SystemExit(main())