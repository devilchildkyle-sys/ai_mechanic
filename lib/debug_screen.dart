import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'main.dart';
import 'nova_chat_screen.dart';
import 'vehicle_profile_screen.dart';

// ─────────────────────────────────────────
//  DEBUG LOG ENTRY
// ─────────────────────────────────────────
class DebugEntry {
  final String command;
  final String rawResponse;
  final String parsed;
  final bool success;
  final DateTime time;

  DebugEntry({
    required this.command,
    required this.rawResponse,
    required this.parsed,
    required this.success,
  }) : time = DateTime.now();
}

// ─────────────────────────────────────────
//  DEBUG OBD2 SERVICE
//  Same as OBD2Service but logs everything
// ─────────────────────────────────────────
class DebugOBD2Service {
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  final List<int> _responseBuffer = [];
  final List<DebugEntry> log = [];

  static const String _veepeakService = '0000fff0-0000-1000-8000-00805f9b34fb';
  static const String _veepeakWrite   = '0000fff2-0000-1000-8000-00805f9b34fb';
  static const String _veepeakNotify  = '0000fff1-0000-1000-8000-00805f9b34fb';

  // All commands we want to test
  static const List<Map<String, String>> testCommands = [
    {'cmd': 'ATZ',   'desc': 'Reset ELM327'},
    {'cmd': 'ATE0',  'desc': 'Echo off'},
    {'cmd': 'ATL0',  'desc': 'Linefeeds off'},
    {'cmd': 'ATS0',  'desc': 'Spaces off'},
    {'cmd': 'ATH0',  'desc': 'Headers off'},
    {'cmd': 'ATSP0', 'desc': 'Auto protocol'},
    {'cmd': 'ATRV',  'desc': 'Battery voltage'},
    {'cmd': 'ATI',   'desc': 'ELM version'},
    {'cmd': 'ATDP',  'desc': 'Current protocol'},
    {'cmd': '0100',  'desc': 'Supported PIDs 01-20'},
    {'cmd': '0120',  'desc': 'Supported PIDs 21-40'},
    {'cmd': '0105',  'desc': 'Coolant temp'},
    {'cmd': '010C',  'desc': 'RPM'},
    {'cmd': '010D',  'desc': 'Vehicle speed'},
    {'cmd': '0111',  'desc': 'Throttle position'},
    {'cmd': '012F',  'desc': 'Fuel level'},
    {'cmd': '0902',  'desc': 'VIN (mode 9 PID 2)'},
    {'cmd': '0900',  'desc': 'VIN supported PIDs'},
    {'cmd': '09 02', 'desc': 'VIN with space'},
    {'cmd': '03',    'desc': 'Read DTCs'},
  ];

  Future<bool> initialize(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();

      // Log all discovered services and characteristics
      for (final service in services) {
        final sid = service.serviceUuid.toString().toLowerCase();
        for (final char in service.characteristics) {
          final cid = char.characteristicUuid.toString().toLowerCase();
          log.add(DebugEntry(
            command: 'DISCOVER',
            rawResponse:
            'Service: $sid\nChar: $cid\nProps: read=${char.properties.read} write=${char.properties.write} writeNoResp=${char.properties.writeWithoutResponse} notify=${char.properties.notify}',
            parsed: 'Found characteristic',
            success: true,
          ));

          if (sid == _veepeakService) {
            if (cid == _veepeakNotify && char.properties.notify) {
              _notifyChar = char;
            }
            if (cid == _veepeakWrite &&
                (char.properties.write ||
                    char.properties.writeWithoutResponse)) {
              _writeChar = char;
            }
          }
          if (_writeChar == null &&
              (char.properties.write ||
                  char.properties.writeWithoutResponse)) {
            _writeChar = char;
          }
          if (_notifyChar == null && char.properties.notify) {
            _notifyChar = char;
          }
        }
      }

      if (_writeChar == null || _notifyChar == null) {
        log.add(DebugEntry(
          command: 'INIT',
          rawResponse: 'writeChar: $_writeChar, notifyChar: $_notifyChar',
          parsed: 'FAILED — could not find write/notify characteristics',
          success: false,
        ));
        return false;
      }

      log.add(DebugEntry(
        command: 'INIT',
        rawResponse:
        'Write: ${_writeChar!.characteristicUuid}\nNotify: ${_notifyChar!.characteristicUuid}',
        parsed: 'SUCCESS — characteristics found',
        success: true,
      ));

      await _notifyChar!.setNotifyValue(true);
      _notifyChar!.lastValueStream.listen((value) {
        _responseBuffer.addAll(value);
      });

      return true;
    } catch (e) {
      log.add(DebugEntry(
        command: 'INIT ERROR',
        rawResponse: e.toString(),
        parsed: 'Exception during init',
        success: false,
      ));
      return false;
    }
  }

  Future<String> sendRaw(String command) async {
    if (_writeChar == null) {
      log.add(DebugEntry(
        command: command,
        rawResponse: 'No write characteristic available',
        parsed: 'FAILED',
        success: false,
      ));
      return '';
    }

    try {
      _responseBuffer.clear();
      final bytes = utf8.encode('$command\r');

      if (_writeChar!.properties.writeWithoutResponse) {
        await _writeChar!.write(bytes, withoutResponse: true);
      } else {
        await _writeChar!.write(bytes);
      }

      // Wait for response — poll every 100ms up to 4 seconds
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        final r = utf8.decode(_responseBuffer, allowMalformed: true);
        if (r.contains('>') || r.contains('ERROR') || r.contains('UNABLE')) {
          break;
        }
      }

      // CRITICAL settle wait: '>' means ELM327 is done but BLE packets
      // are async. A 2nd ECU response or trailing multi-frame bytes may
      // still be queued in the Dart event loop. Wait 120ms for all late
      // bytes to land before snapshotting the buffer, so they don't
      // contaminate the NEXT command after _responseBuffer.clear().
      await Future.delayed(const Duration(milliseconds: 120));

      final rawResponse =
      utf8.decode(_responseBuffer, allowMalformed: true).trim();

      final hexResponse = _responseBuffer
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');

      log.add(DebugEntry(
        command: command,
        rawResponse: 'ASCII: $rawResponse\nHEX: $hexResponse',
        parsed: rawResponse.isEmpty ? 'No response' : rawResponse,
        success: rawResponse.isNotEmpty &&
            !rawResponse.contains('ERROR') &&
            !rawResponse.contains('UNABLE'),
      ));

      return rawResponse;
    } catch (e) {
      log.add(DebugEntry(
        command: command,
        rawResponse: e.toString(),
        parsed: 'Exception',
        success: false,
      ));
      return '';
    }
  }

  /// Sends a bare carriage return to flush any pending adapter output
  /// and waits for the prompt. Call before Mode 22 PID queries to
  /// ensure the adapter is truly idle with a clean buffer.
  Future<void> drainAdapter() async {
    if (_writeChar == null) return;
    _responseBuffer.clear();
    try {
      final bytes = utf8.encode('\r');
      if (_writeChar!.properties.writeWithoutResponse) {
        await _writeChar!.write(bytes, withoutResponse: true);
      } else {
        await _writeChar!.write(bytes);
      }
      for (int i = 0; i < 6; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        final r = utf8.decode(_responseBuffer, allowMalformed: true);
        if (r.contains('>')) break;
      }
      await Future.delayed(const Duration(milliseconds: 150));
      _responseBuffer.clear();
    } catch (_) {}
  }

  Future<void> runFullDiagnostic() async {
    // Init sequence first
    await sendRaw('ATZ');
    await Future.delayed(const Duration(milliseconds: 1000));
    await sendRaw('ATE0');
    await sendRaw('ATL0');
    await sendRaw('ATS0');
    await sendRaw('ATH0');
    await sendRaw('ATSP0');
    await Future.delayed(const Duration(milliseconds: 500));

    // Test all PIDs
    for (final cmd in testCommands.skip(6)) {
      await sendRaw(cmd['cmd']!);
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  // ── POWERSTROKE SPECIFIC TEST PIDs ───────────────────────
  // Each entry: pid hex, human name, formula string, unit, min, max
  // Formula uses A/B as first/second data bytes (header already stripped)
  // rxAddr: which CAN address to filter responses FROM (ATCRA command)
  // txAddr: which CAN address to send requests TO (ATSH command)
  // ECM = 7E8 (request to 7E0), TCM = 7E9 (request to 7E1)
  static const List<Map<String, dynamic>> powerStrokeTests = [
    {
      'pid': '221310', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'Engine Oil Temp',
      'formula': '(((A*256)+B)/100-40)*9/5+32',
      'unit': '°F', 'min': 32.0, 'max': 300.0,
      'note': 'Normal: 160–220°F. VALIDATED vs Torque Pro. Example [43,240]=162°F',
    },
    {
      'pid': '221674', 'rxAddr': '7E9', 'txAddr': '7E1',
      'name': 'Trans Fluid Temp',
      'formula': '((A*256)+B)/8',
      'unit': '°F', 'min': 0.0, 'max': 300.0,
      'note': 'Normal: 80–200°F. From TCM (7E9). VALIDATED. Example [3,33]=100°F',
    },
    {
      'pid': '221446', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'ICP / HPOP Pressure',
      'formula': '((A*256)+B)*0.57',
      'unit': 'psi', 'min': 0.0, 'max': 5000.0,
      'note': 'Normal idle: 400–900psi. Under load: 2000–3500psi. VALIDATED',
    },
    {
      'pid': '221445', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'MAP Pressure',
      'formula': '((A*256)+B)*0.03625',
      'unit': 'psi', 'min': 0.0, 'max': 50.0,
      'note': 'Used with BARO to calc boost. VALIDATED. Example [1,217]=17.1psi',
    },
    {
      'pid': '2209CF', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'FICM Logic Voltage',
      'formula': '((A*256+B)*100/256)/100',
      'unit': 'V', 'min': 40.0, 'max': 56.0,
      'note': 'Normal: 48–49V. Below 48V = FICM starting to fail. VALIDATED',
    },
    {
      'pid': '2209D0', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'FICM Main Voltage',
      'formula': '((A*256)+B)*(100/256)/100',
      'unit': 'V', 'min': 40.0, 'max': 56.0,
      'note': '48V high-voltage system. Normal: 48–50V. Below 48V = FICM failing',
    },
    {
      'pid': '221434', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'IPR Duty Cycle',
      'formula': '(A*13.53)/35',
      'unit': '%', 'min': 0.0, 'max': 100.0,
      'note': '1-byte response — only A is data. May exceed 100% (normal). VALIDATED',
    },
    {
      'pid': '221624', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'Cylinder Head Temp',
      'formula': '(((A*256)+B)*1.999)+32',
      'unit': '°F', 'min': 32.0, 'max': 400.0,
      'note': 'CHT sensor. Normal: similar to coolant temp',
    },
    {
      'pid': '221440', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'MAP (Boost calc)',
      'formula': '((A*256)+B)*0.03625',
      'unit': 'psi', 'min': 0.0, 'max': 50.0,
      'note': 'Subtract BARO (~9.4psi at altitude) to get boost',
    },
    {
      'pid': '221412', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'Mass Fuel Desired',
      'formula': '((A*256)+B)*0.0625',
      'unit': 'mg/stk', 'min': 0.0, 'max': 200.0,
      'note': 'Desired fuel mass per stroke',
    },
    {
      'pid': '22096D', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'VGT Duty Cycle',
      'formula': '((A*256)+B)*(100/32767)',
      'unit': '%', 'min': 0.0, 'max': 100.0,
      'note': 'Variable Geometry Turbo vane position command',
    },
    {
      'pid': '2209CC', 'rxAddr': '7E8', 'txAddr': '7E0',
      'name': 'Injector Timing BTDC',
      'formula': '(((A*256)+B)*(10/64))/10',
      'unit': 'Deg', 'min': -20.0, 'max': 30.0,
      'note': 'Injection timing before top dead center',
    },
  ];

  String exportLog() {
    final buffer = StringBuffer();
    buffer.writeln('=== AI MECHANIC DEBUG LOG ===');
    buffer.writeln('Generated: ${DateTime.now()}');
    buffer.writeln('');
    for (final entry in log) {
      buffer.writeln('[${entry.time.toIso8601String()}]');
      buffer.writeln('CMD: ${entry.command}');
      buffer.writeln('RAW: ${entry.rawResponse}');
      buffer.writeln('STATUS: ${entry.success ? "OK" : "FAIL"}');
      buffer.writeln('---');
    }
    return buffer.toString();
  }
}

// ─────────────────────────────────────────
//  DEBUG SCREEN
// ─────────────────────────────────────────
class DebugScreen extends StatefulWidget {
  final VehicleProfile? vehicleProfile;
  final OBD2Service? mainObdService; // pause its live timer during Powerstroke tests

  const DebugScreen({super.key, this.vehicleProfile, this.mainObdService});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen>
    with SingleTickerProviderStateMixin {
  final _debugService = DebugOBD2Service();
  bool _isRunning = false;
  bool _initialized = false;
  String _currentCmd = '';
  late TabController _tabCtrl;
  final _manualCmdCtrl = TextEditingController();
  final List<_PsTestResult> _psResults = [];
  bool _psRunning = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _manualCmdCtrl.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final connected = FlutterBluePlus.connectedDevices;
    if (connected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No OBD2 device connected. Connect your dongle first.'),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }

    setState(() => _isRunning = true);

    final ok = await _debugService.initialize(connected.first);
    setState(() {
      _initialized = ok;
      _isRunning = false;
    });
  }

  Future<void> _runFullDiagnostic() async {
    if (!_initialized) await _initialize();
    if (!_initialized) return;

    setState(() => _isRunning = true);

    for (final cmd
    in DebugOBD2Service.testCommands.skip(6)) {
      setState(() => _currentCmd = '${cmd['cmd']} — ${cmd['desc']}');
      await _debugService.sendRaw(cmd['cmd']!);
      await Future.delayed(const Duration(milliseconds: 300));
      setState(() {});
    }

    setState(() {
      _isRunning = false;
      _currentCmd = '';
    });
  }

  Future<void> _sendManualCmd() async {
    if (!_initialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Initialize connection first'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }
    final cmd = _manualCmdCtrl.text.trim().toUpperCase();
    if (cmd.isEmpty) return;
    _manualCmdCtrl.clear();
    setState(() => _isRunning = true);
    await _debugService.sendRaw(cmd);
    setState(() => _isRunning = false);
  }

  void _askNova() {
    final logText = _debugService.exportLog();
    final prompt =
        'I am having issues with my OBD2 dongle connection. Here is my full debug log:\n\n$logText\n\nCan you analyze this and tell me:\n1. What is working and what is not\n2. Why the VIN might be reading as UNKNOWN\n3. Which PIDs are responding correctly\n4. What I should try to fix the issues';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NovaChatScreen(
          vehicleProfile: widget.vehicleProfile,
          initialMessage: prompt,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildTabBar(),
              Expanded(
                child: TabBarView(
                  controller: _tabCtrl,
                  children: [
                    _buildLogTab(),
                    _buildManualTab(),
                    _buildSummaryTab(),
                    _buildPowerStrokeTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: AppColors.bgCard.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Icons.arrow_back_rounded,
                  color: AppColors.textPrimary, size: 20),
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('OBD2 Debug Console',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                Text('Raw dongle diagnostics',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          // Nova help button
          GestureDetector(
            onTap: _debugService.log.isEmpty ? null : _askNova,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                gradient: _debugService.log.isEmpty
                    ? null
                    : const LinearGradient(
                    colors: AppColors.primaryGradient),
                color: _debugService.log.isEmpty
                    ? AppColors.bgCard.withOpacity(0.5)
                    : null,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.psychology_rounded,
                      color: Colors.white, size: 16),
                  SizedBox(width: 6),
                  Text('Ask Nova',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.bgCard.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: TabBar(
        controller: _tabCtrl,
        indicator: BoxDecoration(
          gradient:
          const LinearGradient(colors: AppColors.primaryGradient),
          borderRadius: BorderRadius.circular(10),
        ),
        labelColor: Colors.white,
        unselectedLabelColor: AppColors.textMuted,
        labelStyle:
        const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        dividerColor: Colors.transparent,
        tabs: const [
          Tab(text: 'Log'),
          Tab(text: 'Manual'),
          Tab(text: 'Summary'),
          Tab(text: 'Powerstroke'),
        ],
      ),
    );
  }

  // ── LOG TAB ───────────────────────────
  Widget _buildLogTab() {
    return Column(
      children: [
        // Action buttons
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (_isRunning) ...[
                GlassCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.blueElectric),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _currentCmd.isEmpty
                              ? 'Initializing...'
                              : _currentCmd,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      label: _initialized
                          ? 'Run Full Test'
                          : 'Initialize',
                      icon: _initialized
                          ? Icons.play_arrow_rounded
                          : Icons.link_rounded,
                      isLoading: _isRunning,
                      onPressed: _isRunning
                          ? null
                          : _initialized
                          ? _runFullDiagnostic
                          : _initialize,
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _debugService.log.isEmpty
                        ? null
                        : () {
                      Clipboard.setData(ClipboardData(
                          text: _debugService.exportLog()));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Log copied to clipboard'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    child: Container(
                      width: 50, height: 54,
                      decoration: BoxDecoration(
                        color: AppColors.bgCard.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: const Icon(Icons.copy_rounded,
                          color: AppColors.blueBright, size: 20),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Log entries
        Expanded(
          child: _debugService.log.isEmpty
              ? const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.terminal_rounded,
                    color: AppColors.textMuted, size: 48),
                SizedBox(height: 16),
                Text('No data yet',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted)),
                SizedBox(height: 8),
                Text(
                    'Tap Initialize to connect\nthen Run Full Test',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted)),
              ],
            ),
          )
              : ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: _debugService.log.length,
            itemBuilder: (_, i) {
              final entry = _debugService.log[
              _debugService.log.length - 1 - i];
              return _buildLogEntry(entry);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLogEntry(DebugEntry entry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: entry.success
            ? AppColors.bgCard.withOpacity(0.6)
            : AppColors.danger.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: entry.success
              ? AppColors.border
              : AppColors.danger.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                  entry.success ? AppColors.success : AppColors.danger,
                  boxShadow: [
                    BoxShadow(
                      color: entry.success
                          ? AppColors.success.withOpacity(0.6)
                          : AppColors.danger.withOpacity(0.6),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(entry.command,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      color: AppColors.blueElectric)),
              const Spacer(),
              Text(
                '${entry.time.hour}:${entry.time.minute.toString().padLeft(2, '0')}:${entry.time.second.toString().padLeft(2, '0')}',
                style: const TextStyle(
                    fontSize: 9,
                    color: AppColors.textMuted,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(entry.rawResponse,
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  fontFamily: 'monospace',
                  height: 1.4)),
          // Ask Nova about this specific entry
          if (!entry.success) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                final prompt =
                    'I have a specific OBD2 issue. Command: ${entry.command}\nRaw response: ${entry.rawResponse}\n\nWhat does this mean and how do I fix it?';
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => NovaChatScreen(
                      vehicleProfile: widget.vehicleProfile,
                      initialMessage: prompt,
                    ),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.blueCore.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.blueCore.withOpacity(0.3)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.psychology_rounded,
                        color: AppColors.blueBright, size: 12),
                    SizedBox(width: 4),
                    Text('Ask Nova about this',
                        style: TextStyle(
                            fontSize: 10,
                            color: AppColors.blueBright,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── MANUAL TAB ────────────────────────
  Widget _buildManualTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Send Raw Command'),
          GlassCard(
            child: Column(
              children: [
                TextField(
                  controller: _manualCmdCtrl,
                  style: const TextStyle(
                      fontSize: 14,
                      fontFamily: 'monospace',
                      color: AppColors.blueElectric),
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    hintText: 'e.g. 0902 or ATI or 010C',
                    hintStyle: TextStyle(
                        color: AppColors.textMuted, fontFamily: 'monospace'),
                    border: InputBorder.none,
                  ),
                  onSubmitted: (_) => _sendManualCmd(),
                ),
                const SizedBox(height: 10),
                PrimaryButton(
                  label: 'Send Command',
                  icon: Icons.send_rounded,
                  isLoading: _isRunning,
                  onPressed: _isRunning ? null : _sendManualCmd,
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          const SectionLabel('Quick Commands'),

          Expanded(
            child: ListView(
              children: DebugOBD2Service.testCommands.map((cmd) {
                return GestureDetector(
                  onTap: _isRunning
                      ? null
                      : () async {
                    _manualCmdCtrl.text = cmd['cmd']!;
                    await _sendManualCmd();
                    _tabCtrl.animateTo(0);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.bgCard.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Text(cmd['cmd']!,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                                color: AppColors.blueElectric)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(cmd['desc']!,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                        ),
                        const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textMuted, size: 18),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── SUMMARY TAB ───────────────────────
  Widget _buildSummaryTab() {
    if (_debugService.log.isEmpty) {
      return const Center(
        child: Text('Run a diagnostic first',
            style:
            TextStyle(fontSize: 14, color: AppColors.textMuted)),
      );
    }

    final passed =
        _debugService.log.where((e) => e.success).length;
    final failed =
        _debugService.log.where((e) => !e.success).length;
    final total = _debugService.log.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Score card
          GlassCard(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _ScoreChip(
                          label: 'Passed',
                          value: '$passed',
                          color: AppColors.success),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ScoreChip(
                          label: 'Failed',
                          value: '$failed',
                          color: AppColors.danger),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ScoreChip(
                          label: 'Total',
                          value: '$total',
                          color: AppColors.blueBright),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: total > 0 ? passed / total : 0,
                    minHeight: 8,
                    backgroundColor:
                    AppColors.danger.withOpacity(0.3),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.success),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          const SectionLabel('Failed Commands'),

          ..._debugService.log
              .where((e) => !e.success)
              .map((e) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.danger.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.danger.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.command,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                        color: AppColors.danger)),
                const SizedBox(height: 4),
                Text(e.rawResponse,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        fontFamily: 'monospace')),
              ],
            ),
          )),

          const SizedBox(height: 20),

          PrimaryButton(
            label: 'Send Full Report to Nova',
            icon: Icons.psychology_rounded,
            onPressed:
            _debugService.log.isEmpty ? null : _askNova,
          ),
        ],
      ),
    );
  }

  // ── POWERSTROKE PID TEST TAB ──────────────────────────────────────
  Widget _buildPowerStrokeTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header info
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.warning.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.local_fire_department_rounded,
                      color: AppColors.warning, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ford 6.0L Powerstroke',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                      Text('Extended Mode 22 PID validation',
                          style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Run button
          GestureDetector(
            onTap: (_psRunning || !_initialized) ? null : _runPowerStrokeTests,
            child: Container(
              width: double.infinity,
              height: 52,
              decoration: BoxDecoration(
                gradient: (_psRunning || !_initialized)
                    ? null
                    : const LinearGradient(colors: AppColors.primaryGradient),
                color: (_psRunning || !_initialized)
                    ? AppColors.bgCard.withOpacity(0.5)
                    : null,
                borderRadius: BorderRadius.circular(14),
                boxShadow: (_psRunning || !_initialized) ? [] : [
                  BoxShadow(
                    color: AppColors.blueCore.withOpacity(0.35),
                    blurRadius: 16, offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_psRunning)
                    const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  else
                    const Icon(Icons.play_arrow_rounded,
                        color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    !_initialized
                        ? 'Initialize connection first'
                        : _psRunning
                        ? 'Testing PIDs...'
                        : 'RUN POWERSTROKE PID TESTS',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Results
          Expanded(
            child: _psResults.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.science_rounded,
                      size: 48,
                      color: AppColors.textMuted.withOpacity(0.4)),
                  const SizedBox(height: 12),
                  const Text('Tap Run to test Powerstroke PIDs',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 13)),
                  const SizedBox(height: 6),
                  const Text('Engine should be running for best results',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 11)),
                ],
              ),
            )
                : ListView.builder(
              itemCount: _psResults.length,
              itemBuilder: (_, i) => _PsResultCard(result: _psResults[i]),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runPowerStrokeTests() async {
    setState(() {
      _psRunning = true;
      _psResults.clear();
    });

    // ── SETUP ──────────────────────────────────────────────────────────
    // We use ATH0 (headers OFF) + ATS0 (spaces OFF) — the defaults.
    // This avoids the 3-hex-char address misalignment bug with Veepeak
    // (7E8 is 3 nibbles, not 4, so byte-pair parsing breaks with ATH1).
    //
    // Instead we search the hex blob for the Mode 22 positive response
    // marker "62{PID_H}{PID_L}" — that 6-char sequence can only appear
    // in a correct response for our exact PID. Data bytes follow directly.
    //
    // ATSH still works (sets transmit destination) and is widely supported.
    // try/finally guarantees cleanup always runs even if a PID crashes.

    // CRITICAL: Pause the main OBD2Service live timer before touching the bus.
    // Both services share the same BLE characteristic — if the main timer fires
    // while Mode 22 queries are running, its Mode 01 responses (RPM, coolant,
    // speed) land in the debug buffer and cause STOPPED / NO DATA on every PID.
    widget.mainObdService?.pauseLiveUpdates();
    // Also flush any in-flight response from the last live-timer cycle.
    await _debugService.drainAdapter();

    // Set ELM327 response timeout to 600ms (0x96 = 150 × 4ms).
    // Default is 0x19 (100ms) — too short for Mode 22 on the 6.0 Powerstroke.
    // ATAT0 disables adaptive timing for consistent, predictable delays.
    await _debugService.sendRaw('ATAT0');
    await Future.delayed(const Duration(milliseconds: 100));
    await _debugService.sendRaw('ATST96');
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      for (final test in DebugOBD2Service.powerStrokeTests) {
        final pid     = test['pid']    as String;
        final rxAddr  = test['rxAddr'] as String; // for display only
        final txAddr  = test['txAddr'] as String; // ATSH destination
        final name    = test['name']   as String;
        final formula = test['formula'] as String;
        final unit    = test['unit']   as String;
        final min     = test['min']    as double;
        final max     = test['max']    as double;
        final note    = test['note']   as String;

        // PID hex — e.g. '221434' → marker = '621434'
        final pidH    = pid.length >= 4 ? pid.substring(2, 4).toUpperCase() : '??';
        final pidL    = pid.length >= 6 ? pid.substring(4, 6).toUpperCase() : '??';
        final marker  = '62$pidH$pidL'; // 6-char search key

        setState(() {
          _psResults.add(_PsTestResult(
            pid: pid, name: name, formula: formula, unit: unit,
            min: min, max: max, note: note,
            status: _PsStatus.running,
          ));
        });

        try {
          // Drain any leftover bytes from previous command before querying.
          // This is the key fix for random NO DATA — late-arriving BLE packets
          // from the previous ECU response are flushed before the clear().
          await _debugService.drainAdapter();

          // Point the adapter at the right ECU (ECM=7E0, TCM=7E1)
          await _debugService.sendRaw('ATSH $txAddr');
          await Future.delayed(const Duration(milliseconds: 100));

          // Drain again after ATSH in case it triggered any bus activity
          await _debugService.drainAdapter();

          final rawResponse = await _debugService.sendRaw(pid);
          final rawAscii    = rawResponse.trim();
          await Future.delayed(const Duration(milliseconds: 400));

          // ── BLOB SEARCH PARSER ──────────────────────────────────────
          //
          // With ATH0+ATS0 the response is a raw hex string, e.g.:
          //   "621310C01EE803..." (positive, our data starts at offset 6)
          //   "7F2211"           (negative response — service not supported)
          //   "NODATA"           (ECU didn't respond)
          //
          // Strategy: strip non-hex chars, search for "62{PH}{PL}".
          // Everything after that 6-char marker is payload data.
          // A=bytes[0], B=bytes[1], C=bytes[2] from the data section.
          //
          // This is immune to:
          //   • Multi-ECU contamination (7E9 can't produce "62{our PID}")
          //   • Frame boundary misalignment (no address byte to trip on)
          //   • Adapter variation (no ATS1 required)
          // ─────────────────────────────────────────────────────────────

          final clean = rawResponse
              .toUpperCase()
              .replaceAll(RegExp(r'[^0-9A-F]'), '');

          if (clean.isEmpty ||
              rawResponse.toUpperCase().contains('NO DATA') ||
              rawResponse.toUpperCase().contains('UNABLE') ||
              rawResponse.toUpperCase().contains('ERROR')) {
            final grid8 = List.filled(8, '--');
            grid8[0] = rxAddr; // show expected addr for reference
            setState(() {
              _psResults[_psResults.length - 1] = _PsTestResult(
                pid: pid, name: name, formula: formula, unit: unit,
                min: min, max: max, note: note,
                rawHex: clean, rawAscii: rawAscii,
                allBytes8: grid8,
                status: _PsStatus.noData,
              );
            });
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }

          // Search for the mode 62 response marker
          final markerIdx = clean.indexOf(marker);

          if (markerIdx == -1) {
            // Response received but no valid Mode 22 positive frame found
            // Could be 7F (negative) or garbled data
            final grid8 = List.filled(8, '--');
            grid8[0] = rxAddr;
            setState(() {
              _psResults[_psResults.length - 1] = _PsTestResult(
                pid: pid, name: name, formula: formula, unit: unit,
                min: min, max: max, note: note,
                rawHex: clean, rawAscii: rawAscii,
                allBytes8: grid8,
                status: _PsStatus.noData,
              );
            });
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }

          // Data starts 6 chars after marker start (skip "62 PH PL")
          final dataHex = clean.substring(markerIdx + 6);

          // Parse up to 4 data bytes
          final dataBytes = <int>[];
          for (int i = 0; i + 1 < dataHex.length && dataBytes.length < 4; i += 2) {
            final b = int.tryParse(dataHex.substring(i, i + 2), radix: 16);
            if (b != null) dataBytes.add(b);
          }

          if (dataBytes.isEmpty) {
            setState(() {
              _psResults[_psResults.length - 1] = _PsTestResult(
                pid: pid, name: name, formula: formula, unit: unit,
                min: min, max: max, note: note,
                rawHex: clean, rawAscii: rawAscii,
                allBytes8: List.filled(8, '--'),
                status: _PsStatus.parseError,
              );
            });
            continue;
          }

          final A = dataBytes[0];
          final B = dataBytes.length > 1 ? dataBytes[1] : 0;
          final C = dataBytes.length > 2 ? dataBytes[2] : 0;

          // Build display grid:
          // [rxAddr][marker[0..1]][marker[2..3]][marker[4..5]][A][B][C][--]
          final List<String> grid8 = [
            rxAddr,
            '--',    // no PCI byte with ATH0
            '62',
            pidH,
            pidL,
            dataBytes.isNotEmpty ? dataBytes[0].toRadixString(16).padLeft(2,'0').toUpperCase() : '--',
            dataBytes.length > 1 ? dataBytes[1].toRadixString(16).padLeft(2,'0').toUpperCase() : '--',
            dataBytes.length > 2 ? dataBytes[2].toRadixString(16).padLeft(2,'0').toUpperCase() : '--',
          ];

          double? decoded;
          try { decoded = _evalFormula(formula, A, B, C); } catch (_) {}

          final inRange = decoded != null && decoded >= min && decoded <= max;
          final status  = decoded == null ? _PsStatus.parseError
              : inRange ? _PsStatus.pass : _PsStatus.outOfRange;

          setState(() {
            _psResults[_psResults.length - 1] = _PsTestResult(
              pid: pid, name: name, formula: formula, unit: unit,
              min: min, max: max, note: note,
              rawHex: clean,
              rawAscii: rawAscii,
              allBytes8: grid8,
              headerBytesHex: '$rxAddr 62 $pidH $pidL',
              dataBytesHex: dataBytes
                  .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
                  .join(' '),
              pciByte: 0,
              dataByteCount: dataBytes.length,
              byteA: A, byteB: B, byteC: C,
              decodedValue: decoded,
              status: status,
            );
          });

        } catch (e) {
          setState(() {
            _psResults[_psResults.length - 1] = _PsTestResult(
              pid: pid, name: name, formula: formula, unit: unit,
              min: min, max: max, note: note,
              rawHex: e.toString(),
              status: _PsStatus.parseError,
            );
          });
        }

        await Future.delayed(const Duration(milliseconds: 500));
      }

    } finally {
      // Always restore adapter to clean default state.
      // No ATH1/ATS1 to undo — defaults are already ATH0+ATS0.
      // ATSP0 re-confirms auto-protocol in case ATSH left state dirty.
      await _debugService.sendRaw('ATSH 7DF'); // restore broadcast
      await Future.delayed(const Duration(milliseconds: 50));
      await _debugService.sendRaw('ATAT1');    // restore adaptive timing
      await Future.delayed(const Duration(milliseconds: 50));
      await _debugService.sendRaw('ATST19');   // restore default 100ms timeout
      await Future.delayed(const Duration(milliseconds: 50));
      await _debugService.sendRaw('ATSP0');
      await Future.delayed(const Duration(milliseconds: 200));
      // Resume main live timer — bus is clean and back to defaults
      widget.mainObdService?.resumeLiveUpdates();
      setState(() => _psRunning = false);
    }
  }

  /// Build a fixed 8-element list of hex byte strings from a clean hex string.
  /// Pads with '--' if fewer than 8 bytes present.
  List<String> _buildBytes8(String cleanHex) {
    final result = <String>[];
    for (int i = 0; i + 1 < cleanHex.length && result.length < 8; i += 2) {
      result.add(cleanHex.substring(i, i + 2));
    }
    while (result.length < 8) {
      result.add('--');
    }
    return result;
  }

  /// Evaluate a simple formula string with A, B, C substituted
  double _evalFormula(String formula, int A, int B, int C) {
    // Handle 1-byte IPR formula specially
    if (formula == '(A*13.53)/35') {
      return (A * 13.53) / 35;
    }
    // EOT: (((A*256)+B)/100-40)*9/5+32
    if (formula.contains('9/5+32')) {
      final raw = (A * 256) + B;
      final celsius = (raw / 100) - 40;
      return (celsius * 9 / 5) + 32;
    }
    // Trans: ((A*256)+B)/8
    if (formula == '((A*256)+B)/8') {
      return ((A * 256) + B) / 8;
    }
    // ICP: ((A*256)+B)*0.57 or *(57/100)
    if (formula.contains('0.57') || formula.contains('57/100')) {
      return ((A * 256) + B) * 0.57;
    }
    // MAP/EBP: ((A*256)+B)*0.03625
    if (formula.contains('0.03625')) {
      return ((A * 256) + B) * 0.03625;
    }
    // FICM: ((A*256+B)*100/256)/100
    if (formula.contains('100/256')) {
      return ((A * 256 + B) * 100 / 256) / 100;
    }
    // Cylinder head: (((A*256)+B)*1.999)+32
    if (formula.contains('1.999')) {
      return (((A * 256) + B) * 1.999) + 32;
    }
    // VGT: ((A*256)+B)*(100/32767)
    if (formula.contains('32767')) {
      return ((A * 256) + B) * (100 / 32767);
    }
    // Injector timing: (((A*256)+B)*(10/64))/10
    if (formula.contains('10/64')) {
      return (((A * 256) + B) * (10 / 64)) / 10;
    }
    // Mass fuel: ((A*256)+B)*0.0625
    if (formula.contains('0.0625')) {
      return ((A * 256) + B) * 0.0625;
    }
    // Generic A*256+B fallback
    if (formula.contains('A*256') || formula.contains('(A*256)')) {
      return ((A * 256) + B).toDouble();
    }
    // Single byte fallback
    return A.toDouble();
  }
}

class _ScoreChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _ScoreChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: color,
                  fontFamily: 'monospace')),
          Text(label,
              style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  POWERSTROKE TEST RESULT MODEL
// ─────────────────────────────────────────
enum _PsStatus { running, pass, outOfRange, noData, parseError }

class _PsTestResult {
  final String pid;
  final String name;
  final String formula;
  final String unit;
  final double min;
  final double max;
  final String note;
  final String rawHex;
  final String headerBytesHex;
  final String dataBytesHex;
  final int pciByte;
  final int dataByteCount;
  final int byteA;
  final int byteB;
  final int byteC;
  final double? decodedValue;
  final _PsStatus status;
  // Full unstripped response for manual inspection
  final String rawAscii;
  // All 8 bytes as individual hex strings for the byte grid
  final List<String> allBytes8;

  _PsTestResult({
    required this.pid,
    required this.name,
    required this.formula,
    required this.unit,
    required this.min,
    required this.max,
    required this.note,
    this.rawHex = '',
    this.headerBytesHex = '',
    this.dataBytesHex = '',
    this.pciByte = 0,
    this.dataByteCount = 0,
    this.byteA = 0,
    this.byteB = 0,
    this.byteC = 0,
    this.decodedValue,
    this.status = _PsStatus.running,
    this.rawAscii = '',
    this.allBytes8 = const [],
  });
}

// ─────────────────────────────────────────
//  POWERSTROKE RESULT CARD
// ─────────────────────────────────────────
class _PsResultCard extends StatelessWidget {
  final _PsTestResult result;
  const _PsResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final Color statusColor;
    final IconData statusIcon;
    final String statusLabel;

    switch (result.status) {
      case _PsStatus.running:
        statusColor = AppColors.blueElectric;
        statusIcon = Icons.hourglass_top_rounded;
        statusLabel = 'TESTING...';
        break;
      case _PsStatus.pass:
        statusColor = AppColors.success;
        statusIcon = Icons.check_circle_rounded;
        statusLabel = 'PASS';
        break;
      case _PsStatus.outOfRange:
        statusColor = AppColors.warning;
        statusIcon = Icons.warning_rounded;
        statusLabel = 'OUT OF RANGE';
        break;
      case _PsStatus.noData:
        statusColor = AppColors.danger;
        statusIcon = Icons.cancel_rounded;
        statusLabel = 'NO DATA';
        break;
      case _PsStatus.parseError:
        statusColor = AppColors.danger;
        statusIcon = Icons.error_rounded;
        statusLabel = 'PARSE ERROR';
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              // PID badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.bgCard2,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  result.pid,
                  style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: AppColors.blueElectric,
                      fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  result.name,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              // Status badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: statusColor.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(statusIcon, color: statusColor, size: 12),
                    const SizedBox(width: 4),
                    Text(statusLabel,
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: statusColor)),
                  ],
                ),
              ),
            ],
          ),

          // Decoded value — big and prominent
          if (result.decodedValue != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  result.decodedValue!.toStringAsFixed(1),
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      color: statusColor,
                      fontFamily: 'monospace',
                      shadows: [
                        Shadow(color: statusColor.withOpacity(0.4), blurRadius: 12)
                      ]),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(result.unit,
                      style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600)),
                ),
                const Spacer(),
                Text(
                  'Expected: ${result.min.toStringAsFixed(0)}–${result.max.toStringAsFixed(0)} ${result.unit}',
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textMuted),
                ),
              ],
            ),
          ],

          // ── RAW BYTES SECTION — always shown ─────────────────────────
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.bgCard2.withOpacity(0.6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border.withOpacity(0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Full ASCII response (unstripped) ─────────────────
                const Text('FULL RESPONSE',
                    style: TextStyle(
                        fontSize: 8,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.bgCard.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    result.rawAscii.isEmpty ? result.rawHex : result.rawAscii,
                    style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppColors.textSecondary),
                  ),
                ),

                const SizedBox(height: 10),

                // ── 8-byte grid ──────────────────────────────────────
                const Text('ALL 8 BYTES',
                    style: TextStyle(
                        fontSize: 8,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2)),
                const SizedBox(height: 6),
                if (result.allBytes8.isNotEmpty)
                  _ByteGrid(bytes: result.allBytes8, pciByte: result.pciByte,
                      dataByteCount: result.dataByteCount),

                if (result.headerBytesHex.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('HDR  ',
                          style: TextStyle(
                              fontSize: 9,
                              color: AppColors.textMuted,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1)),
                      Text(
                        result.headerBytesHex,
                        style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: AppColors.textMuted.withOpacity(0.7)),
                      ),
                    ],
                  ),
                ],
                if (result.dataBytesHex.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text('DATA ',
                          style: TextStyle(
                              fontSize: 9,
                              color: AppColors.blueElectric,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1)),
                      Expanded(
                        child: Text(
                          '${result.dataBytesHex}  →  A=${result.byteA}  B=${result.byteB}  (PCI=${result.pciByte.toRadixString(16).toUpperCase()} → ${result.dataByteCount}B)',
                          style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: AppColors.blueElectric,
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text('FMR  ',
                        style: TextStyle(
                            fontSize: 9,
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1)),
                    Expanded(
                      child: Text(
                        result.formula,
                        style: const TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: AppColors.warning),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Note
          if (result.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              result.note,
              style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  fontStyle: FontStyle.italic,
                  height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  8-BYTE GRID WIDGET
//  Shows all 8 CAN frame bytes color-coded:
//  gray  = PCI byte (position 0)
//  gray  = mode/PID echo bytes (positions 1-3)
//  blue  = data bytes (positions 4 to 4+dataByteCount-1)
//  dim   = padding bytes
// ─────────────────────────────────────────
class _ByteGrid extends StatelessWidget {
  // allBytes8 layout (with ATH1+ATS1 spaces-on parsing):
  //   [0] = source addr  e.g. "7E8"   → teal chip
  //   [1] = PCI byte                  → yellow (payload length)
  //   [2] = "62"  (mode echo)         → gray
  //   [3] = PID_H echo                → gray
  //   [4] = PID_L echo                → gray
  //   [5..7] = data bytes A, B, C     → blue (highlighted)
  //   "--" = missing/padding          → dim
  final List<String> bytes;
  final int pciByte;
  final int dataByteCount;

  const _ByteGrid({
    required this.bytes,
    required this.pciByte,
    required this.dataByteCount,
  });

  @override
  Widget build(BuildContext context) {
    const posLabels = ['ADDR', 'PCI', 'MODE', 'PID_H', 'PID_L', 'A', 'B', 'C'];

    return Row(
      children: List.generate(8, (i) {
        final val    = i < bytes.length ? bytes[i] : '--';
        final isAddr = i == 0;
        final isPci  = i == 1;
        final isEcho = i >= 2 && i <= 4;
        final isData = i >= 5 && i < 5 + dataByteCount;

        final Color boxColor;
        final Color textColor;
        final Color labelColor;

        if (isAddr) {
          // Source ECU address — teal/success color
          boxColor   = AppColors.success.withOpacity(0.12);
          textColor  = AppColors.success;
          labelColor = AppColors.success.withOpacity(0.7);
        } else if (isPci) {
          // PCI byte — gold/warning, tells us payload length
          boxColor   = AppColors.warning.withOpacity(0.12);
          textColor  = AppColors.warning;
          labelColor = AppColors.warning.withOpacity(0.7);
        } else if (isEcho) {
          // Mode/PID echo bytes — dimmed gray
          boxColor   = AppColors.textMuted.withOpacity(0.05);
          textColor  = AppColors.textMuted.withOpacity(0.55);
          labelColor = AppColors.textMuted.withOpacity(0.35);
        } else if (isData) {
          // Data bytes — bright blue, these feed the formula
          boxColor   = AppColors.blueElectric.withOpacity(0.15);
          textColor  = AppColors.blueElectric;
          labelColor = AppColors.blueElectric.withOpacity(0.7);
        } else {
          // Padding / unknown
          boxColor   = Colors.transparent;
          textColor  = AppColors.textMuted.withOpacity(0.2);
          labelColor = AppColors.textMuted.withOpacity(0.15);
        }

        // Show decimal under data bytes (helps verify formula inputs)
        String? decVal;
        if ((isData || isPci) && val != '--' && val.length <= 2) {
          try { decVal = int.parse(val, radix: 16).toString(); } catch (_) {}
        }

        // Font size — addr chip uses slightly smaller font to fit "7E8"
        final double fontSize = isAddr ? 9.5 : 11;

        return Expanded(
          child: Container(
            margin: const EdgeInsets.only(right: 3),
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: boxColor,
              borderRadius: BorderRadius.circular(6),
              border: isData
                  ? Border.all(color: AppColors.blueElectric.withOpacity(0.35))
                  : isPci
                  ? Border.all(color: AppColors.warning.withOpacity(0.3))
                  : isAddr
                  ? Border.all(color: AppColors.success.withOpacity(0.35))
                  : null,
            ),
            child: Column(
              children: [
                Text(
                  val,
                  style: TextStyle(
                      fontSize: fontSize,
                      fontFamily: 'monospace',
                      fontWeight: (isData || isAddr) ? FontWeight.w800 : FontWeight.w400,
                      color: textColor),
                  textAlign: TextAlign.center,
                ),
                if (decVal != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    decVal,
                    style: TextStyle(
                        fontSize: 8,
                        fontFamily: 'monospace',
                        color: isData
                            ? AppColors.blueElectric.withOpacity(0.65)
                            : AppColors.warning.withOpacity(0.65)),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  i < posLabels.length ? posLabels[i] : 'B$i',
                  style: TextStyle(
                      fontSize: 7,
                      fontWeight: FontWeight.w700,
                      color: labelColor,
                      letterSpacing: 0.2),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}