import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'main.dart';
import 'config.dart';
import 'vehicle_profile_screen.dart';

// ─────────────────────────────────────────
//  KNOWN ISSUE WATCH ITEM
//  Nova creates these based on the VIN.
//  Each one tells the app what to monitor
//  and what threshold is suspicious —
//  things the stock ECU would never flag.
// ─────────────────────────────────────────
class WatchItem {
  final String pid;
  final String name;
  final String description;
  final String whatToWatch;
  final String severity;       // 'info' | 'warning' | 'critical'
  final double? warnBelow;
  final double? warnAbove;
  final String unit;

  bool triggered = false;
  double? lastValue;

  WatchItem({
    required this.pid,
    required this.name,
    required this.description,
    required this.whatToWatch,
    required this.severity,
    this.warnBelow,
    this.warnAbove,
    required this.unit,
  });

  Color get color {
    switch (severity) {
      case 'critical': return const Color(0xFFFF4D6D);
      case 'warning':  return const Color(0xFFFFB347);
      default:         return const Color(0xFF00C3FF);
    }
  }

  IconData get icon {
    switch (severity) {
      case 'critical': return Icons.error_rounded;
      case 'warning':  return Icons.warning_rounded;
      default:         return Icons.info_rounded;
    }
  }
}

// ─────────────────────────────────────────
//  VEHICLE MODULE
//  Represents a scannable ECU module
//  beyond the standard OBD2 ECM
// ─────────────────────────────────────────
class VehicleModule {
  final String id;
  final String name;
  final String serviceId;    // CAN header address for this module
  final List<String> pids;
  final IconData icon;
  final Color color;

  bool enabled;
  Map<String, String> data = {};
  bool available = false;
  String? error;

  VehicleModule({
    required this.id,
    required this.name,
    required this.serviceId,
    required this.pids,
    required this.icon,
    required this.color,
    this.enabled = false,
  });
}

// ─────────────────────────────────────────
//  VEHICLE INTELLIGENCE RESULT
// ─────────────────────────────────────────
class VehicleIntelligence {
  final List<Map<String, String>> smartPids;
  final List<WatchItem> watchItems;
  final String vehicleSummary;
  final String knownIssuesSummary;
  final List<VehicleModule> availableModules;

  VehicleIntelligence({
    required this.smartPids,
    required this.watchItems,
    required this.vehicleSummary,
    required this.knownIssuesSummary,
    required this.availableModules,
  });
}

// ─────────────────────────────────────────
//  NOVA VEHICLE INTELLIGENCE SERVICE
// ─────────────────────────────────────────
class NovaVehicleIntelligenceService {

  static Future<VehicleIntelligence> analyze({
    required Map<String, String> vehicleInfo,
    required Set<String> supportedPids,
    required bool engineRunning,
  }) async {
    try {
      final prompt = _buildPrompt(vehicleInfo, supportedPids, engineRunning);
      final result = await _callNova(prompt);
      return _parse(result, vehicleInfo);
    } catch (e) {
      debugPrint('Nova intelligence error: $e');
      return _fallback(vehicleInfo);
    }
  }

  static String _buildPrompt(
      Map<String, String> info, Set<String> pids, bool engineRunning) {
    return '''
You are an expert automotive AI mechanic. A ${info['year']} ${info['make']} ${info['model']} with a ${info['engine']} ${info['fuelType']} engine just connected.

Supported OBD2 PIDs: ${pids.isEmpty ? 'unknown — assume common PIDs' : pids.join(', ')}
Standard PIDs already polled: RPM(0C), Coolant(05), Speed(0D), Throttle(11), Fuel(2F), Battery(ATRV)
Engine running: $engineRunning

Your tasks:
1. Research the top known failure points for this EXACT vehicle
2. Select additional PIDs to monitor that are relevant to those issues
3. Set up "watch items" — specific value thresholds that indicate early warning of known problems
   (These are things the stock ECU would NOT flag — you are the expert catching them early)
4. List relevant ECU modules to scan beyond the main ECM

Example thinking for a 2006 Ford F-250 6.0L diesel:
- EGR cooler failure: coolant temp spike above 107°C or coolant loss pattern
- Oil cooler: oil pressure at idle below 30 PSI warns of blocked cooler
- Head gasket: white smoke + coolant consumption + high temp with normal thermostat
- FICM voltage: below 45V causes hard starts — standard ECU never reads this
- Turbo boost: MAP below 170 kPa at WOT = boost leak or bad vanes

Respond ONLY with this JSON (no other text):
{
  "vehicle_summary": "1-2 sentence personality of this vehicle — strengths and known weak points",
  "known_issues_summary": "Top known issues for this specific vehicle in 2-3 sentences",
  "smart_pids": [
    {"pid": "0F", "name": "Intake Air Temp", "unit": "°C", "description": "Monitors charge air temperature — high temp can indicate intercooler issues"},
    {"pid": "0B", "name": "MAP / Boost", "unit": "kPa", "description": "Manifold absolute pressure — low boost = turbo or boost leak"}
  ],
  "watch_items": [
    {
      "pid": "05",
      "name": "Coolant Temp — EGR Watch",
      "description": "EGR cooler failure on 6.0 Power Stroke causes coolant loss and overheating",
      "what_to_watch": "Alert if coolant exceeds 107°C — possible EGR or oil cooler failure",
      "severity": "critical",
      "warn_above": 107,
      "warn_below": null,
      "unit": "°C"
    }
  ],
  "modules": [
    {
      "id": "TCM",
      "name": "Transmission Control Module",
      "service_id": "7E1",
      "pids": ["61","62","63"],
      "relevant": true,
      "reason": "5R110 transmission has known TCC lockup and converter clutch issues"
    },
    {
      "id": "ABS",
      "name": "ABS / Brake Module",
      "service_id": "7B0",
      "pids": ["01","02"],
      "relevant": true,
      "reason": "Wheel speed sensors can fail before setting a DTC"
    },
    {
      "id": "TPMS",
      "name": "Tire Pressure Monitor",
      "service_id": "7B4",
      "pids": ["A0","A1","A2","A3"],
      "relevant": true,
      "reason": "Individual tire pressures and temperatures per corner"
    },
    {
      "id": "FICM",
      "name": "Fuel Injection Control Module",
      "service_id": "7E1",
      "pids": ["D1","D2"],
      "relevant": true,
      "reason": "FICM voltage below 45V causes misfires — ECM does not monitor this"
    }
  ]
}
''';
  }

  static Future<String> _callNova(String prompt) async {
    final url = Uri.parse(
      'https://bedrock-runtime.${AppConfig.awsRegion}.amazonaws.com'
          '/model/amazon.nova-lite-v1:0/invoke',
    );
    final body = jsonEncode({
      'messages': [
        {
          'role': 'user',
          'content': [{'text': prompt}],
        }
      ],
      'inferenceConfig': {'maxTokens': 2000, 'temperature': 0.2},
    });

    final signer = AwsSigV4Signer(
      accessKey: AppConfig.awsAccessKey,
      secretKey: AppConfig.awsSecretKey,
      region: AppConfig.awsRegion,
      service: 'bedrock',
    );
    final headers = signer.sign(method: 'POST', uri: url, body: body);
    final response = await http.post(url, headers: headers, body: body);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['output']['message']['content'][0]['text'] ?? '';
    }
    throw Exception('Nova ${response.statusCode}');
  }

  static VehicleIntelligence _parse(
      String text, Map<String, String> vehicleInfo) {
    try {
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start == -1 || end == -1) return _fallback(vehicleInfo);

      final json = jsonDecode(text.substring(start, end + 1));

      final smartPids = <Map<String, String>>[];
      for (final p in (json['smart_pids'] as List? ?? [])) {
        smartPids.add({
          'pid': p['pid']?.toString() ?? '',
          'name': p['name']?.toString() ?? '',
          'unit': p['unit']?.toString() ?? '',
          'description': p['description']?.toString() ?? '',
        });
      }

      final watchItems = <WatchItem>[];
      for (final w in (json['watch_items'] as List? ?? [])) {
        watchItems.add(WatchItem(
          pid: w['pid']?.toString() ?? '',
          name: w['name']?.toString() ?? '',
          description: w['description']?.toString() ?? '',
          whatToWatch: w['what_to_watch']?.toString() ?? '',
          severity: w['severity']?.toString() ?? 'info',
          warnAbove: (w['warn_above'] as num?)?.toDouble(),
          warnBelow: (w['warn_below'] as num?)?.toDouble(),
          unit: w['unit']?.toString() ?? '',
        ));
      }

      final modules = <VehicleModule>[];
      for (final m in (json['modules'] as List? ?? [])) {
        if (m['relevant'] == true) {
          modules.add(VehicleModule(
            id: m['id']?.toString() ?? 'UNK',
            name: m['name']?.toString() ?? '',
            serviceId: m['service_id']?.toString() ?? '7DF',
            pids: List<String>.from(m['pids'] ?? []),
            icon: _moduleIcon(m['id']?.toString() ?? ''),
            color: _moduleColor(m['id']?.toString() ?? ''),
          ));
        }
      }

      return VehicleIntelligence(
        smartPids: smartPids,
        watchItems: watchItems,
        vehicleSummary: json['vehicle_summary']?.toString() ?? '',
        knownIssuesSummary: json['known_issues_summary']?.toString() ?? '',
        availableModules: modules,
      );
    } catch (e) {
      debugPrint('Parse intelligence error: $e');
      return _fallback(vehicleInfo);
    }
  }

  static VehicleIntelligence _fallback(Map<String, String> vehicleInfo) {
    return VehicleIntelligence(
      smartPids: [],
      watchItems: [],
      vehicleSummary:
      'Standard monitoring active for ${vehicleInfo['year']} ${vehicleInfo['make']} ${vehicleInfo['model']}.',
      knownIssuesSummary:
      'Vehicle-specific analysis unavailable — check internet connection.',
      availableModules: [
        VehicleModule(
          id: 'TCM', name: 'Transmission Control Module',
          serviceId: '7E1', pids: ['61', '62'],
          icon: Icons.settings_rounded,
          color: const Color(0xFF8B7FFF),
        ),
        VehicleModule(
          id: 'TPMS', name: 'Tire Pressure Monitor',
          serviceId: '7B4', pids: ['A0', 'A1', 'A2', 'A3'],
          icon: Icons.tire_repair_rounded,
          color: const Color(0xFF00E5C3),
        ),
      ],
    );
  }

  static IconData _moduleIcon(String id) {
    switch (id) {
      case 'TCM':  return Icons.settings_rounded;
      case 'ABS':  return Icons.emergency_rounded;
      case 'TPMS': return Icons.tire_repair_rounded;
      case 'FICM': return Icons.flash_on_rounded;
      case 'BCM':  return Icons.electrical_services_rounded;
      case 'IPC':  return Icons.speed_rounded;
      default:     return Icons.memory_rounded;
    }
  }

  static Color _moduleColor(String id) {
    switch (id) {
      case 'TCM':  return const Color(0xFF8B7FFF);
      case 'ABS':  return const Color(0xFFFF4D6D);
      case 'TPMS': return const Color(0xFF00E5C3);
      case 'FICM': return const Color(0xFFFFB347);
      case 'BCM':  return const Color(0xFF4D9FFF);
      default:     return const Color(0xFF00C3FF);
    }
  }
}

// ─────────────────────────────────────────
//  MODULE OBD2 SCANNER
//  Sends targeted requests to specific
//  ECU modules using their CAN header
// ─────────────────────────────────────────
class ModuleScanner {
  final OBD2Service _obd;
  ModuleScanner(this._obd);

  Future<bool> pingModule(VehicleModule module) async {
    try {
      await _obd.sendRaw('ATSH${module.serviceId}');
      await Future.delayed(const Duration(milliseconds: 200));
      final response = await _obd.sendRaw('2101');
      await _obd.sendRaw('ATSH7DF');
      return response.isNotEmpty &&
          !response.contains('NO DATA') &&
          !response.contains('ERROR');
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> scanModule(VehicleModule module) async {
    final results = <String, String>{};
    try {
      await _obd.sendRaw('ATSH${module.serviceId}');
      await Future.delayed(const Duration(milliseconds: 200));

      for (final pid in module.pids) {
        final response = await _obd.sendRaw('22$pid');
        if (response.isNotEmpty &&
            !response.contains('NO DATA') &&
            !response.contains('ERROR')) {
          results[pid] = response.trim();
        }
      }
      await _obd.sendRaw('ATSH7DF'); // reset to broadcast
    } catch (e) {
      module.error = 'Scan failed';
    }
    return results;
  }
}

// ─────────────────────────────────────────
//  WATCH ITEM EVALUATOR
//  Runs every poll cycle — checks live
//  values against Nova's thresholds
// ─────────────────────────────────────────
class WatchItemEvaluator {
  static void evaluateAll(
      List<WatchItem> items, Map<String, String> obdData) {
    for (final item in items) {
      String? rawValue;
      switch (item.pid) {
        case '05': rawValue = obdData['coolant_temp']; break;
        case '0C': rawValue = obdData['rpm']; break;
        case '0D': rawValue = obdData['speed']; break;
        case '11': rawValue = obdData['throttle']; break;
        case '2F': rawValue = obdData['fuel_level']; break;
        default:   rawValue = obdData[item.pid];
      }
      if (rawValue != null) {
        final v = _parse(rawValue);
        if (v != null) _evaluate(item, v);
      }
    }
  }

  static void _evaluate(WatchItem item, double value) {
    item.lastValue = value;
    item.triggered =
        (item.warnAbove != null && value > item.warnAbove!) ||
            (item.warnBelow != null && value < item.warnBelow!);
  }

  static double? _parse(String raw) {
    final m = RegExp(r'[-+]?\d+\.?\d*').firstMatch(raw);
    return m != null ? double.tryParse(m.group(0)!) : null;
  }
}

// ─────────────────────────────────────────
//  VEHICLE INTELLIGENCE PANEL WIDGET
// ─────────────────────────────────────────
class VehicleIntelligencePanel extends StatefulWidget {
  final VehicleIntelligence intelligence;
  final VoidCallback? onModulesChanged;

  const VehicleIntelligencePanel({
    super.key,
    required this.intelligence,
    this.onModulesChanged,
  });

  @override
  State<VehicleIntelligencePanel> createState() =>
      _VehicleIntelligencePanelState();
}

class _VehicleIntelligencePanelState
    extends State<VehicleIntelligencePanel> {
  bool _showModules = false;

  @override
  Widget build(BuildContext context) {
    final intel = widget.intelligence;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        // ── NOVA VEHICLE BRIEF ────────────
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.blueCore.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppColors.blueCore.withOpacity(0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32, height: 32,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          colors: AppColors.primaryGradient),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.psychology_rounded,
                        color: Colors.white, size: 16),
                  ),
                  const SizedBox(width: 10),
                  const Text('Nova Vehicle Intel',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.blueBright,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5)),
                ],
              ),
              const SizedBox(height: 10),
              Text(intel.vehicleSummary,
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textPrimary,
                      height: 1.4)),
              const SizedBox(height: 6),
              Text(intel.knownIssuesSummary,
                  style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                      height: 1.4)),
            ],
          ),
        ),

        // ── WATCH ITEMS ───────────────────
        if (intel.watchItems.isNotEmpty) ...[
          const SizedBox(height: 16),
          const SectionLabel('Nova Watch Items'),
          ...intel.watchItems.map((item) => _WatchItemCard(item: item)),
        ],

        // ── MODULE SCANNER ────────────────
        if (intel.availableModules.isNotEmpty) ...[
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _showModules = !_showModules),
            child: Row(
              children: [
                const Expanded(child: SectionLabel('Module Scanner')),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.bgCard.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${intel.availableModules.where((m) => m.enabled).length} active',
                        style: const TextStyle(
                            fontSize: 9,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _showModules
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 14,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_showModules) ...[
            const SizedBox(height: 8),
            ...intel.availableModules.map((mod) => _ModuleCard(
              module: mod,
              onToggle: (val) {
                setState(() => mod.enabled = val);
                widget.onModulesChanged?.call();
              },
            )),
          ],
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────
//  WATCH ITEM CARD
// ─────────────────────────────────────────
class _WatchItemCard extends StatelessWidget {
  final WatchItem item;
  const _WatchItemCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: item.triggered
            ? item.color.withOpacity(0.12)
            : AppColors.bgCard.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: item.triggered
              ? item.color.withOpacity(0.5)
              : AppColors.border,
          width: item.triggered ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: item.color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(item.icon, color: item.color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(item.name,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: item.triggered
                            ? item.color.withOpacity(0.2)
                            : AppColors.success.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        item.triggered ? 'ALERT' : 'OK',
                        style: TextStyle(
                            fontSize: 8,
                            color: item.triggered
                                ? item.color
                                : AppColors.success,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(item.description,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        height: 1.3)),
                const SizedBox(height: 4),
                Text(item.whatToWatch,
                    style: TextStyle(
                        fontSize: 10,
                        color: item.color.withOpacity(0.8),
                        height: 1.3,
                        fontStyle: FontStyle.italic)),
                if (item.lastValue != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Current: ${item.lastValue!.toStringAsFixed(1)} ${item.unit}',
                    style: TextStyle(
                        fontSize: 10,
                        color: item.triggered
                            ? item.color
                            : AppColors.textMuted,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  MODULE CARD
// ─────────────────────────────────────────
class _ModuleCard extends StatelessWidget {
  final VehicleModule module;
  final ValueChanged<bool> onToggle;

  const _ModuleCard({required this.module, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: module.enabled
            ? module.color.withOpacity(0.06)
            : AppColors.bgCard.withOpacity(0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: module.enabled
              ? module.color.withOpacity(0.3)
              : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: module.enabled
                  ? module.color.withOpacity(0.15)
                  : AppColors.bgCard2.withOpacity(0.6),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(module.icon,
                color: module.enabled
                    ? module.color
                    : AppColors.textMuted,
                size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(module.id,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: module.enabled
                            ? module.color
                            : AppColors.textPrimary)),
                Text(module.name,
                    style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary)),
                if (module.available && module.data.isNotEmpty)
                  Text('${module.data.length} values read',
                      style: const TextStyle(
                          fontSize: 9,
                          color: AppColors.success,
                          fontWeight: FontWeight.w600)),
                if (module.error != null)
                  Text(module.error!,
                      style: const TextStyle(
                          fontSize: 9, color: AppColors.danger)),
              ],
            ),
          ),
          Switch(
            value: module.enabled,
            onChanged: onToggle,
            activeThumbColor: module.color,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  WATCH ALERT BANNER
//  Slides in from top when a watch item fires
// ─────────────────────────────────────────
class WatchAlertBanner extends StatefulWidget {
  final WatchItem item;
  final VoidCallback onDismiss;

  const WatchAlertBanner({
    super.key,
    required this.item,
    required this.onDismiss,
  });

  @override
  State<WatchAlertBanner> createState() => _WatchAlertBannerState();
}

class _WatchAlertBannerState extends State<WatchAlertBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _slide = Tween<Offset>(
        begin: const Offset(0, -1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return SlideTransition(
      position: _slide,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: item.color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(16),
          border:
          Border.all(color: item.color.withOpacity(0.5), width: 1.5),
          boxShadow: [
            BoxShadow(
                color: item.color.withOpacity(0.25),
                blurRadius: 16,
                offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          children: [
            Icon(item.icon, color: item.color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NOVA ALERT — ${item.name}',
                      style: TextStyle(
                          fontSize: 11,
                          color: item.color,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5)),
                  Text(item.whatToWatch,
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textPrimary,
                          height: 1.3)),
                  if (item.lastValue != null)
                    Text(
                        'Reading: ${item.lastValue!.toStringAsFixed(1)} ${item.unit}',
                        style: TextStyle(
                            fontSize: 10,
                            color: item.color,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            GestureDetector(
              onTap: widget.onDismiss,
              child: Icon(Icons.close_rounded,
                  color: item.color.withOpacity(0.7), size: 18),
            ),
          ],
        ),
      ),
    );
  }
}