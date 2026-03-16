import 'package:flutter/material.dart';
import 'dart:math';
import 'main.dart';
import 'vehicle_profile_screen.dart';
import 'settings_screen.dart';

// ─────────────────────────────────────────
//  STATS FOR NERDS SCREEN
// ─────────────────────────────────────────
class StatsScreen extends StatefulWidget {
  final VehicleProfile vehicleProfile;
  final OBD2Service obd;
  final Map<String, String> powerstrokePids;
  final Map<String, String> toyotaPids;
  final Map<String, String> gmPids;
  final int psGen;    // Powerstroke generation: 73, 60, 64, or 67
  final String gmGen; // GM generation: 'gas','lb7','lly_lbz','lmm','lml','l5p'

  const StatsScreen({
    super.key,
    required this.vehicleProfile,
    required this.obd,
    this.powerstrokePids = const {},
    this.toyotaPids = const {},
    this.gmPids = const {},
    this.psGen = 60,
    this.gmGen = 'gas',
  });

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen>
    with TickerProviderStateMixin {
  late VehicleProfile _profile;

  double _rpm = 0;
  double _coolant = 0;
  double _battery = 0;
  double _throttle = 0;
  double _speed = 0;
  double _fuel = 0;

  final List<double> _rpmHistory = [];
  final List<double> _coolantHistory = [];
  final List<double> _throttleHistory = [];
  static const int _historyMax = 40;

  late AnimationController _gaugeCtrl;
  bool _polling = false;

  // Manufacturer PID maps
  Map<String, String> _psPids = {};
  bool _psRefreshing = false;
  Map<String, String> _toPids = {};
  bool _toRefreshing = false;
  Map<String, String> _gmPids = {};
  bool _gmRefreshing = false;

  @override
  void initState() {
    super.initState();
    _profile = widget.vehicleProfile;
    _gaugeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
    _psPids = Map<String, String>.from(widget.powerstrokePids);
    _toPids = Map<String, String>.from(widget.toyotaPids);
    _gmPids = Map<String, String>.from(widget.gmPids);
    _loadInitialValues();
    _startPolling();
  }

  @override
  void dispose() {
    _polling = false;
    _gaugeCtrl.dispose();
    super.dispose();
  }

  void _loadInitialValues() {
    final obd = _profile.rawObd;
    _rpm      = double.tryParse(obd['rpm']?.replaceAll(RegExp(r'[^0-9.]'), '') ?? '0') ?? 0;
    _coolant  = double.tryParse(obd['coolant_temp']?.replaceAll(RegExp(r'[^0-9.]'), '') ?? '0') ?? 0;
    _battery  = double.tryParse(obd['battery']?.replaceAll(RegExp(r'[^0-9.]'), '') ?? '0') ?? 0;
    _throttle = double.tryParse(obd['throttle']?.replaceAll(RegExp(r'[^0-9.]'), '') ?? '0') ?? 0;
    _speed    = double.tryParse(obd['speed']?.replaceAll(RegExp(r'[^0-9.]'), '') ?? '0') ?? 0;
    _fuel     = double.tryParse(obd['fuel_level']?.replaceAll(RegExp(r'[^0-9.]'), '') ?? '0') ?? 0;
  }

  // ── REFRESH METHODS ───────────────────

  Future<void> _refreshPowerstrokePids() async {
    if (_psRefreshing) return;
    setState(() => _psRefreshing = true);
    try {
      widget.obd.pauseLiveUpdates();
      await Future.delayed(const Duration(milliseconds: 300));
      final results = await widget.obd.readPowerstrokePids(gen: widget.psGen);
      if (mounted) setState(() => _psPids = results);
    } catch (e) { debugPrint('PS refresh error: $e'); }
    finally {
      widget.obd.resumeLiveUpdates();
      if (mounted) setState(() => _psRefreshing = false);
    }
  }

  Future<void> _refreshToyotaPids() async {
    if (_toRefreshing) return;
    setState(() => _toRefreshing = true);
    try {
      widget.obd.pauseLiveUpdates();
      await Future.delayed(const Duration(milliseconds: 300));
      final results = await widget.obd.readToyotaPids();
      if (mounted) setState(() => _toPids = results);
    } catch (e) { debugPrint('Toyota refresh error: $e'); }
    finally {
      widget.obd.resumeLiveUpdates();
      if (mounted) setState(() => _toRefreshing = false);
    }
  }

  Future<void> _refreshGmPids() async {
    if (_gmRefreshing) return;
    setState(() => _gmRefreshing = true);
    try {
      widget.obd.pauseLiveUpdates();
      await Future.delayed(const Duration(milliseconds: 300));
      final results = await widget.obd.readGmPids(gen: widget.gmGen);
      if (mounted) setState(() => _gmPids = results);
    } catch (e) { debugPrint('GM refresh error: $e'); }
    finally {
      widget.obd.resumeLiveUpdates();
      if (mounted) setState(() => _gmRefreshing = false);
    }
  }

  Future<void> _startPolling() async {
    _polling = true;
    while (_polling && mounted) {
      try {
        final rpm      = (await widget.obd.readRpm()).toDouble();
        final coolant  = (await widget.obd.readCoolantTemp()).toDouble();
        final battery  = await widget.obd.readBattery();
        final throttle = await widget.obd.readThrottle();
        final speed    = (await widget.obd.readSpeed()).toDouble();
        final fuel     = await widget.obd.readFuelLevel();
        if (!mounted) break;
        setState(() {
          _rpm = rpm; _coolant = coolant; _battery = battery;
          _throttle = throttle; _speed = speed; _fuel = fuel;
          _rpmHistory.add(rpm); _coolantHistory.add(coolant); _throttleHistory.add(throttle);
          if (_rpmHistory.length > _historyMax)      _rpmHistory.removeAt(0);
          if (_coolantHistory.length > _historyMax)  _coolantHistory.removeAt(0);
          if (_throttleHistory.length > _historyMax) _throttleHistory.removeAt(0);
        });
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: appSettings.updateIntervalMs));
    }
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
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      _buildRpmGauge(),
                      const SizedBox(height: 16),
                      _buildSpeedThrottleRow(),
                      const SizedBox(height: 16),
                      _buildTempFuelRow(),
                      const SizedBox(height: 16),
                      _buildBatteryCard(),
                      const SizedBox(height: 16),
                      _buildRawDataCard(),
                      const SizedBox(height: 16),
                      _buildPowerstrokeCard(),
                      const SizedBox(height: 16),
                      _buildToyotaCard(),
                      const SizedBox(height: 16),
                      _buildGmCard(),
                      const SizedBox(height: 16),
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Stats for Nerds',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                Text(_profile.displayName,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const LiveIndicator(color: AppColors.blueElectric, label: 'LIVE'),
        ],
      ),
    );
  }

  Widget _buildRpmGauge() {
    const maxRpm = 7000.0;
    final pct = (_rpm / maxRpm).clamp(0.0, 1.0);
    return GlassCard(
      child: Column(
        children: [
          const Text('ENGINE RPM',
              style: TextStyle(fontSize: 10, color: AppColors.textMuted,
                  letterSpacing: 2, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          SizedBox(
            width: 220, height: 220,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(size: const Size(220, 220),
                    painter: _GaugePainter(value: 1.0,
                        color: Colors.white.withOpacity(0.05),
                        strokeWidth: 18, startAngle: pi * 0.75, sweepAngle: pi * 1.5)),
                CustomPaint(size: const Size(220, 220),
                    painter: _GaugePainter(value: 1.0,
                        color: AppColors.danger.withOpacity(0.2),
                        strokeWidth: 18,
                        startAngle: pi * 0.75 + (pi * 1.5 * (6000 / maxRpm)),
                        sweepAngle: pi * 1.5 * (1000 / maxRpm))),
                AnimatedBuilder(
                  animation: _gaugeCtrl,
                  builder: (_, __) => CustomPaint(
                    size: const Size(220, 220),
                    painter: _GaugePainter(
                        value: pct * _gaugeCtrl.value, color: _rpmColor(_rpm),
                        strokeWidth: 18, startAngle: pi * 0.75,
                        sweepAngle: pi * 1.5, withGlow: true),
                  ),
                ),
                CustomPaint(size: const Size(220, 220),
                    painter: _TickPainter(count: 7, maxValue: maxRpm)),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_rpm.round().toString(),
                        style: TextStyle(fontSize: 44, fontWeight: FontWeight.w900,
                            color: _rpmColor(_rpm), fontFamily: 'monospace')),
                    const Text('RPM',
                        style: TextStyle(fontSize: 12, color: AppColors.textMuted, letterSpacing: 2)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_rpmHistory.length > 2)
            _Sparkline(data: _rpmHistory, color: _rpmColor(_rpm), height: 40),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _miniStat('IDLE', '600-800'),
              _miniStat('NORMAL', '1000-3000'),
              _miniStat('HIGH', '3000+'),
            ],
          ),
        ],
      ),
    );
  }

  Color _rpmColor(double rpm) {
    if (rpm < 3000) return AppColors.success;
    if (rpm < 5000) return AppColors.warning;
    return AppColors.danger;
  }

  Widget _buildSpeedThrottleRow() {
    return Row(
      children: [
        Expanded(child: GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            const Text('SPEED', style: TextStyle(fontSize: 9, color: AppColors.textMuted,
                letterSpacing: 1.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _buildHalfGauge(value: _speed,
                max: appSettings.useMiles ? 120 : 200, color: AppColors.violetLight),
            const SizedBox(height: 8),
            Text(appSettings.formatSpeed(_speed.round()),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800,
                    color: AppColors.violetLight, fontFamily: 'monospace')),
          ]),
        )),
        const SizedBox(width: 12),
        Expanded(child: GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            const Text('THROTTLE', style: TextStyle(fontSize: 9, color: AppColors.textMuted,
                letterSpacing: 1.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _buildHalfGauge(value: _throttle, max: 100, color: AppColors.teal),
            const SizedBox(height: 8),
            Text('${_throttle.toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800,
                    color: AppColors.teal, fontFamily: 'monospace')),
          ]),
        )),
      ],
    );
  }

  Widget _buildHalfGauge({required double value, required double max, required Color color}) {
    final pct = (value / max).clamp(0.0, 1.0);
    return SizedBox(width: 90, height: 55,
      child: Stack(alignment: Alignment.bottomCenter, children: [
        CustomPaint(size: const Size(90, 55),
            painter: _HalfGaugePainter(value: 1.0,
                color: Colors.white.withOpacity(0.05), strokeWidth: 10)),
        CustomPaint(size: const Size(90, 55),
            painter: _HalfGaugePainter(value: pct,
                color: color, strokeWidth: 10, withGlow: true)),
      ]),
    );
  }

  Widget _buildTempFuelRow() {
    return Row(
      children: [
        Expanded(child: _buildVerticalBar(
          label: 'COOLANT', value: _coolant, min: 0, max: 130,
          unit: appSettings.tempUnit, displayValue: appSettings.formatTemp(_coolant.round()),
          color: _coolantColor(_coolant), dangerZone: 105,
        )),
        const SizedBox(width: 12),
        Expanded(child: _buildVerticalBar(
          label: 'FUEL', value: _fuel, min: 0, max: 100,
          unit: '%', displayValue: '${_fuel.toStringAsFixed(1)}%',
          color: _fuelColor(_fuel), dangerZone: 15, dangerAtBottom: true,
        )),
      ],
    );
  }

  Widget _buildVerticalBar({
    required String label, required double value, required double min,
    required double max, required String unit, required String displayValue,
    required Color color, double? dangerZone, bool dangerAtBottom = false,
  }) {
    final pct = ((value - min) / (max - min)).clamp(0.0, 1.0);
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Text(label, style: const TextStyle(fontSize: 9, color: AppColors.textMuted,
            letterSpacing: 1.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        SizedBox(height: 120, child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(width: 28, height: 120,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(alignment: Alignment.bottomCenter, children: [
                  FractionallySizedBox(heightFactor: pct,
                    child: Container(decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter, end: Alignment.topCenter,
                        colors: [color, color.withOpacity(0.6)],
                      ),
                    )),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(max.round().toString(), style: const TextStyle(fontSize: 8, color: AppColors.textMuted)),
                Text((max * 0.75).round().toString(), style: const TextStyle(fontSize: 8, color: AppColors.textMuted)),
                Text((max * 0.5).round().toString(), style: const TextStyle(fontSize: 8, color: AppColors.textMuted)),
                Text((max * 0.25).round().toString(), style: const TextStyle(fontSize: 8, color: AppColors.textMuted)),
                Text(min.round().toString(), style: const TextStyle(fontSize: 8, color: AppColors.textMuted)),
              ],
            ),
          ],
        )),
        const SizedBox(height: 12),
        Text(displayValue, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800,
            color: color, fontFamily: 'monospace')),
      ]),
    );
  }

  Color _coolantColor(double temp) {
    if (temp < 70) return AppColors.blueElectric;
    if (temp < 100) return AppColors.success;
    if (temp < 110) return AppColors.warning;
    return AppColors.danger;
  }

  Color _fuelColor(double fuel) {
    if (fuel > 30) return AppColors.success;
    if (fuel > 15) return AppColors.warning;
    return AppColors.danger;
  }

  Widget _buildBatteryCard() {
    final pct = ((_battery - 10) / (15 - 10)).clamp(0.0, 1.0);
    final color = _batteryColor(_battery);
    return GlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.battery_charging_full_rounded, color: color, size: 20),
          const SizedBox(width: 8),
          const Text('BATTERY VOLTAGE', style: TextStyle(fontSize: 10,
              color: AppColors.textMuted, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('${_battery.toStringAsFixed(1)}V', style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.w900,
              color: color, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 14),
        Stack(children: [
          Container(height: 24,
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity(0.06)))),
          FractionallySizedBox(widthFactor: pct,
            child: Container(height: 24, decoration: BoxDecoration(
              gradient: LinearGradient(colors: [color.withOpacity(0.7), color]),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [BoxShadow(color: color.withOpacity(0.4), blurRadius: 8)],
            )),
          ),
        ]),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _voltageLabel('10V', 'Dead', AppColors.danger),
          _voltageLabel('11-12V', 'Engine off', AppColors.warning),
          _voltageLabel('12.6V', 'Charged', AppColors.success),
          _voltageLabel('13.5-14.5V', 'Charging', AppColors.blueElectric),
        ]),
      ]),
    );
  }

  Color _batteryColor(double v) {
    if (v >= 13.5) return AppColors.blueElectric;
    if (v >= 12.4) return AppColors.success;
    if (v >= 11.5) return AppColors.warning;
    return AppColors.danger;
  }

  Widget _voltageLabel(String v, String label, Color color) {
    return Column(children: [
      Text(v, style: TextStyle(fontSize: 8, color: color, fontWeight: FontWeight.w700)),
      Text(label, style: const TextStyle(fontSize: 7, color: AppColors.textMuted)),
    ]);
  }

  Widget _buildRawDataCard() {
    final obd = _profile.rawObd;
    return GlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionLabel('Raw OBD2 Data'),
        ...obd.entries.where((e) => e.key != 'dtcs').map((e) => _rawRow(e.key, e.value)),
        if ((obd['dtcs'] ?? '').isNotEmpty)
          _rawRow('Fault Codes', obd['dtcs']!.replaceAll(',', '  ')),
      ]),
    );
  }

  // ── SHARED PID SECTION BUILDER ────────
  Widget _buildPidSection({
    required String title,
    required Map<String, String> pids,
    required Map<String, Map<String, dynamic>> meta,
    required bool isRefreshing,
    required VoidCallback onRefresh,
    required String emptyTitle,
    required List<Color> buttonColors,
    required Color buttonBorderColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: SectionLabel(title)),
          GestureDetector(
            onTap: isRefreshing ? null : onRefresh,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                gradient: isRefreshing ? null : LinearGradient(colors: buttonColors),
                color: isRefreshing ? AppColors.bgCard2 : null,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: buttonBorderColor),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                isRefreshing
                    ? SizedBox(width: 12, height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: buttonColors.last))
                    : const Icon(Icons.refresh_rounded, size: 13, color: Colors.white),
                const SizedBox(width: 5),
                Text(isRefreshing ? 'Reading...' : 'Refresh',
                    style: TextStyle(fontSize: 11,
                        color: isRefreshing ? AppColors.textMuted : Colors.white,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (pids.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.bgCard.withOpacity(0.7),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, color: AppColors.textMuted, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(
                _profile.engineRunning
                    ? '$emptyTitle — tap Refresh to read'
                    : 'Start the engine then tap Refresh',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
              )),
            ]),
          )
        else
          GridView.count(
            crossAxisCount: 2, shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.5,
            children: meta.entries
                .where((e) => pids.containsKey(e.key))
                .map((e) => _PsPidChip(
              label: e.value['label'] as String,
              value: pids[e.key]!,
              range: e.value['range'] as String,
              color: e.value['color'] as Color,
            ))
                .toList(),
          ),
      ],
    );
  }

  Widget _buildPowerstrokeCard() {
    final fuel = _profile.fuelType.toLowerCase();
    final eng  = _profile.engine.toLowerCase();
    if (!fuel.contains('diesel') && !eng.contains('diesel') && _psPids.isEmpty) {
      return const SizedBox.shrink();
    }

    return _buildPidSection(
      title: 'Powerstroke Mode 22',
      pids: _psPids,
      meta: {
        'ps_oil_temp':     {'label': 'Engine Oil Temp',      'color': AppColors.warning,      'range': '180–220°F'},
        'ps_icp_psi':      {'label': 'ICP / HPOP Pressure',  'color': AppColors.blueElectric, 'range': 'idle ~500 • WOT ~3800'},
        'ps_icp_target':   {'label': 'ICP Target',           'color': AppColors.blueElectric, 'range': 'matches ICP actual'},
        'ps_map_psi':      {'label': 'MAP Pressure',         'color': AppColors.teal,         'range': '14–35 psi'},
        'ps_boost_psi':    {'label': 'Boost',                'color': AppColors.blueBright,   'range': '0–30 psi'},
        'ps_boost1_psi':   {'label': 'Boost Stage 1',        'color': AppColors.blueBright,   'range': '0–25 psi'},
        'ps_boost2_psi':   {'label': 'Boost Stage 2',        'color': AppColors.blueElectric, 'range': '0–35 psi'},
        'ps_ficm_logic_v': {'label': 'FICM Logic Voltage',   'color': AppColors.violet,       'range': '48–49V ✓'},
        'ps_ficm_main_v':  {'label': 'FICM Main Voltage',    'color': AppColors.violetLight,  'range': '48–49V ✓'},
        'ps_ipr_pct':      {'label': 'IPR Duty Cycle',       'color': AppColors.success,      'range': '15–65%'},
        'ps_hpop_pct':     {'label': 'HPOP Duty',            'color': AppColors.success,      'range': '10–80%'},
        'ps_cht_f':        {'label': 'Cyl Head Temp',        'color': AppColors.danger,       'range': '180–230°F'},
        'ps_fuel_mg':      {'label': 'Mass Fuel Desired',    'color': AppColors.teal,         'range': 'varies'},
        'ps_fuel_temp_c':  {'label': 'Fuel Temp',            'color': AppColors.teal,         'range': '10–60°C'},
        'ps_vgt_pct':      {'label': 'VGT Duty',             'color': AppColors.blueElectric, 'range': '20–80%'},
        'ps_inj_timing':   {'label': 'Inj Timing',           'color': AppColors.blueBright,   'range': '0–15°'},
        'ps_trans_temp':   {'label': 'Trans Fluid Temp',     'color': AppColors.warning,      'range': '150–200°F'},
        'ps_oil_press':    {'label': 'Oil Pressure',         'color': AppColors.success,      'range': '25–80 psi'},
        'ps_oil_life':     {'label': 'Oil Life',             'color': AppColors.success,      'range': '>20% change soon'},
        'ps_egr_in_c':     {'label': 'EGR Cooler Inlet',     'color': AppColors.danger,       'range': '<200°C normal'},
        'ps_egr_out_c':    {'label': 'EGR Cooler Outlet',    'color': AppColors.warning,      'range': 'Δ <50°C from inlet'},
        'ps_rail_kpa':     {'label': 'Rail Pressure',        'color': AppColors.blueElectric, 'range': '30–180 MPa'},
        'ps_glow_relay':   {'label': 'Glow Plug Relay',      'color': AppColors.teal,         'range': 'ON when cold start'},
        'ps_dpf_soot':     {'label': 'DPF Soot Load',        'color': AppColors.warning,      'range': '<80% normal'},
        'ps_dpf_dp':       {'label': 'DPF Δ Pressure',       'color': AppColors.warning,      'range': '<5 kPa normal'},
        'ps_dpf_in_c':     {'label': 'DPF Inlet Temp',       'color': AppColors.danger,       'range': '200–600°C'},
        'ps_fuel_dilution':{'label': 'Fuel Dilution in Oil', 'color': AppColors.danger,       'range': '<2% normal'},
        'ps_def_level':    {'label': 'DEF Level',            'color': AppColors.success,      'range': '>10%'},
        'ps_def_quality':  {'label': 'DEF Quality',          'color': AppColors.success,      'range': '~32.5% urea'},
        'ps_nox_up':       {'label': 'NOx Upstream',         'color': AppColors.teal,         'range': 'varies ppm'},
        'ps_nox_dn':       {'label': 'NOx Downstream',       'color': AppColors.teal,         'range': '<50 ppm good'},
        'ps_cp4_wear':     {'label': 'CP4 Wear Index',       'color': AppColors.danger,       'range': '<50% healthy'},
      },
      isRefreshing: _psRefreshing,
      onRefresh: _refreshPowerstrokePids,
      emptyTitle: 'No Powerstroke data yet',
      buttonColors: [const Color(0xFF5B4AFF), const Color(0xFF00C3FF)],
      buttonBorderColor: AppColors.blueElectric.withOpacity(0.3),
    );
  }

  Widget _buildToyotaCard() {
    final make = _profile.make.toLowerCase();
    if (!make.contains('toyota') && !make.contains('lexus') &&
        !make.contains('scion') && _toPids.isEmpty) {
      return const SizedBox.shrink();
    }

    return _buildPidSection(
      title: 'Toyota Mode 21 Enhanced',
      pids: _toPids,
      meta: {
        'to_oil_temp':    {'label': 'Engine Oil Temp',  'color': AppColors.warning,      'range': '180–220°F'},
        'to_iat':         {'label': 'Intake Air Temp',  'color': AppColors.teal,         'range': '-40–215°C'},
        'to_maf':         {'label': 'Mass Air Flow',    'color': AppColors.blueElectric, 'range': 'varies g/s'},
        'to_stft_b1':     {'label': 'STFT Bank 1',      'color': AppColors.success,      'range': '±5% healthy'},
        'to_ltft_b1':     {'label': 'LTFT Bank 1',      'color': AppColors.success,      'range': '±5% healthy'},
        'to_stft_b2':     {'label': 'STFT Bank 2',      'color': AppColors.success,      'range': '±5% healthy'},
        'to_ltft_b2':     {'label': 'LTFT Bank 2',      'color': AppColors.success,      'range': '±5% healthy'},
        'to_cat_temp_b1': {'label': 'Cat Temp B1',      'color': AppColors.danger,       'range': '400–800°C'},
        'to_cat_temp_b2': {'label': 'Cat Temp B2',      'color': AppColors.danger,       'range': '400–800°C'},
        'to_vvti_b1':     {'label': 'VVT-i B1',         'color': AppColors.violet,       'range': '0–40° cruise'},
        'to_vvti_b2':     {'label': 'VVT-i B2',         'color': AppColors.violet,       'range': '0–40° cruise'},
        'to_o2_b1s1':     {'label': 'O2 B1S1 (up)',     'color': AppColors.blueElectric, 'range': '0.1–0.9V sweep'},
        'to_o2_b1s2':     {'label': 'O2 B1S2 (down)',   'color': AppColors.blueBright,   'range': '0.6–0.8V stable'},
        'to_o2_b2s1':     {'label': 'O2 B2S1 (up)',     'color': AppColors.blueElectric, 'range': '0.1–0.9V sweep'},
        'to_o2_b2s2':     {'label': 'O2 B2S2 (down)',   'color': AppColors.blueBright,   'range': '0.6–0.8V stable'},
        'to_knock_b1':    {'label': 'Knock Retard B1',  'color': AppColors.warning,      'range': '~0° healthy'},
        'to_knock_b2':    {'label': 'Knock Retard B2',  'color': AppColors.warning,      'range': '~0° healthy'},
        'to_trans_temp':  {'label': 'Trans Fluid Temp', 'color': AppColors.warning,      'range': '150–200°F'},
        'to_4wd':         {'label': '4WD Mode',         'color': AppColors.teal,         'range': '2WD/4H/4L'},
        'to_fuel_econ':   {'label': 'Fuel Economy',     'color': AppColors.success,      'range': 'varies mpg'},
      },
      isRefreshing: _toRefreshing,
      onRefresh: _refreshToyotaPids,
      emptyTitle: 'No Toyota data yet',
      buttonColors: [const Color(0xFF00C3FF), const Color(0xFF00E5CC)],
      buttonBorderColor: AppColors.teal.withOpacity(0.4),
    );
  }

  Widget _buildGmCard() {
    final make = _profile.make.toLowerCase();
    if (!make.contains('chevrolet') && !make.contains('chevy') &&
        !make.contains('gmc') && !make.contains('cadillac') &&
        !make.contains('buick') && _gmPids.isEmpty) {
      return const SizedBox.shrink();
    }

    return _buildPidSection(
      title: 'GM Mode 22 Enhanced',
      pids: _gmPids,
      meta: {
        'gm_oil_temp':     {'label': 'Engine Oil Temp',    'color': AppColors.warning,      'range': '180–220°F'},
        'gm_oil_press':    {'label': 'Oil Pressure',       'color': AppColors.success,      'range': '25–80 psi'},
        'gm_oil_life':     {'label': 'Oil Life',           'color': AppColors.success,      'range': '>20% change soon'},
        'gm_boost_psi':    {'label': 'Boost',              'color': AppColors.blueBright,   'range': 'Duramax 0–30 psi'},
        'gm_vgt_pct':      {'label': 'VGT Duty',           'color': AppColors.blueElectric, 'range': '20–80%'},
        'gm_rail_mpa':     {'label': 'Rail Pressure',      'color': AppColors.blueElectric, 'range': '30–160 MPa'},
        'gm_egr_in_c':     {'label': 'EGR Cooler Inlet',  'color': AppColors.danger,       'range': '<200°C normal'},
        'gm_egr_out_c':    {'label': 'EGR Cooler Outlet', 'color': AppColors.warning,      'range': 'Δ <50°C from inlet'},
        'gm_dpf_soot':     {'label': 'DPF Soot Load',     'color': AppColors.warning,      'range': '<80% normal'},
        'gm_dpf_dp':       {'label': 'DPF Δ Pressure',    'color': AppColors.warning,      'range': '<5 kPa normal'},
        'gm_dpf_in_c':     {'label': 'DPF Inlet Temp',    'color': AppColors.danger,       'range': '200–600°C'},
        'gm_def_level':    {'label': 'DEF Level',         'color': AppColors.success,      'range': '>10%'},
        'gm_def_quality':  {'label': 'DEF Quality',       'color': AppColors.success,      'range': '~32.5% urea'},
        'gm_nox_up':       {'label': 'NOx Upstream',      'color': AppColors.teal,         'range': 'varies ppm'},
        'gm_nox_dn':       {'label': 'NOx Downstream',    'color': AppColors.teal,         'range': '<50 ppm good'},
        'gm_cp4_wear':     {'label': 'CP4 Wear Index',    'color': AppColors.danger,       'range': '<50% healthy'},
        'gm_trans_temp':   {'label': 'Trans Fluid Temp',  'color': AppColors.warning,      'range': '150–200°F'},
        'gm_fuel_dilution':{'label': 'Fuel Dilution',     'color': AppColors.danger,       'range': '<2% normal'},
        'gm_fuel_press':   {'label': 'Fuel Pressure',     'color': AppColors.teal,         'range': '300–600 kPa'},
        'gm_water_fuel':   {'label': 'Water in Fuel',     'color': AppColors.danger,       'range': 'OK'},
        'gm_glow_relay':   {'label': 'Glow Plug Relay',   'color': AppColors.teal,         'range': 'ON when cold'},
        'gm_inj_timing':   {'label': 'Inj Timing',        'color': AppColors.blueBright,   'range': '0–15° BTDC'},
        'gm_o2_b1s1':      {'label': 'O2 B1S1 (up)',      'color': AppColors.blueElectric, 'range': '0.1–0.9V sweep'},
        'gm_o2_b1s2':      {'label': 'O2 B1S2 (down)',    'color': AppColors.blueBright,   'range': '0.6–0.8V stable'},
        'gm_knock_b1':     {'label': 'Knock Retard B1',   'color': AppColors.warning,      'range': '~0° healthy'},
        'gm_knock_b2':     {'label': 'Knock Retard B2',   'color': AppColors.warning,      'range': '~0° healthy'},
        'gm_vvt_in_b1':    {'label': 'VVT Intake B1',     'color': AppColors.violet,       'range': 'varies °CA'},
        'gm_vvt_in_b2':    {'label': 'VVT Intake B2',     'color': AppColors.violet,       'range': 'varies °CA'},
        'gm_afm_status':   {'label': 'AFM Status',        'color': AppColors.teal,         'range': 'All Cyl / AFM'},
        'gm_fuel_econ':    {'label': 'Fuel Economy',      'color': AppColors.success,      'range': 'varies mpg'},
      },
      isRefreshing: _gmRefreshing,
      onRefresh: _refreshGmPids,
      emptyTitle: 'No GM data yet',
      buttonColors: [const Color(0xFFFFB347), const Color(0xFFFF6B35)],
      buttonBorderColor: AppColors.warning.withOpacity(0.4),
    );
  }

  Widget _rawRow(String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(flex: 2,
            child: Text(key.replaceAll('_', ' ').toUpperCase(),
                style: const TextStyle(fontSize: 9, color: AppColors.textMuted,
                    letterSpacing: 0.8, fontFamily: 'monospace'))),
        Expanded(flex: 3,
            child: Text(value,
                style: const TextStyle(fontSize: 12, color: AppColors.blueElectric,
                    fontFamily: 'monospace', fontWeight: FontWeight.w600),
                textAlign: TextAlign.right)),
      ]),
    );
  }

  Widget _miniStat(String label, String range) {
    return Column(children: [
      Text(label, style: const TextStyle(fontSize: 8, color: AppColors.textMuted,
          fontWeight: FontWeight.w700)),
      Text(range, style: const TextStyle(fontSize: 9, color: AppColors.textSecondary)),
    ]);
  }
}

// ─────────────────────────────────────────
//  PAINTERS
// ─────────────────────────────────────────
class _GaugePainter extends CustomPainter {
  final double value;
  final Color color;
  final double strokeWidth;
  final double startAngle;
  final double sweepAngle;
  final bool withGlow;

  _GaugePainter({required this.value, required this.color,
    required this.strokeWidth, required this.startAngle,
    required this.sweepAngle, this.withGlow = false});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
        center: Offset(size.width / 2, size.height / 2),
        radius: size.width / 2 - strokeWidth / 2);
    if (withGlow && value > 0) {
      canvas.drawArc(rect, startAngle, sweepAngle * value, false, Paint()
        ..color = color.withOpacity(0.25) ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 10 ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    }
    canvas.drawArc(rect, startAngle, sweepAngle * value, false, Paint()
      ..color = color ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.value != value || old.color != color;
}

class _HalfGaugePainter extends CustomPainter {
  final double value;
  final Color color;
  final double strokeWidth;
  final bool withGlow;

  _HalfGaugePainter({required this.value, required this.color,
    required this.strokeWidth, this.withGlow = false});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
        center: Offset(size.width / 2, size.height),
        radius: size.width / 2 - strokeWidth / 2);
    if (withGlow && value > 0) {
      canvas.drawArc(rect, pi, pi * value, false, Paint()
        ..color = color.withOpacity(0.3) ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 8 ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    }
    canvas.drawArc(rect, pi, pi * value, false, Paint()
      ..color = color ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_HalfGaugePainter old) => old.value != value;
}

class _TickPainter extends CustomPainter {
  final int count;
  final double maxValue;
  _TickPainter({required this.count, required this.maxValue});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 28.0;
    final paint = Paint()..color = Colors.white.withOpacity(0.2)..strokeWidth = 1.5;
    for (int i = 0; i <= count; i++) {
      final angle = pi * 0.75 + (pi * 1.5 * i / count);
      canvas.drawLine(
        Offset(center.dx + (radius - 8) * cos(angle), center.dy + (radius - 8) * sin(angle)),
        Offset(center.dx + radius * cos(angle), center.dy + radius * sin(angle)),
        paint,
      );
      final lr = radius - 20.0;
      final lp = Offset(center.dx + lr * cos(angle), center.dy + lr * sin(angle));
      final v = ((maxValue / count) * i / 1000).round();
      final tp = TextPainter(
        text: TextSpan(text: '$v', style: TextStyle(fontSize: 8,
            color: Colors.white.withOpacity(0.3), fontFamily: 'monospace')),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, lp - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

class _Sparkline extends StatelessWidget {
  final List<double> data;
  final Color color;
  final double height;
  const _Sparkline({required this.data, required this.color, required this.height});

  @override
  Widget build(BuildContext context) => SizedBox(height: height,
      child: CustomPaint(size: Size.infinite,
          painter: _SparklinePainter(data: data, color: color)));
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _SparklinePainter({required this.data, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final min = data.reduce((a, b) => a < b ? a : b);
    final max = data.reduce((a, b) => a > b ? a : b);
    final range = (max - min).abs();
    if (range == 0) return;

    final paint = Paint()..color = color.withOpacity(0.8)..strokeWidth = 1.5
      ..style = PaintingStyle.stroke..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.3), Colors.transparent])
          .createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    final path = Path();
    final fillPath = Path();
    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - min) / range) * size.height * 0.8 - size.height * 0.1;
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();
    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.data != data;
}

// ─────────────────────────────────────────
//  PID CHIP (shared by all manufacturers)
// ─────────────────────────────────────────
class _PsPidChip extends StatelessWidget {
  final String label;
  final String value;
  final String range;
  final Color color;

  const _PsPidChip({
    required this.label,
    required this.value,
    required this.range,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bgCard2.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(fontSize: 8, color: AppColors.textMuted,
                  letterSpacing: 0.8, fontWeight: FontWeight.w600),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(value,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                  color: color, fontFamily: 'monospace')),
          Text(range,
              style: const TextStyle(fontSize: 9, color: AppColors.textMuted,
                  fontStyle: FontStyle.italic),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}