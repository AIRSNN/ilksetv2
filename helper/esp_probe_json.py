import sys
import argparse
import json
import subprocess
import re

def probe_port(port, baud, timeout):
    try:
        cmd = [sys.executable, "-m", "esptool", "--port", port, "--baud", str(baud), "--connect-attempts", "2", "read_mac"]
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        output = result.stdout + result.stderr
        
        if result.returncode == 0 and "MAC:" in output:
            chip_match = re.search(r"Detecting chip type\.\.\.\s*(.+)", output)
            mac_match = re.search(r"MAC:\s*([0-9a-fA-F:]+)", output)
            
            return {
                "port": port,
                "ok": True,
                "chip": chip_match.group(1).strip() if chip_match else "Unknown ESP",
                "mac": mac_match.group(1).strip() if mac_match else "Unknown",
                "baud": baud,
                "message": "PROGRAMLANABİLİR"
            }
        else:
            err_msg = "Bağlantı kurulamadı veya uyumsuz çip."
            if "PermissionError" in output or "Access is denied" in output:
                err_msg = "Port başka bir uygulama tarafından kullanılıyor."
            elif "A fatal error occurred:" in output:
                err_start = output.find("A fatal error occurred:")
                err_msg = output[err_start:].split('\n')[0].strip()
            
            return {"port": port, "ok": False, "message": err_msg}
            
    except subprocess.TimeoutExpired:
        return {"port": port, "ok": False, "message": "Zaman aşımı (Timeout)."}
    except Exception as e:
        return {"port": port, "ok": False, "message": str(e)}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Probe ESP device on a specific port and return JSON.')
    parser.add_argument('--port', required=True, help='Serial port (e.g., COM3)')
    parser.add_argument('--baud', type=int, default=115200, help='Baud rate')
    parser.add_argument('--timeout', type=float, default=8.0, help='Timeout in seconds')
    parser.add_argument('--trace', action='store_true', help='Trace output (ignored)')
    args = parser.parse_args()
    
    print(json.dumps(probe_port(args.port, args.baud, args.timeout)))