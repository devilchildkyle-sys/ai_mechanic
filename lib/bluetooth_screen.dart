import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart'
as classic;
import 'package:permission_handler/permission_handler.dart';
import 'main.dart';
import 'vehicle_check_screen.dart';

class BluetoothScreen extends StatefulWidget {
  const BluetoothScreen({super.key});
  @override
  State<BluetoothScreen> createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen>
    with SingleTickerProviderStateMixin {

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  List<classic.BluetoothDevice> _classicDevices = [];
  final Set<String> _bleIds = {};
  String? _connectingId;
  String? _connectedId;
  String? _errorMessage;
  bool _showNonObd = false; // controls the "Show more" section

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    FlutterBluePlus.adapterState.listen((s) {
      if (mounted) setState(() => _adapterState = s);
    });
    FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() {
          _scanResults = results
              .where((r) => r.device.platformName.isNotEmpty)
              .toList()
            ..sort((a, b) => b.rssi.compareTo(a.rssi));
          for (final r in results) {
            _bleIds.add(r.device.remoteId.toString());
          }
        });
      }
    });
    FlutterBluePlus.isScanning.listen((v) {
      if (mounted) setState(() => _isScanning = v);
    });
    _loadClassicDevices();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _loadClassicDevices() async {
    try {
      final bonded =
      await classic.FlutterBluetoothSerial.instance.getBondedDevices();
      if (mounted) {
        setState(() {
          _classicDevices = bonded
            ..sort((a, b) {
              final aObd = _isLikelyObd(a.name ?? '') ? 0 : 1;
              final bObd = _isLikelyObd(b.name ?? '') ? 0 : 1;
              return aObd.compareTo(bObd);
            });
        });
      }
    } catch (e) {
      debugPrint('Classic BT load error: $e');
    }
  }

  Future<void> _connectClassic(classic.BluetoothDevice device) async {
    final id = device.address;
    setState(() { _connectingId = id; _errorMessage = null; });
    try {
      await Permission.bluetooth.request();
      setState(() { _connectedId = id; _connectingId = null; });
      if (mounted) {
        _showDialog(device.name ?? device.address, true, () {
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => VehicleCheckScreen(
            deviceName: device.name ?? device.address,
            deviceId: device.address,
            isClassic: true,
          ),
        ));
      });
      }
    } catch (e) {
      setState(() {
        _connectingId = null;
        _errorMessage = 'Could not connect to ${device.name ?? id}.\n'
            'Make sure it is powered on and try again.';
      });
    }
  }

  Future<void> _startScan() async {
    setState(() { _scanResults = []; _errorMessage = null; });
    try {
      if (_adapterState != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
      await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 15),
          androidUsesFineLocation: true);
    } catch (e) {
      setState(() => _errorMessage = 'Scan failed: ${e.toString()}');
    }
  }

  Future<void> _stopScan() async => FlutterBluePlus.stopScan();

  Future<void> _connectBle(BluetoothDevice device) async {
    final id = device.remoteId.toString();
    setState(() { _connectingId = id; _errorMessage = null; });
    try {
      await FlutterBluePlus.stopScan();
      await device.connect(timeout: const Duration(seconds: 10));
      setState(() { _connectedId = id; _connectingId = null; });
      if (mounted) {
        _showDialog(device.platformName, false, () {
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => VehicleCheckScreen(
            deviceName: device.platformName,
            deviceId: device.remoteId.toString(),
            isClassic: false,
          ),
        ));
      });
      }
    } catch (e) {
      setState(() {
        _connectingId = null;
        _errorMessage = 'Could not connect to ${device.platformName}. '
            'Make sure the dongle is powered on and try again.';
      });
    }
  }

  void _showDialog(String name, bool isClassic, VoidCallback onContinue) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: AppColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: AppColors.success.withOpacity(0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.success.withOpacity(0.4)),
                ),
                child: const Icon(Icons.check_rounded,
                    color: AppColors.success, size: 32),
              ),
              const SizedBox(height: 16),
              const Text('Connected!',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isClassic
                      ? AppColors.warning.withOpacity(0.12)
                      : AppColors.blueElectric.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isClassic ? 'Classic Bluetooth' : 'Bluetooth Low Energy',
                  style: TextStyle(
                      fontSize: 11,
                      color: isClassic ? AppColors.warning : AppColors.blueElectric,
                      fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 8),
              Text(name,
                  style: const TextStyle(fontSize: 14,
                      color: AppColors.textSecondary)),
              const SizedBox(height: 24),
              PrimaryButton(
                label: 'Continue',
                icon: Icons.arrow_forward_rounded,
                onPressed: () { Navigator.pop(context); onContinue(); },
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isLikelyObd(String name) {
    final n = name.toLowerCase();
    return n.contains('obd') || n.contains('elm') || n.contains('obdii') ||
        n.contains('vlink') || n.contains('veepeak') || n.contains('carista') ||
        n.contains('bluedriver') || n.contains('fixd') || n.contains('icar') ||
        n.contains('vlinker') || n.contains('konnwei') || n.contains('topdon') ||
        n.contains('launch') || n.contains('autel') || n.contains('scantool') ||
        n.contains('obdlink') || n.contains('odb') || n.contains('scan') ||
        n.contains('diag') || n.contains('car');
  }

  Widget _signalIcon(int rssi) {
    if (rssi >= -60) {
      return const Icon(Icons.signal_cellular_alt_rounded,
        color: AppColors.success, size: 18);
    }
    if (rssi >= -75) {
      return const Icon(Icons.signal_cellular_alt_2_bar_rounded,
        color: AppColors.warning, size: 18);
    }
    return const Icon(Icons.signal_cellular_alt_1_bar_rounded,
        color: AppColors.danger, size: 18);
  }

  // ── Build unified OBD device list ─────────────────────────────────────────
  // Combines classic BT OBD devices + BLE OBD devices into one sorted list
  List<Widget> _buildObdDeviceList() {
    final widgets = <Widget>[];

    // Classic OBD devices
    for (final d in _classicDevices.where((d) => _isLikelyObd(d.name ?? ''))) {
      widgets.add(_buildClassicCard(d));
    }

    // BLE OBD devices (from scan results)
    for (final r in _scanResults.where((r) => _isLikelyObd(r.device.platformName))) {
      widgets.add(_buildBleCard(r));
    }

    return widgets;
  }

  // Non-OBD devices combined (classic + BLE non-OBD)
  List<Widget> _buildNonObdDeviceList() {
    final widgets = <Widget>[];

    for (final d in _classicDevices.where((d) => !_isLikelyObd(d.name ?? ''))) {
      widgets.add(_buildClassicCard(d));
    }

    for (final r in _scanResults.where((r) => !_isLikelyObd(r.device.platformName))) {
      widgets.add(_buildBleCard(r));
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final obdWidgets    = _buildObdDeviceList();
    final nonObdWidgets = _buildNonObdDeviceList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Column(
                    children: [
                      const SizedBox(height: 24),
                      _buildScannerRing(),
                      const SizedBox(height: 32),
                      _buildScanButton(),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 16),
                        _buildErrorBanner(),
                      ],

                      // ── OBD2 Devices ───────────────────────────────────
                      if (obdWidgets.isNotEmpty || _isScanning) ...[
                        const SizedBox(height: 28),
                        const SectionLabel('OBD2 Adapters'),
                        if (obdWidgets.isEmpty && _isScanning)
                          _buildSearchingIndicator()
                        else
                          ...obdWidgets,
                      ],

                      // ── No devices found hint ───────────────────────────
                      if (obdWidgets.isEmpty && !_isScanning &&
                          _classicDevices.isEmpty) ...[
                        const SizedBox(height: 28),
                        _buildNoDevicesHint(),
                      ],

                      // ── Other Devices (collapsed) ───────────────────────
                      if (nonObdWidgets.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        _buildShowMoreToggle(nonObdWidgets.length),
                        if (_showNonObd) ...[
                          const SizedBox(height: 12),
                          ...nonObdWidgets,
                        ],
                      ],

                      const SizedBox(height: 24),
                      _buildHelpCard(),
                    ],
                  ),
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
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
                Text('Connect Dongle',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                Text('Classic BT & BLE supported',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (_connectedId != null)
            const LiveIndicator(color: AppColors.success, label: 'CONNECTED'),
        ],
      ),
    );
  }

  Widget _buildScannerRing() {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, __) => Stack(
        alignment: Alignment.center,
        children: [
          if (_isScanning)
            Container(
              width: 160 * _pulseAnim.value,
              height: 160 * _pulseAnim.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.blueCore.withOpacity(
                      0.3 * (1 - (_pulseAnim.value - 0.6) / 0.4)),
                  width: 2,
                ),
              ),
            ),
          if (_isScanning)
            Container(
              width: 130, height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: AppColors.blueCore.withOpacity(0.2), width: 1),
              ),
            ),
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                AppColors.blueCore.withOpacity(_isScanning ? 0.4 : 0.2),
                AppColors.bgCard.withOpacity(0.8),
              ]),
              border: Border.all(
                  color: AppColors.blueCore
                      .withOpacity(_isScanning ? 0.6 : 0.3),
                  width: 1.5),
              boxShadow: _isScanning
                  ? [BoxShadow(
                  color: AppColors.blueCore.withOpacity(0.4),
                  blurRadius: 30)]
                  : [],
            ),
            child: Icon(Icons.bluetooth_searching_rounded, size: 42,
                color: _isScanning
                    ? AppColors.blueElectric
                    : AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildScanButton() {
    if (_isScanning) {
      return SecondaryButton(
          label: 'Stop Scanning',
          icon: Icons.stop_rounded,
          onPressed: _stopScan);
    }
    return PrimaryButton(
        label: 'Scan for BLE Devices',
        icon: Icons.bluetooth_searching_rounded,
        onPressed: _startScan);
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withOpacity(0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.danger.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppColors.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(_errorMessage!,
              style: const TextStyle(fontSize: 12, color: AppColors.danger))),
        ],
      ),
    );
  }

  // ── Show More toggle button ───────────────────────────────────────────────
  Widget _buildShowMoreToggle(int count) {
    return GestureDetector(
      onTap: () => setState(() => _showNonObd = !_showNonObd),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.bgCard.withOpacity(0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _showNonObd
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              color: AppColors.textMuted,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              _showNonObd
                  ? 'Hide other devices'
                  : 'Show $count other paired device${count == 1 ? '' : 's'}',
              style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  // ── No devices hint ───────────────────────────────────────────────────────
  Widget _buildNoDevicesHint() {
    return const GlassCard(
      padding: EdgeInsets.all(20),
      child: Column(
        children: [
          Icon(Icons.bluetooth_disabled_rounded,
              color: AppColors.textMuted, size: 36),
          SizedBox(height: 12),
          Text('No OBD2 adapters found',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          SizedBox(height: 6),
          Text(
            'For Classic BT adapters, pair them in your phone\'s Bluetooth settings first, then come back here.\n\nFor BLE adapters, tap Scan above.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, color: AppColors.textSecondary, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildClassicCard(classic.BluetoothDevice device) {
    final name = device.name ?? device.address;
    final id   = device.address;
    final isObd        = _isLikelyObd(name);
    final isConnecting = _connectingId == id;
    final isConnected  = _connectedId  == id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: isConnecting || isConnected ? null : () => _connectClassic(device),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isObd
                ? AppColors.success.withOpacity(0.08)
                : AppColors.bgCard.withOpacity(0.7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isConnected
                  ? AppColors.success.withOpacity(0.5)
                  : isObd
                  ? AppColors.success.withOpacity(0.4)
                  : AppColors.border,
              width: isObd ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: isObd
                      ? AppColors.success.withOpacity(0.15)
                      : AppColors.bgCard2.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isObd
                      ? Icons.settings_input_component_rounded
                      : Icons.bluetooth_rounded,
                  color: isObd ? AppColors.success : AppColors.textMuted,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(name,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                    const SizedBox(height: 2),
                    Row(children: [
                      Text(device.address,
                          style: const TextStyle(fontSize: 10,
                              color: AppColors.textMuted,
                              fontFamily: 'monospace')),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('CLASSIC BT',
                            style: TextStyle(fontSize: 7,
                                color: AppColors.warning,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5)),
                      ),
                    ]),
                  ],
                ),
              ),
              if (isConnecting)
                const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.warning))
              else if (isConnected)
                const LiveIndicator(
                    color: AppColors.success, label: 'CONNECTED')
              else
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBleCard(ScanResult result) {
    final device = result.device;
    final name   = device.platformName;
    final id     = device.remoteId.toString();
    final isObd        = _isLikelyObd(name);
    final isConnecting = _connectingId == id;
    final isConnected  = _connectedId  == id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: isConnecting || isConnected ? null : () => _connectBle(device),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isObd
                ? AppColors.success.withOpacity(0.08)
                : AppColors.bgCard.withOpacity(0.7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isConnected
                  ? AppColors.success.withOpacity(0.5)
                  : isObd
                  ? AppColors.success.withOpacity(0.4)
                  : AppColors.border,
              width: isObd ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: isObd
                      ? AppColors.success.withOpacity(0.15)
                      : AppColors.bgCard2.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isObd
                      ? Icons.settings_input_component_rounded
                      : Icons.bluetooth_rounded,
                  color: isObd ? AppColors.success : AppColors.textMuted,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Row(children: [
                      Text(id,
                          style: const TextStyle(fontSize: 10,
                              color: AppColors.textMuted,
                              fontFamily: 'monospace')),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.blueElectric.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('BLE',
                            style: TextStyle(fontSize: 7,
                                color: AppColors.blueElectric,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5)),
                      ),
                    ]),
                  ],
                ),
              ),
              if (isConnecting)
                const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.blueElectric))
              else if (isConnected)
                const LiveIndicator(
                    color: AppColors.success, label: 'CONNECTED')
              else
                Row(children: [
                  _signalIcon(result.rssi),
                  const SizedBox(width: 4),
                  Text('${result.rssi}',
                      style: const TextStyle(fontSize: 10,
                          color: AppColors.textMuted,
                          fontFamily: 'monospace')),
                ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchingIndicator() {
    return const GlassCard(
      child: Row(
        children: [
          SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.blueElectric)),
          SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Scanning for BLE adapters...',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text('Classic BT devices appear automatically above',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
            ],
          )),
        ],
      ),
    );
  }

  Widget _buildHelpCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.lightbulb_outline_rounded,
                color: AppColors.blueElectric, size: 18),
            SizedBox(width: 8),
            Text('Quick Tips',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 12),
          _tip('Plug your OBD2 dongle into the port under your dashboard'),
          _tip('Turn your key to ON position (engine off is fine)'),
          _tip('Classic BT adapters: pair in phone Settings first, then come back here'),
          _tip('BLE adapters: tap Scan — no pre-pairing needed'),
          _tip('Can\'t find your adapter? Tap "Show other devices" below the list'),
        ],
      ),
    );
  }

  Widget _tip(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6, height: 6,
            margin: const EdgeInsets.only(top: 5, right: 10),
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: AppColors.blueElectric),
          ),
          Expanded(child: Text(text,
              style: const TextStyle(fontSize: 12,
                  color: AppColors.textSecondary, height: 1.4))),
        ],
      ),
    );
  }
}