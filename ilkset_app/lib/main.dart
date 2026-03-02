import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppController.instance.init();
  runApp(const IlksetApp());
}

class IlksetApp extends StatelessWidget {
  const IlksetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ILKSET',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Helvetica',
        fontFamilyFallback: const ['Arial', 'Noto Sans', 'sans-serif'],
        colorScheme: const ColorScheme.dark(
          primary: Colors.blueAccent,
          onPrimary: Colors.white,
          surface: Color(0xFF1E1E1E),
        ),

        // ✅ FIX: CardTheme -> CardThemeData (senin Flutter sürümün bunu istiyor)
        cardTheme: CardThemeData(
          color: const Color(0xFF252525),
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      home: const PortsDashboardPage(),
    );
  }
}

enum ProbeStatus { unknown, probing, programmable, notProgrammable }
enum ProvisionStatus { idle, provisioning, success, fail }

/// Global App Controller state for managing port lifecycles
class AppController extends ChangeNotifier {
  static final AppController instance = AppController();

  final Map<String, PortState> ports = {};
  Timer? _scanTimer;
  PortState? activePanelPort;

  void init() {
    rescan();
    _scanTimer = Timer.periodic(const Duration(seconds: 1), (_) => rescan());
  }

  void rescan({bool force = false}) {
    final list = SerialPort.availablePorts;
    bool changed = false;

    for (final p in list) {
      if (!ports.containsKey(p)) {
        ports[p] = PortState(port: p);
        changed = true;
      }
    }

    final existing = ports.keys.toList();
    for (final p in existing) {
      if (!list.contains(p)) {
        ports.remove(p);
        if (activePanelPort?.port == p) {
          activePanelPort = null;
        }
        changed = true;
      }
    }

    if (changed || force) notifyListeners();
  }
}

/// State and logic dedicated to an individual serial port
class PortState extends ChangeNotifier {
  final String port;
  bool isFavorite = false;
  ProbeStatus probeStatus = ProbeStatus.unknown;
  ProvisionStatus provStatus = ProvisionStatus.idle;

  Map<String, dynamic>? lastProbe;
  Map<String, dynamic>? lastProvision;

  List<String> logs = [];

  String ssid = "";
  String pass = "";
  String ip = "";
  String gw = "";
  String mask = "";
  String currentAction = "";

  PortState({required this.port});

  void toggleFavorite() {
    isFavorite = !isFavorite;
    notifyListeners();
  }

  void addLog(String line) {
    logs.add(line);
    if (logs.length > 200) {
      logs.removeAt(0);
    }
    notifyListeners();
  }

  static const String _pythonExe =
      r"C:\GitProje\ilkset\helper\venv\Scripts\python.exe";
  static const String _probeScript =
      r"C:\GitProje\ilkset\helper\esp_probe_json.py";
  static const String _flashScript =
      r"C:\GitProje\ilkset\helper\esp_flash_stub_json.py";
  static const String _provisionScript =
      r"C:\GitProje\ilkset\helper\esp_provision_json.py";

  String _oneLine(String s) {
    final x = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (x.isEmpty) return "";
    final line = x.split('\n').first.trim();
    if (line.length > 220) return "${line.substring(0, 220)}…";
    return line;
  }

  Future<Map<String, dynamic>> _runHelper(
    String scriptPath,
    List<String> scriptArgs, {
    List<String>? displayArgs,
  }) async {
    final py = _pythonExe;
    final argsForLog = displayArgs ?? scriptArgs;
    final logCmd =
        "PY=python SCRIPT=${scriptPath.split(r'\').last} ARGS=[${argsForLog.join(' ')}]";

    if (!File(py).existsSync()) {
      return {
        "ok": false,
        "message": "python.exe (venv) bulunamadı: $py",
        "cmd": logCmd
      };
    }
    if (!File(scriptPath).existsSync()) {
      return {
        "ok": false,
        "message": "helper betiği bulunamadı: $scriptPath",
        "cmd": logCmd
      };
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
      // JSON Parse öncesi tek satır JSON'u güvenle ayıkla
      String jsonStr = "{}";
      final lines = stdoutStr.split('\n');
      for (var line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
          jsonStr = trimmed;
          break;
        }
      }

      final obj = json.decode(jsonStr);
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
        "cmd": logCmd,
      };
    } catch (_) {
      return {
        "ok": false,
        "message": "JSON Parse Hatası",
        "exitCode": result.exitCode,
        "stdout": _oneLine(stdoutStr),
        "cmd": logCmd,
      };
    }
  }

  Future<void> probePort() async {
    if (probeStatus == ProbeStatus.probing) return;

    probeStatus = ProbeStatus.probing;
    notifyListeners();
    addLog("PROBE: başlatılıyor...");

    final out = await _runHelper(_probeScript, ["--port", port]);

    lastProbe = out;
    final ok = out["ok"] == true;
    probeStatus = ok ? ProbeStatus.programmable : ProbeStatus.notProgrammable;

    if (out["cmd"] != null) addLog("> ${out["cmd"]}");

    final msg = (out["message"] ?? "").toString();
    final chip = (out["chip"] ?? "").toString();
    final mac = (out["mac"] ?? "").toString();

    addLog(ok ? "✅ PROBE: $msg" : "❌ PROBE: $msg");
    if (chip.isNotEmpty && chip != "null") addLog("chip: $chip | mac: $mac");

    final stderr = (out["stderr"] ?? "").toString();
    if (!ok && stderr.isNotEmpty && stderr != "null") addLog("stderr: $stderr");

    notifyListeners();
  }

  Future<void> provisionPort() async {
    if (provStatus == ProvisionStatus.provisioning) return;

    if (ssid.trim().isEmpty || pass.trim().isEmpty) {
      provStatus = ProvisionStatus.fail;
      currentAction = "";
      addLog("❌ PROVISION: SSID ve Password zorunlu.");
      notifyListeners();
      return;
    }

    provStatus = ProvisionStatus.provisioning;
    currentAction = "Flashing...";
    notifyListeners();
    addLog("PROVISION: script çağrılıyor...");

    // ZİNCİR 1: FLASH STUB
    final flashArgs = ["--port", port];
    final flashOut = await _runHelper(_flashScript, flashArgs);

    if (flashOut["ok"] != true) {
      lastProvision = flashOut;
      provStatus = ProvisionStatus.fail;
      currentAction = "";
      if (flashOut["cmd"] != null) addLog("> ${flashOut["cmd"]}");
      addLog("❌ FLASH FAIL: ${flashOut["message"]}");
      final stderr = (flashOut["stderr"] ?? "").toString();
      if (stderr.isNotEmpty && stderr != "null") addLog("stderr: $stderr");
      notifyListeners();
      return;
    }

    addLog("✅ FLASH OK / READY");
    currentAction = "Provisioning...";
    notifyListeners();

    // ZİNCİR 2: PROVISIONING
    final args = [
      "--port",
      port,
      "--ssid",
      ssid.trim(),
      "--pass",
      pass.trim(),
    ];

    final displayArgs = [
      "--port",
      port,
      "--ssid",
      ssid.trim(),
      "--pass",
      "XXXXX",
    ];

    if (ip.trim().isNotEmpty) {
      args.addAll(["--ip", ip.trim()]);
      displayArgs.addAll(["--ip", ip.trim()]);
    }
    if (gw.trim().isNotEmpty) {
      args.addAll(["--gw", gw.trim()]);
      displayArgs.addAll(["--gw", gw.trim()]);
    }
    if (mask.trim().isNotEmpty) {
      args.addAll(["--mask", mask.trim()]);
      displayArgs.addAll(["--mask", mask.trim()]);
    }

    final out = await _runHelper(_provisionScript, args, displayArgs: displayArgs);

    lastProvision = out;
    final ok = out["ok"] == true;
    provStatus = ok ? ProvisionStatus.success : ProvisionStatus.fail;
    currentAction = ok ? "Done" : "";

    if (out["cmd"] != null) addLog("> ${out["cmd"]}");

    final msg = (out["message"] ?? "").toString();
    addLog(ok ? "✅ PROVISION: $msg" : "❌ PROVISION: $msg");

    final stderr = (out["stderr"] ?? "").toString();
    if (!ok && stderr.isNotEmpty && stderr != "null") addLog("stderr: $stderr");

    notifyListeners();
  }
}

// =========================================================================
// EKRAN A: DASHBOARD
// =========================================================================

class PortsDashboardPage extends StatefulWidget {
  const PortsDashboardPage({super.key});

  @override
  State<PortsDashboardPage> createState() => _PortsDashboardPageState();
}

class _PortsDashboardPageState extends State<PortsDashboardPage> {
  @override
  void initState() {
    super.initState();
    AppController.instance.addListener(_onRebuild);
  }

  @override
  void dispose() {
    AppController.instance.removeListener(_onRebuild);
    super.dispose();
  }

  void _onRebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ports = AppController.instance.ports.values.toList();

    // Sort logic: Favorites first, then alphabetically
    ports.sort((a, b) {
      if (a.isFavorite && !b.isFavorite) return -1;
      if (!a.isFavorite && b.isFavorite) return 1;
      return a.port.compareTo(b.port);
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "ILKSET",
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        actions: [
          Center(
            child: Text(
              "Ports: ${ports.length}",
              style: const TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(width: 24),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            child: ElevatedButton.icon(
              onPressed: () => AppController.instance.rescan(force: true),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text("Scan Ports (${ports.length})"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ports.isEmpty
                ? const Center(
                    child: Text(
                      "Port bulunamadı. Bir ESP cihazını USB ile bağlayın ve tarayın.",
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      int cols = constraints.maxWidth > 900
                          ? 3
                          : (constraints.maxWidth > 600 ? 2 : 1);
                      return GridView.builder(
                        padding: const EdgeInsets.all(24),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisExtent: 220, // fixed card height
                          crossAxisSpacing: 24,
                          mainAxisSpacing: 24,
                        ),
                        itemCount: ports.length,
                        itemBuilder: (context, i) =>
                            PortCard(portState: ports[i]),
                      );
                    },
                  ),
          ),
          const DashboardLogPanel(),
        ],
      ),
    );
  }
}

class PortCard extends StatelessWidget {
  final PortState portState;
  const PortCard({super.key, required this.portState});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: portState,
      builder: (context, _) {
        Color statusColor;
        String statusText;
        switch (portState.probeStatus) {
          case ProbeStatus.programmable:
            statusColor = Colors.greenAccent;
            final chip = portState.lastProbe?["chip"] ?? "ESP";
            statusText = "Programmable ($chip)";
            break;
          case ProbeStatus.notProgrammable:
            statusColor = Colors.redAccent;
            statusText = "Not Programmable";
            break;
          case ProbeStatus.probing:
            statusColor = Colors.orangeAccent;
            statusText = "Probing...";
            break;
          case ProbeStatus.unknown:
          default:
            statusColor = Colors.grey;
            statusText = "Unknown";
            break;
        }

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      portState.port,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        portState.isFavorite ? Icons.star : Icons.star_border,
                        color: portState.isFavorite ? Colors.amber : Colors.grey,
                      ),
                      onPressed: () => portState.toggleFavorite(),
                      tooltip: "Favori",
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  "Status: $statusText",
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Center(
                  child: Material(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withOpacity(0.15),
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: () {
                        AppController.instance.activePanelPort = portState;
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PortDetailPage(portState: portState),
                          ),
                        );
                      },
                      customBorder: const CircleBorder(),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Icon(
                          Icons.play_arrow,
                          size: 40,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 36,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      side: BorderSide(color: Colors.white.withOpacity(0.1)),
                    ),
                    onPressed: portState.probeStatus == ProbeStatus.probing
                        ? null
                        : () {
                            AppController.instance.activePanelPort = portState;
                            portState.probePort();
                          },
                    icon: portState.probeStatus == ProbeStatus.probing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bolt, size: 16),
                    label: const Text("Probe"),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class DashboardLogPanel extends StatefulWidget {
  const DashboardLogPanel({super.key});

  @override
  State<DashboardLogPanel> createState() => _DashboardLogPanelState();
}

class _DashboardLogPanelState extends State<DashboardLogPanel> {
  PortState? _currentPort;

  @override
  void initState() {
    super.initState();
    AppController.instance.addListener(_onAppChanged);
    _onAppChanged();
  }

  void _onAppChanged() {
    final active = AppController.instance.activePanelPort;
    if (_currentPort != active) {
      _currentPort?.removeListener(_onPortChanged);
      _currentPort = active;
      _currentPort?.addListener(_onPortChanged);
      if (mounted) setState(() {});
    }
  }

  void _onPortChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppController.instance.removeListener(_onAppChanged);
    _currentPort?.removeListener(_onPortChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentPort == null) return const SizedBox.shrink();

    // Sadece son 8 satırı göster
    final logs = _currentPort!.logs;
    final displayLogs = logs.length > 8 ? logs.sublist(logs.length - 8) : logs;

    return Container(
      height: 180,
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Açıklama / Probe Çıktısı (${_currentPort!.port})",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Colors.blueAccent.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                displayLogs.isEmpty ? "Henüz log yok." : displayLogs.join("\n"),
                style: const TextStyle(
                  fontFamily: "Consolas",
                  fontSize: 13,
                  color: Colors.white70,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// EKRAN B: PORT DETAIL / PROVISION
// =========================================================================

class PortDetailPage extends StatefulWidget {
  final PortState portState;
  const PortDetailPage({super.key, required this.portState});

  @override
  State<PortDetailPage> createState() => _PortDetailPageState();
}

class _PortDetailPageState extends State<PortDetailPage> {
  bool _obscurePass = true;

  void _showInfoDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Kapat"),
          )
        ],
      ),
    );
  }

  Future<void> _runProvisionAction(PortState st) async {
    await st.provisionPort();
    if (!mounted) return;
    if (st.provStatus == ProvisionStatus.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Provision Başarılı!'),
          backgroundColor: Colors.green,
        ),
      );
    } else if (st.provStatus == ProvisionStatus.fail) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Provision Başarısız. Logları inceleyin.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.portState,
      builder: (context, _) {
        final st = widget.portState;

        Color statusColor;
        String statusText;
        switch (st.probeStatus) {
          case ProbeStatus.programmable:
            statusColor = Colors.greenAccent;
            statusText = "Programmable";
            break;
          case ProbeStatus.notProgrammable:
            statusColor = Colors.redAccent;
            statusText = "Not Programmable";
            break;
          case ProbeStatus.probing:
            statusColor = Colors.orangeAccent;
            statusText = "Probing...";
            break;
          default:
            statusColor = Colors.grey;
            statusText = "Unknown";
            break;
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(
              "ILKSET / ${st.port}",
              style: const TextStyle(letterSpacing: 1.1),
            ),
            actions: [
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: statusColor.withOpacity(0.4)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.note_alt_outlined, size: 22),
                tooltip: "Notlar eklentisi (opsiyonel)",
                onPressed: () => _showInfoDialog(
                  "Notlar",
                  "Bu porta ait özel notlar buraya eklenebilir.",
                ),
              ),
              IconButton(
                icon: const Icon(Icons.info_outline, size: 22),
                tooltip: "Device Info",
                onPressed: () {
                  final chip = st.lastProbe?["chip"] ?? "Bilinmiyor";
                  final mac = st.lastProbe?["mac"] ?? "Bilinmiyor";
                  _showInfoDialog("Device Info", "Chip: $chip\nMAC: $mac");
                },
              ),
              IconButton(
                icon: const Icon(Icons.bolt, size: 22),
                tooltip: "Tekrar Probe Et",
                onPressed: st.probeStatus == ProbeStatus.probing
                    ? null
                    : () => st.probePort(),
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 32,
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "WiFi ve Network Ayarları",
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 24),
                          _buildTextField(
                            "WiFi Name (SSID) *",
                            st.ssid,
                            (v) => st.ssid = v,
                          ),
                          const SizedBox(height: 16),
                          _buildPasswordField(
                            "Password *",
                            st.pass,
                            (v) => st.pass = v,
                          ),
                          const SizedBox(height: 24),
                          Opacity(
                            opacity: 0.75,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildTextField(
                                  "IP (ops.)",
                                  st.ip,
                                  (v) => st.ip = v,
                                  hint: "Örn: 192.168.1.50",
                                ),
                                const SizedBox(height: 16),
                                _buildTextField(
                                  "Gateway (ops.)",
                                  st.gw,
                                  (v) => st.gw = v,
                                  hint: "Örn: 192.168.1.1",
                                ),
                                const SizedBox(height: 16),
                                _buildTextField(
                                  "Mask (ops.)",
                                  st.mask,
                                  (v) => st.mask = v,
                                  hint: "Örn: 255.255.255.0",
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 48),
                          SizedBox(
                            width: double.infinity,
                            height: 60,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    Theme.of(context).colorScheme.primary,
                                foregroundColor:
                                    Theme.of(context).colorScheme.onPrimary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              onPressed:
                                  st.provStatus == ProvisionStatus.provisioning
                                      ? null
                                      : () => _runProvisionAction(st),
                              icon: st.provStatus == ProvisionStatus.provisioning
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.upload_rounded, size: 24),
                              label: Text(
                                st.provStatus == ProvisionStatus.provisioning
                                    ? (st.currentAction.isNotEmpty
                                        ? st.currentAction
                                        : "Provisioning...")
                                    : "KAYDET / PROVISION",
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _buildConsolePanel(st),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTextField(
    String label,
    String initial,
    Function(String) onChanged, {
    String? hint,
  }) {
    return TextFormField(
      initialValue: initial,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      ),
    );
  }

  Widget _buildPasswordField(
    String label,
    String initial,
    Function(String) onChanged,
  ) {
    return TextFormField(
      initialValue: initial,
      onChanged: onChanged,
      obscureText: _obscurePass,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePass ? Icons.visibility : Icons.visibility_off,
            color: Colors.grey,
          ),
          onPressed: () => setState(() => _obscurePass = !_obscurePass),
        ),
      ),
    );
  }

  Widget _buildConsolePanel(PortState st) {
    return Container(
      height: 250,
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF101010),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              const Text(
                "Console / Tail Log",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                st.logs.isEmpty ? "Henüz log yok." : st.logs.join("\n"),
                style: const TextStyle(
                  fontFamily: "Consolas",
                  fontSize: 13,
                  color: Colors.lightGreenAccent,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}