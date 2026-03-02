# Phase 2.1 Production Hardening

## Goal Description
Enhance the existing demo to a "production-ready helper chain" configuration by implementing an automated Flash -> Provision sequence in the Flutter app, masking sensitive password information in UI logs, standardizing the JSON response contract across all Python scripts, hardening the helper script paths in Dart, and ensuring robust firmware error handling during flashing.

## Proposed Changes

### Dart Code (`ilkset_app/lib/main.dart`)
#### [MODIFY] main.dart
- **Constants**: Extract Python and helper script paths into top-level static `const` variables.
- **Log Masking**: Update `_runHelper` to accept an optional `List<String> displayArgs`. If provided, use it for generating the `logCmd`. In `_provisionPort`, pass a masked version of arguments where the password follows `--pass` is replaced with `"XXXXX"`.
- **Automatic Chain**: Update `_provisionPort` so that when the user starts provisioning, it first invokes `esp_flash_stub_json.py`.
  - If it succeeds (`ok: true`), it continues to run `esp_provision_json.py`.
  - If it fails, the provision process stops and reports the failure.
  - The Flash helper naturally detects if a stub is already present and returns `ok: true`, naturally continuing the chain without redundant re-flashes.
- **Error Handling**: Validate the existence of the scripts using `File(path).existsSync()` and return clear UI messages when paths are missing or invalid, avoiding `Directory.current` dependencies.

---

### Python Helper Scripts (`helper/`)

#### [MODIFY] esp_probe_json.py
- **Standardized Output**: Update the JSON response to include `"stage": "probe"`, `"elapsed_ms"`, and `"tail_log"` fields to comply with the new standard contract.
- Calculate elapsed time accurately.

#### [MODIFY] esp_flash_stub_json.py
- **Standardized Output**: Add `"stage": "flash"`.
- **Firmware Checks**: Ensure we return a distinct `MISSING_FIRMWARE` error message when the expected firmware binary is absent within the `firmware/` directory, and don't create it automatically.
- **Argument Parsing**: Switch to `parse_known_args()` to improve flexibility and robust execution.

#### [MODIFY] esp_provision_json.py
- **Standardized Output**: Add `"stage": "provision"`.
- Make sure all edge cases properly emit the agreed-upon JSON keys.

## Verification Plan

### Automated Tests
This phase consists of application hardening; manual verification is the primary method to validate UI components and end-to-end communication with the serial port.

### Manual Verification
1. **Trigger the Provision Button**: Open the Flutter app, find the target port, fill in the SSID and Password. Press "Provision".
2. **Observe the Logs Check**:
   - The log area should show the execution of the `flash` stage first, followed by the `provision` stage in the same block.
   - Check that the debug log statement masks the password like `ARGS=[--port COM3 --ssid my_wifi --pass XXXXX ...]`.
3. **Firmware Test Check**: Rename the `firmware` folder to `firmware_temp` to trigger a failure. Click Provision; you should see a `MISSING_FIRMWARE` error gracefully caught and displayed on the UI. Restore the folder afterward.
4. **Valid Provision Check**: The final provision should succeed and display a green success indicator, with `esp_provision_json.py` connecting successfully using the stub.

### Provision Chain Flow Diagram
```text
[Provision Button Clicked]
           |
           v
[Run `esp_flash_stub_json.py`]
           |
      Is stub present/flashed successfully?
      /               \
   [No (ok:false)]    [Yes (ok:true)]
        |                  |
        v                  v
[Show Error in UI]   [Run `esp_provision_json.py`]
                           |
                     Provisioning Result JSON
                           |
                     Show logs & final success/fail status
```
