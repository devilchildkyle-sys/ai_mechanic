import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';
import 'vehicle_profile_screen.dart';
import 'nova_chat_screen.dart';

// ─────────────────────────────────────────
//  SCAN RECORD MODEL
// ─────────────────────────────────────────
class ScanRecord {
  final String id;
  final String vin;
  final String year;
  final String make;
  final String model;
  final String engine;
  final String fuelType;
  final String transmission;
  final bool engineRunning;
  final Map<String, String> rawObd;
  final DateTime scanTime;
  final int? scaryRating;

  ScanRecord({
    required this.id,
    required this.vin,
    required this.year,
    required this.make,
    required this.model,
    required this.engine,
    required this.fuelType,
    required this.transmission,
    required this.engineRunning,
    required this.rawObd,
    required this.scanTime,
    this.scaryRating,
  });

  String get displayName => '$year $make $model';
  String get engineDisplay => '$engine · $fuelType';

  Map<String, dynamic> toJson() => {
    'id': id,
    'vin': vin,
    'year': year,
    'make': make,
    'model': model,
    'engine': engine,
    'fuelType': fuelType,
    'transmission': transmission,
    'engineRunning': engineRunning,
    'rawObd': rawObd,
    'scanTime': scanTime.toIso8601String(),
    'scaryRating': scaryRating,
  };

  factory ScanRecord.fromJson(Map<String, dynamic> j) => ScanRecord(
    id: j['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
    vin: j['vin'] ?? 'UNKNOWN',
    year: j['year'] ?? 'Unknown',
    make: j['make'] ?? 'Unknown',
    model: j['model'] ?? 'Unknown',
    engine: j['engine'] ?? 'Unknown',
    fuelType: j['fuelType'] ?? 'Unknown',
    transmission: j['transmission'] ?? 'Unknown',
    engineRunning: j['engineRunning'] ?? false,
    rawObd: Map<String, String>.from(j['rawObd'] ?? {}),
    scanTime: DateTime.tryParse(j['scanTime'] ?? '') ?? DateTime.now(),
    scaryRating: j['scaryRating'],
  );

  factory ScanRecord.fromProfile(VehicleProfile profile, {int? scaryRating}) =>
      ScanRecord(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        vin: profile.vin,
        year: profile.year,
        make: profile.make,
        model: profile.model,
        engine: profile.engine,
        fuelType: profile.fuelType,
        transmission: profile.transmission,
        engineRunning: profile.engineRunning,
        rawObd: Map<String, String>.from(profile.rawObd),
        scanTime: DateTime.now(),
        scaryRating: scaryRating,
      );
}

// ─────────────────────────────────────────
//  HISTORY SERVICE
// ─────────────────────────────────────────
class HistoryService {
  static const _key = 'scan_history';
  static const _maxRecords = 50;

  static Future<List<ScanRecord>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? [];
      return raw
          .map((s) => ScanRecord.fromJson(jsonDecode(s)))
          .toList()
        ..sort((a, b) => b.scanTime.compareTo(a.scanTime));
    } catch (e) {
      return [];
    }
  }

  static Future<void> save(ScanRecord record) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? [];
      final records = raw
          .map((s) => ScanRecord.fromJson(jsonDecode(s)))
          .toList();

      // Remove duplicate VIN same-day scans — keep latest
      records.removeWhere((r) =>
      r.vin == record.vin &&
          r.vin != 'UNKNOWN' &&
          r.scanTime.day == record.scanTime.day &&
          r.scanTime.month == record.scanTime.month &&
          r.scanTime.year == record.scanTime.year);

      records.insert(0, record);

      // Keep max records
      final trimmed = records.take(_maxRecords).toList();
      await prefs.setStringList(
          _key, trimmed.map((r) => jsonEncode(r.toJson())).toList());
    } catch (e) {
      debugPrint('History save error: $e');
    }
  }

  static Future<void> delete(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? [];
      final records = raw
          .map((s) => ScanRecord.fromJson(jsonDecode(s)))
          .where((r) => r.id != id)
          .toList();
      await prefs.setStringList(
          _key, records.map((r) => jsonEncode(r.toJson())).toList());
    } catch (e) {
      debugPrint('History delete error: $e');
    }
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  // Group records by VIN
  static Map<String, List<ScanRecord>> groupByVin(List<ScanRecord> records) {
    final map = <String, List<ScanRecord>>{};
    for (final r in records) {
      final key = r.vin == 'UNKNOWN' ? '${r.make}_${r.model}' : r.vin;
      map.putIfAbsent(key, () => []).add(r);
    }
    return map;
  }
}

// ─────────────────────────────────────────
//  HISTORY SCREEN
// ─────────────────────────────────────────
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  List<ScanRecord> _records = [];
  bool _loading = true;
  final bool _groupByVehicle = true;
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final records = await HistoryService.loadAll();
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _delete(ScanRecord record) async {
    await HistoryService.delete(record.id);
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted scan for ${record.displayName}'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'OK',
            onPressed: () {},
          ),
        ),
      );
    }
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: AppColors.bgCard,
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.delete_forever_rounded,
                  color: AppColors.danger, size: 40),
              const SizedBox(height: 16),
              const Text('Clear All History',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                  'This will permanently delete all scan records. This cannot be undone.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: SecondaryButton(
                      label: 'Cancel',
                      onPressed: () => Navigator.pop(context, false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Delete All',
                      icon: Icons.delete_rounded,
                      onPressed: () => Navigator.pop(context, true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      await HistoryService.clearAll();
      await _load();
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
              const SizedBox(height: 12),
              _buildTabBar(),
              Expanded(
                child: _loading
                    ? const Center(
                    child: CircularProgressIndicator(
                        color: AppColors.blueElectric))
                    : _records.isEmpty
                    ? _buildEmpty()
                    : TabBarView(
                  controller: _tabCtrl,
                  children: [
                    _buildByVehicle(),
                    _buildAllScans(),
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
                Text('History Vault',
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                Text('All your vehicle scans',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (_records.isNotEmpty)
            GestureDetector(
              onTap: _confirmClearAll,
              child: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: AppColors.danger.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border:
                  Border.all(color: AppColors.danger.withOpacity(0.3)),
                ),
                child: const Icon(Icons.delete_outline_rounded,
                    color: AppColors.danger, size: 20),
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
        tabs: [
          Tab(text: 'By Vehicle (${HistoryService.groupByVin(_records).length})'),
          Tab(text: 'All Scans (${_records.length})'),
        ],
      ),
    );
  }

  // ── EMPTY STATE ───────────────────────
  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: AppColors.bgCard.withOpacity(0.5),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Icons.history_rounded,
                  color: AppColors.textMuted, size: 36),
            ),
            const SizedBox(height: 20),
            const Text('No Scans Yet',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
                'Connect your OBD2 dongle and scan a vehicle to start building your history.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    height: 1.5)),
          ],
        ),
      ),
    );
  }

  // ── BY VEHICLE TAB ────────────────────
  Widget _buildByVehicle() {
    final grouped = HistoryService.groupByVin(_records);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: grouped.entries.map((entry) {
        final scans = entry.value;
        final latest = scans.first;
        return _VehicleGroup(
          latest: latest,
          scanCount: scans.length,
          scans: scans,
          onDelete: _delete,
          onAskNova: (record) => _openNova(record),
        );
      }).toList(),
    );
  }

  // ── ALL SCANS TAB ─────────────────────
  Widget _buildAllScans() {
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _records.length,
      itemBuilder: (_, i) {
        return _ScanCard(
          record: _records[i],
          onDelete: () => _delete(_records[i]),
          onAskNova: () => _openNova(_records[i]),
        );
      },
    );
  }

  void _openNova(ScanRecord record) {
    final profile = VehicleProfile(
      vin: record.vin,
      year: record.year,
      make: record.make,
      model: record.model,
      engine: record.engine,
      fuelType: record.fuelType,
      transmission: record.transmission,
      engineRunning: record.engineRunning,
      rawObd: record.rawObd,
    );
    final prompt =
        'I am looking at a historical scan from ${_formatDate(record.scanTime)} for my ${record.displayName}. '
        'The readings were: ${record.rawObd.entries.map((e) => '${e.key}: ${e.value}').join(', ')}. '
        '${record.scaryRating != null ? 'The scary rating was ${record.scaryRating}/10. ' : ''}'
        'Can you analyze this data and tell me if anything has changed or if there are any trends I should watch?';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NovaChatScreen(
          vehicleProfile: profile,
          initialMessage: prompt,
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

// ─────────────────────────────────────────
//  VEHICLE GROUP CARD
// ─────────────────────────────────────────
class _VehicleGroup extends StatefulWidget {
  final ScanRecord latest;
  final int scanCount;
  final List<ScanRecord> scans;
  final Future<void> Function(ScanRecord) onDelete;
  final void Function(ScanRecord) onAskNova;

  const _VehicleGroup({
    required this.latest,
    required this.scanCount,
    required this.scans,
    required this.onDelete,
    required this.onAskNova,
  });

  @override
  State<_VehicleGroup> createState() => _VehicleGroupState();
}

class _VehicleGroupState extends State<_VehicleGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.latest;
    final dtcCount =
        int.tryParse(r.rawObd['dtc_count'] ?? '0') ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.bgCard.withOpacity(0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Vehicle header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 50, height: 50,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: AppColors.primaryGradient),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.directions_car_rounded,
                      color: Colors.white, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.displayName,
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800)),
                      Text(r.engineDisplay,
                          style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _badge(
                            '${widget.scanCount} scan${widget.scanCount > 1 ? 's' : ''}',
                            AppColors.blueElectric,
                          ),
                          const SizedBox(width: 6),
                          if (dtcCount > 0)
                            _badge('$dtcCount code${dtcCount > 1 ? 's' : ''}',
                                AppColors.danger)
                          else
                            _badge('No codes', AppColors.success),
                        ],
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),

          // Action buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => widget.onAskNova(r),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: AppColors.primaryGradient),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
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
                ),
              ],
            ),
          ),

          // Expanded scan list
          if (_expanded) ...[
            Container(
                height: 1,
                color: AppColors.border.withOpacity(0.5)),
            ...widget.scans.map((scan) => _ScanRow(
              scan: scan,
              onDelete: () => widget.onDelete(scan),
            )),
          ],
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding:
      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 9,
              color: color,
              fontWeight: FontWeight.w700)),
    );
  }
}

// ─────────────────────────────────────────
//  SCAN ROW (inside vehicle group)
// ─────────────────────────────────────────
class _ScanRow extends StatelessWidget {
  final ScanRecord scan;
  final VoidCallback onDelete;

  const _ScanRow({required this.scan, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          const Icon(Icons.access_time_rounded,
              color: AppColors.textMuted, size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_formatDateTime(scan.scanTime),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                Text(
                  _buildReadingsSummary(scan),
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (scan.scaryRating != null)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _ratingColor(scan.scaryRating!)
                    .withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('${scan.scaryRating}/10',
                  style: TextStyle(
                      fontSize: 10,
                      color: _ratingColor(scan.scaryRating!),
                      fontWeight: FontWeight.w700)),
            ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onDelete,
            child: const Icon(Icons.close_rounded,
                color: AppColors.textMuted, size: 16),
          ),
        ],
      ),
    );
  }

  String _buildReadingsSummary(ScanRecord r) {
    final parts = <String>[];
    if (r.rawObd['rpm'] != null) parts.add(r.rawObd['rpm']!);
    if (r.rawObd['battery'] != null) parts.add(r.rawObd['battery']!);
    if (r.rawObd['coolant_temp'] != null) {
      parts.add(r.rawObd['coolant_temp']!);
    }
    final dtc = int.tryParse(r.rawObd['dtc_count'] ?? '0') ?? 0;
    if (dtc > 0) parts.add('$dtc fault code${dtc > 1 ? 's' : ''}');
    return parts.isEmpty ? 'Engine off scan' : parts.join(' · ');
  }

  Color _ratingColor(int rating) {
    if (rating <= 3) return AppColors.success;
    if (rating <= 6) return AppColors.warning;
    if (rating <= 8) return const Color(0xFFFF6B35);
    return AppColors.danger;
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    final time =
        '${dt.hour % 12 == 0 ? 12 : dt.hour % 12}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'PM' : 'AM'}';
    if (diff.inDays == 0) return 'Today $time';
    if (diff.inDays == 1) return 'Yesterday $time';
    return '${dt.month}/${dt.day}/${dt.year} $time';
  }
}

// ─────────────────────────────────────────
//  FLAT SCAN CARD (all scans tab)
// ─────────────────────────────────────────
class _ScanCard extends StatelessWidget {
  final ScanRecord record;
  final VoidCallback onDelete;
  final VoidCallback onAskNova;

  const _ScanCard({
    required this.record,
    required this.onDelete,
    required this.onAskNova,
  });

  @override
  Widget build(BuildContext context) {
    final dtcCount =
        int.tryParse(record.rawObd['dtc_count'] ?? '0') ?? 0;

    return Dismissible(
      key: Key(record.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.danger.withOpacity(0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_rounded,
            color: AppColors.danger, size: 24),
      ),
      onDismissed: (_) => onDelete(),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.bgCard.withOpacity(0.7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: AppColors.primaryGradient),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.directions_car_rounded,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(record.displayName,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                  Text(
                    '${_formatDate(record.scanTime)} · ${record.rawObd['battery'] ?? ''}'
                        '${record.engineRunning ? ' · ${record.rawObd['rpm'] ?? ''}' : ' · Engine off'}',
                    style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (record.scaryRating != null)
                  Text('${record.scaryRating}/10',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: _ratingColor(record.scaryRating!),
                          fontFamily: 'monospace')),
                const SizedBox(height: 2),
                Text(
                  dtcCount > 0
                      ? '$dtcCount code${dtcCount > 1 ? 's' : ''}'
                      : 'No codes',
                  style: TextStyle(
                      fontSize: 9,
                      color: dtcCount > 0
                          ? AppColors.danger
                          : AppColors.success,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _ratingColor(int rating) {
    if (rating <= 3) return AppColors.success;
    if (rating <= 6) return AppColors.warning;
    if (rating <= 8) return const Color(0xFFFF6B35);
    return AppColors.danger;
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}