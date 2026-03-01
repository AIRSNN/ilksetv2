import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

void main() {
  runApp(const IlksetApp());
}

class IlksetApp extends StatelessWidget {
  const IlksetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ILKSET',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const ProbeHomePage(),
    );
  }
}

enum ProbeStatus { unknown, probing, programmable, notProgrammable }
enum ProvisionStatus { idle, provisioning, success, fail }

class PortState {
  final String port;
  ProbeStatus probeStatus;
  ProvisionStatus provStatus;

  Map<String, dynamic>? lastProbe;
  Map<String, dynamic>? lastProvision;

  final List<String> logs;

  String ssid = "";
  String pass = "";
  String ip = "";
  String gw = "";
  String mask = "";

  PortState({
    required this.port,
    this.probeStatus = ProbeStatus.unknown,
    this.provStatus = ProvisionStatus.idle,
    this.lastProbe,
    this.lastProvision,
    List<String>? logs,
  }) : logs = logs ?? <String>[];

  void addLog(String line) {
    logs.add(line);
    while (logs.length > 8) {
      logs.removeAt(0);
    }
  }
}

class ProbeHomePage extends StatefulWidget {
  const ProbeHomePage({super.key});

  @override
  State<ProbeHomePage> createState() => _ProbeHomePageState();
}

class _ProbeHomePageState extends State<ProbeHomePage> {
  final Map<String, PortState> _ports = {};
  Timer? _scanTimer;

  @override
  void initState() {
    super.initState();
    _rescan();
    _scanTimer = Timer.periodic(const Duration(seconds: 1), (_) => _rescan());
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  void _rescan() {
    final list = SerialPort.availablePorts;

    for (final p in list) {
      _ports.putIfAbsent(p, () => PortState(port: p));
    }

    final existing = _ports.keys.toList();
    for (final p in existing) {
      if (!list.contains(p)) _ports.remove(p);
    }

    if (mounted) setState(() {});
  }

  Color _probeColor(ProbeStatus s) {
    switch (s) {
      case ProbeStatus.programmable: return Colors.green;
      case ProbeStatus.notProgrammable: return Colors.red;
      case ProbeStatus.probing: return Colors.orange;
      case ProbeStatus.unknown: default: return Colors.grey;
    }
  }

  String _probeText(ProbeStatus s) {
    switch (s) {
      case ProbeStatus.programmable: return "PROGRAMMABLE";
      case ProbeStatus.notProgrammable: return "NOT_PROGRAMMABLE";
      case ProbeStatus.probing: return "PROBING";
      case ProbeStatus.unknown: default: return "UNKNOWN";
    }
  }

  Color _provColor(ProvisionStatus s) {
    switch (s) {
      case ProvisionStatus.success: return Colors.green;
      case ProvisionStatus.fail: return Colors.red;
      case ProvisionStatus.provisioning: return Colors.orange;
      case ProvisionStatus.idle: default: return Colors.grey;
    }
  }

  String _provText(ProvisionStatus s) {
    switch (s) {
      case ProvisionStatus.success: return "SUCCESS";
      case ProvisionStatus.fail: return "FAIL";
      case ProvisionStatus.provisioning: return "PROVISIONING";
      case ProvisionStatus.idle: default: return "IDLE";
    }
  }

  // TEKNİK KARAR DOSYA YOLLARI - Kesin sabit path
  String _helperPythonPath() => r"C:\GitProje\ilkset\helper\venv\Scripts\python.exe";
  String _probeScriptPath() => r"C:\GitProje\ilkset\helper\esp_probe_json.py";
  String _provisionScriptPath() => r"C:\GitProje\ilkset\helper\esp_provision_json.py";

  String _oneLine(String s) {
    final x = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (x.isEmpty) return "";
    final line = x.split('\n').first.trim();
    if (line.length > 220) return "${line.substring(0, 220)}…";
    return line;
  }

  Future<Map<String, dynamic>> _runHelper(String scriptPath, List<String> scriptArgs) async {
    final py = _helperPythonPath();
    final logCmd = "PY=python SCRIPT=${scriptPath.split(r'\').last} ARGS=[${scriptArgs.join(' ')}]";

    if (!File(py).existsSync()) {
      return {"ok": false, "message": "python.exe (venv) bulunamadı: $py"};
    }
    if (!File(scriptPath).existsSync()) {
      return {"ok": false, "message": "helper betiği bulunamadı: $scriptPath"};
    }

    ProcessResult result;
    try {
      result = await Process.run(
        py,
        [scriptPath, ...scriptArgs],
        runInShell: true,
      ).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return {"ok": false, "message": "Zaman aşımı (timeout)", "cmd": logCmd};
    } catch (e) {
      return {"ok": false, "message": "Process başlatılamadı: $e", "cmd": logCmd};
    }

    final stdoutStr = (result.stdout ?? "").toString().trim();
    final stderrStr = (result.stderr ?? "").toString().trim();

    if (stdoutStr.isEmpty) {
      return {
        "ok": false,
        "message": "Script boş çıktı (stdout) üretti",
        "exitCode": result.exitCode,
        "stderr": _oneLine(stderrStr),
        "cmd": logCmd,
      };
    }

    try {
      final obj = json.decode(stdoutStr);
      if (obj is Map<String, dynamic>) {
        if (stderrStr.isNotEmpty) obj["stderr"] = _oneLine(stderrStr);
        if (result.exitCode != 0) obj["exitCode"] = result.exitCode;
        obj["cmd"] = logCmd;
        return obj;
      }
      return {
        "ok": false,
        "message": "Çıktı JSON sözlüğü değil",
        "exitCode": result.exitCode,
        "stdout": _oneLine(stdoutStr),
        "stderr": _oneLine(stderrStr),
        "cmd": logCmd,
      };
    } catch (_) {
      return {
        "ok": false,
        "message": "JSON Parse Hatası",
        "exitCode": result.exitCode,
        "stdout": _oneLine(stdoutStr),
        "stderr": _oneLine(stderrStr),
        "cmd": logCmd,
      };
    }
  }

  Future<void> _probePort(PortState st) async {
    if (st.probeStatus == ProbeStatus.probing) return;

    setState(() {
      st.probeStatus = ProbeStatus.probing;
      st.addLog("PROBE: başlatılıyor...");
    });

    // KESİN DENETİM 1: Probe için sadece --port geçirilir.
    final out = await _runHelper(_probeScriptPath(), ["--port", st.port]);

    setState(() {
      st.lastProbe = out;
      final ok = out["ok"] == true;
      st.probeStatus = ok ? ProbeStatus.programmable : ProbeStatus.notProgrammable;

      if (out["cmd"] != null) st.addLog("> ${out["cmd"]}");

      final msg = (out["message"] ?? "").toString();
      final chip = (out["chip"] ?? "").toString();
      final mac = (out["mac"] ?? "").toString();

      st.addLog(ok ? "✅ PROBE: $msg" : "❌ PROBE: $msg");
      if (chip.isNotEmpty && chip != "null") st.addLog("chip: $chip | mac: $mac");
      
      final stderr = (out["stderr"] ?? "").toString();
      if (!ok && stderr.isNotEmpty && stderr != "null") st.addLog("stderr: $stderr");
    });
  }

  Future<void> _provisionPort(PortState st) async {
    if (st.provStatus == ProvisionStatus.provisioning) return;

    if (st.ssid.trim().isEmpty || st.pass.trim().isEmpty) {
      setState(() {
        st.provStatus = ProvisionStatus.fail;
        st.addLog("❌ PROVISION: SSID ve Password zorunlu.");
      });
      return;
    }

    setState(() {
      st.provStatus = ProvisionStatus.provisioning;
      st.addLog("PROVISION: script çağrılıyor...");
    });

    // KESİN DENETİM 2: Provision için "--port", "--ssid", "--pass" vs. geçirilir.
    final args = [
      "--port", st.port,
      "--ssid", st.ssid.trim(),
      "--pass", st.pass.trim(),
    ];

    if (st.ip.trim().isNotEmpty) args.addAll(["--ip", st.ip.trim()]);
    if (st.gw.trim().isNotEmpty) args.addAll(["--gw", st.gw.trim()]);
    if (st.mask.trim().isNotEmpty) args.addAll(["--mask", st.mask.trim()]);

    final out = await _runHelper(_provisionScriptPath(), args);

    setState(() {
      st.lastProvision = out;
      final ok = out["ok"] == true;
      st.provStatus = ok ? ProvisionStatus.success : ProvisionStatus.fail;

      if (out["cmd"] != null) st.addLog("> ${out["cmd"]}");

      final msg = (out["message"] ?? "").toString();
      st.addLog(ok ? "✅ PROVISION: $msg" : "❌ PROVISION: $msg");

      final stderr = (out["stderr"] ?? "").toString();
      if (!ok && stderr.isNotEmpty && stderr != "null") st.addLog("stderr: $stderr");
    });
  }

  @override
  Widget build(BuildContext context) {
    final ports = _ports.values.toList()..sort((a, b) => a.port.compareTo(b.port));

    return Scaffold(
      appBar: AppBar(
        title: Text("ILKSET - Ports: ${ports.length}"),
        actions: [
          IconButton(tooltip: "Rescan", onPressed: _rescan, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ports.isEmpty
          ? const Center(child: Text("Port bulunamadı. Bir ESP kartı USB ile tak.", style: TextStyle(fontSize: 16)))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: ports.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _portCard(ports[i]),
            ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        border: Border.all(color: color.withOpacity(0.65)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
    );
  }

  Widget _field({
    required String label,
    required String value,
    required void Function(String) onChanged,
    bool obscure = false,
    String hint = "",
  }) {
    return TextField(
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint.isEmpty ? null : hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onChanged,
      controller: TextEditingController.fromValue(
        TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length)),
      ),
    );
  }

  Widget _portCard(PortState st) {
    final probeColor = _probeColor(st.probeStatus);
    final provColor = _provColor(st.provStatus);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(st.port, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
                _badge(_probeText(st.probeStatus), probeColor),
                const SizedBox(width: 8),
                _badge(_provText(st.provStatus), provColor),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: st.probeStatus == ProbeStatus.probing ? null : () => _probePort(st),
                  icon: const Icon(Icons.bolt),
                  label: const Text("Probe"),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text("Provision", style: TextStyle(color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            GridView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 3.2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              children: [
                _field(label: "SSID *", value: st.ssid, onChanged: (v) => st.ssid = v),
                _field(label: "Password *", value: st.pass, obscure: true, onChanged: (v) => st.pass = v),
                _field(label: "IP (ops.)", value: st.ip, hint: "192.168.1.50", onChanged: (v) => st.ip = v),
                _field(label: "Gateway (ops.)", value: st.gw, hint: "192.168.1.1", onChanged: (v) => st.gw = v),
                _field(label: "Mask (ops.)", value: st.mask, hint: "255.255.255.0", onChanged: (v) => st.mask = v),
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: st.provStatus == ProvisionStatus.provisioning ? null : () => _provisionPort(st),
                      icon: const Icon(Icons.upload),
                      label: const Text("Provision"),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Text(
                st.logs.isEmpty ? "log: (empty)" : st.logs.join("\n"),
                style: const TextStyle(fontFamily: "Consolas", fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}