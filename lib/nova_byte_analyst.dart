// ─────────────────────────────────────────────────────────────────────────────
//  nova_byte_analyst.dart
//
//  Nova Byte Analyst — AI-powered PID formula discovery
//
//  HOW IT WORKS:
//  1. Sends a PID request to the OBD2 device multiple times under varying
//     conditions (engine warming up, different RPMs, etc.)
//  2. Captures the FULL raw hex response each time — no byte stripping
//  3. Sends all samples to Nova AI with context about what the sensor measures
//  4. Nova identifies which bytes are changing vs static (identifier bytes),
//     and proposes a formula with the correct byte positions
//  5. User validates the decoded value against a known reference (temp gauge,
//     Torque Pro, etc.)
//  6. Confirmed formulas are saved locally and override the CSV defaults
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'main.dart';
import 'vehicle_profile_screen.dart';
import 'pid_definitions.dart';

// ─────────────────────────────────────────────
//  VALIDATED FORMULA STORE
//  Saves user-confirmed formulas locally so they
//  override the defaults for that vehicle+PID combo
// ─────────────────────────────────────────────
class ValidatedFormulaStore {
  static const _prefix = 'validated_formula_';

  static String _key(String vehicleMake, String pid) =>
      '$_prefix${vehicleMake.toUpperCase()}_${pid.toUpperCase()}';

  static Future<void> save(String vehicleMake, String pid, ValidatedFormula formula) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(vehicleMake, pid), jsonEncode(formula.toJson()));
  }

  static Future<ValidatedFormula?> load(String vehicleMake, String pid) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(vehicleMake, pid));
    if (raw == null) return null;
    try {
      return ValidatedFormula.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<List<ValidatedFormula>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix));
    final results = <ValidatedFormula>[];
    for (final k in keys) {
      final raw = prefs.getString(k);
      if (raw != null) {
        try {
          results.add(ValidatedFormula.fromJson(jsonDecode(raw)));
        } catch (_) {}
      }
    }
    return results;
  }
}

class ValidatedFormula {
  final String vehicleMake;
  final String pid;
  final String pidName;
  final String formula;
  final String unit;
  final String byteExplanation;
  final List<String> rawSamples;
  final DateTime validatedAt;
  final String? validatedBy; // e.g. "Torque Pro", "temperature gauge"

  ValidatedFormula({
    required this.vehicleMake,
    required this.pid,
    required this.pidName,
    required this.formula,
    required this.unit,
    required this.byteExplanation,
    required this.rawSamples,
    required this.validatedAt,
    this.validatedBy,
  });

  Map<String, dynamic> toJson() => {
    'vehicleMake': vehicleMake,
    'pid': pid,
    'pidName': pidName,
    'formula': formula,
    'unit': unit,
    'byteExplanation': byteExplanation,
    'rawSamples': rawSamples,
    'validatedAt': validatedAt.toIso8601String(),
    'validatedBy': validatedBy,
  };

  factory ValidatedFormula.fromJson(Map<String, dynamic> j) => ValidatedFormula(
    vehicleMake: j['vehicleMake'],
    pid: j['pid'],
    pidName: j['pidName'],
    formula: j['formula'],
    unit: j['unit'],
    byteExplanation: j['byteExplanation'],
    rawSamples: List<String>.from(j['rawSamples'] ?? []),
    validatedAt: DateTime.parse(j['validatedAt']),
    validatedBy: j['validatedBy'],
  );
}

// ─────────────────────────────────────────────
//  NOVA BYTE ANALYST SERVICE
// ─────────────────────────────────────────────
class NovaByteAnalyst {
  // Nova API URL — same endpoint used throughout the app (see config.dart)

  /// Capture N raw samples from a PID over a given duration
  static Future<List<String>> captureSamples({
    required OBD2Service obd2,
    required String pidHex,
    required String canHeader,
    int sampleCount = 8,
    Duration interval = const Duration(milliseconds: 600),
  }) async {
    final samples = <String>[];

    for (int i = 0; i < sampleCount; i++) {
      try {
        // Send header if needed (for non-standard ECU targets)
        if (canHeader.isNotEmpty && canHeader != 'Auto' && canHeader != '') {
          await obd2.sendRaw('ATSH $canHeader');
          await Future.delayed(const Duration(milliseconds: 50));
        }

        // Request the PID — use full 2-byte mode 22 format
        String command;
        final pidClean = pidHex.replaceAll('0x', '').replaceAll('0X', '');
        if (pidClean.length <= 4) {
          // Mode 22 2-byte PID: e.g. 221310 → send as "22 13 10"
          if (pidClean.length == 4) {
            command = '22$pidClean';
          } else {
            command = pidClean; // Standard PID like 010C
          }
        } else {
          command = pidClean; // Full command already
        }

        final raw = await obd2.sendRaw(command);

        if (raw.isNotEmpty && !raw.contains('NO DATA') && !raw.contains('ERROR')) {
          // Store the FULL raw response, no stripping
          final clean = raw.replaceAll(RegExp(r'[\r\n\s]'), '').toUpperCase();
          if (clean.isNotEmpty) {
            samples.add(clean);
          }
        }
      } catch (_) {}

      await Future.delayed(interval);
    }

    return samples;
  }

  /// Ask Nova AI to analyze the raw byte samples and propose a formula
  static Future<NovaAnalysisResult> analyzeWithNova({
    required List<String> rawSamples,
    required PidDefinition pid,
    required String vehicleDescription,
    required String apiKey,
  }) async {
    if (rawSamples.isEmpty) {
      return NovaAnalysisResult.error('No samples captured');
    }

    // Build a table showing each sample with individual bytes labeled
    final sampleTable = StringBuffer();
    for (int i = 0; i < rawSamples.length; i++) {
      final hex = rawSamples[i];
      final bytes = <String>[];
      for (int j = 0; j + 1 < hex.length; j += 2) {
        bytes.add(hex.substring(j, j + 2));
      }
      final byteLabels = List.generate(bytes.length, (idx) => 'B${idx + 1}');
      if (i == 0) {
        sampleTable.writeln('Position: ${byteLabels.join('  ')}');
        sampleTable.writeln('Decimal:  ${bytes.map((b) => int.parse(b, radix: 16).toString().padLeft(3)).join('  ')}');
        sampleTable.writeln('---');
      }
      final decimals = bytes.map((b) => int.parse(b, radix: 16).toString().padLeft(3)).join('  ');
      sampleTable.writeln('Sample${i + 1}: $decimals  (hex: ${bytes.join(' ')})');
    }

    final prompt = '''
You are an expert OBD2 automotive engineer analyzing raw ECU responses.

VEHICLE: $vehicleDescription
PID: ${pid.pid}
SENSOR NAME: ${pid.name}
EXPECTED UNIT: ${pid.unit}
EXPECTED RANGE: ${pid.minValue} to ${pid.maxValue} ${pid.unit}
CURRENT FORMULA IN DATABASE: ${pid.formula}

RAW BYTE SAMPLES (captured live from the vehicle, ${rawSamples.length} samples):
$sampleTable

TASK:
1. Identify which bytes are STATIC (part of the OBD2 response header/mode/PID echo) - these never change
2. Identify which bytes are DATA bytes (they change between samples) - these are A, B, C etc.
3. Determine the correct byte positions - note: OBD2 Mode 22 response format is:
   [62] [PID_HIGH] [PID_LOW] [DATA_A] [DATA_B] ...
   So for a 5-byte response, bytes 1-3 are header/echo, bytes 4-5 are A and B
4. Propose the correct formula using A, B, C notation where A=first data byte
5. Verify your formula produces values in the expected range for this sensor
6. Note if the formula in the database appears correct or incorrect

Respond ONLY in this exact JSON format:
{
  "staticBytes": [list of 1-indexed byte positions that never change],
  "dataBytes": [list of 1-indexed byte positions that change, labeled as A, B, C...],
  "byteExplanation": "plain English explanation of what each byte is",
  "proposedFormula": "formula using A, B, C notation",
  "sampleDecodedValues": [list of decoded values for each sample using your formula],
  "expectedRangeMatch": true or false,
  "databaseFormulaCorrect": true or false,
  "databaseFormulaIssue": "description of what was wrong, or null if correct",
  "confidence": "high/medium/low",
  "notes": "any other observations"
}
''';

    try {
      final response = await http.post(
        Uri.parse('https://bedrock-runtime.\${AppConfig.awsRegion}.amazonaws.com'
            '/model/amazon.nova-lite-v1:0/invoke'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'modelId': 'amazon.nova-lite-v1:0',
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'inferenceConfig': {'maxTokens': 1000},
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = (data['output']?['message']?['content'] as List?)
            ?.firstWhere((c) => c['type'] == 'text', orElse: () => null)
        ?['text'] ?? '';

        // Extract JSON from response
        final jsonStart = text.indexOf('{');
        final jsonEnd = text.lastIndexOf('}');
        if (jsonStart != -1 && jsonEnd != -1) {
          final parsed = jsonDecode(text.substring(jsonStart, jsonEnd + 1));
          return NovaAnalysisResult.fromJson(parsed, rawSamples);
        }
      }
    } catch (e) {
      return NovaAnalysisResult.error('Nova API error: $e');
    }

    return NovaAnalysisResult.error('Could not parse Nova response');
  }
}

class NovaAnalysisResult {
  final bool success;
  final String? errorMessage;
  final List<int> staticBytes;
  final List<int> dataBytes;
  final String byteExplanation;
  final String proposedFormula;
  final List<double> sampleDecodedValues;
  final bool expectedRangeMatch;
  final bool databaseFormulaCorrect;
  final String? databaseFormulaIssue;
  final String confidence;
  final String? notes;
  final List<String> rawSamples;

  NovaAnalysisResult({
    required this.success,
    this.errorMessage,
    this.staticBytes = const [],
    this.dataBytes = const [],
    this.byteExplanation = '',
    this.proposedFormula = '',
    this.sampleDecodedValues = const [],
    this.expectedRangeMatch = false,
    this.databaseFormulaCorrect = false,
    this.databaseFormulaIssue,
    this.confidence = 'low',
    this.notes,
    this.rawSamples = const [],
  });

  factory NovaAnalysisResult.error(String msg) => NovaAnalysisResult(
    success: false, errorMessage: msg,
  );

  factory NovaAnalysisResult.fromJson(Map<String, dynamic> j, List<String> samples) {
    return NovaAnalysisResult(
      success: true,
      staticBytes: List<int>.from(j['staticBytes'] ?? []),
      dataBytes: List<int>.from(j['dataBytes'] ?? []),
      byteExplanation: j['byteExplanation'] ?? '',
      proposedFormula: j['proposedFormula'] ?? '',
      sampleDecodedValues: (j['sampleDecodedValues'] as List? ?? [])
          .map((v) => (v as num).toDouble())
          .toList(),
      expectedRangeMatch: j['expectedRangeMatch'] ?? false,
      databaseFormulaCorrect: j['databaseFormulaCorrect'] ?? false,
      databaseFormulaIssue: j['databaseFormulaIssue'],
      confidence: j['confidence'] ?? 'low',
      notes: j['notes'],
      rawSamples: samples,
    );
  }
}

// ─────────────────────────────────────────────
//  NOVA BYTE ANALYST SCREEN
// ─────────────────────────────────────────────
class NovaByteAnalystScreen extends StatefulWidget {
  final OBD2Service obd2;
  final PidDefinition pid;
  final String vehicleMake;
  final String vehicleDescription;

  const NovaByteAnalystScreen({
    super.key,
    required this.obd2,
    required this.pid,
    required this.vehicleMake,
    required this.vehicleDescription,
  });

  @override
  State<NovaByteAnalystScreen> createState() => _NovaByteAnalystScreenState();
}

class _NovaByteAnalystScreenState extends State<NovaByteAnalystScreen>
    with SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.idle;
  List<String> _samples = [];
  NovaAnalysisResult? _result;
  String _statusMsg = '';
  int _sampleCount = 0;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _startCapture() async {
    setState(() {
      _phase = _Phase.capturing;
      _samples = [];
      _sampleCount = 0;
      _statusMsg = 'Capturing raw bytes from ECU...';
    });

    // Capture 8 samples with progress updates
    final samples = <String>[];
    for (int i = 0; i < 8; i++) {
      try {
        final canHeader = widget.pid.canHeader ?? '';
        if (canHeader.isNotEmpty && canHeader != 'Auto') {
          await widget.obd2.sendRaw('ATSH $canHeader');
          await Future.delayed(const Duration(milliseconds: 50));
        }

        final pidClean = widget.pid.pid.replaceAll('0x', '').replaceAll('0X', '');
        String command;
        if (pidClean.length == 4 && !pidClean.startsWith('01')) {
          command = '22$pidClean';
        } else {
          command = pidClean;
        }

        final raw = await widget.obd2.sendRaw(command);
        if (raw.isNotEmpty && !raw.contains('NO DATA') && !raw.contains('ERROR')) {
          final clean = raw.replaceAll(RegExp(r'[\r\n\s>]'), '').toUpperCase();
          if (clean.length >= 4) {
            samples.add(clean);
            setState(() {
              _sampleCount = samples.length;
              _statusMsg = 'Captured ${samples.length}/8 samples...';
            });
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 700));
    }

    if (samples.length < 2) {
      setState(() {
        _phase = _Phase.idle;
        _statusMsg = 'Not enough samples captured. Is the engine running?';
      });
      return;
    }

    setState(() {
      _samples = samples;
      _phase = _Phase.analyzing;
      _statusMsg = 'Sending samples to Nova AI for analysis...';
    });

    final result = await NovaByteAnalyst.analyzeWithNova(
      rawSamples: samples,
      pid: widget.pid,
      vehicleDescription: widget.vehicleDescription,
      apiKey: '', // handled by Bedrock auth
    );

    setState(() {
      _result = result;
      _phase = result.success ? _Phase.results : _Phase.idle;
      _statusMsg = result.success ? '' : result.errorMessage ?? 'Analysis failed';
    });
  }

  Future<void> _confirmFormula(String validatedBy) async {
    final result = _result!;
    final formula = ValidatedFormula(
      vehicleMake: widget.vehicleMake,
      pid: widget.pid.pid,
      pidName: widget.pid.name,
      formula: result.proposedFormula,
      unit: widget.pid.unit,
      byteExplanation: result.byteExplanation,
      rawSamples: _samples,
      validatedAt: DateTime.now(),
      validatedBy: validatedBy,
    );

    await ValidatedFormulaStore.save(widget.vehicleMake, widget.pid.pid, formula);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Formula saved for ${widget.pid.name}'),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.pop(context, formula);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Nova Byte Analyst'),
        backgroundColor: AppColors.bgCard,
      ),
      body: AppBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPidHeader(),
                const SizedBox(height: 24),
                if (_phase == _Phase.idle) _buildIdlePanel(),
                if (_phase == _Phase.capturing) _buildCapturingPanel(),
                if (_phase == _Phase.analyzing) _buildAnalyzingPanel(),
                if (_phase == _Phase.results && _result != null) _buildResultsPanel(),
                if (_statusMsg.isNotEmpty && _phase == _Phase.idle)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_statusMsg,
                        style: const TextStyle(color: AppColors.warning)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPidHeader() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.blueElectric.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.blueElectric.withOpacity(0.3)),
                ),
                child: Text(
                  widget.pid.pid,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: AppColors.blueElectric,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.pid.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Vehicle: ${widget.vehicleDescription}',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Text('Database formula: ',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              Expanded(
                child: Text(
                  widget.pid.formula.isEmpty ? 'Unknown' : widget.pid.formula,
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace', color: AppColors.warning),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Expected range: ${widget.pid.minValue}–${widget.pid.maxValue} ${widget.pid.unit}',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          if (widget.pid.canHeader != null && widget.pid.canHeader!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'CAN Header: ${widget.pid.canHeader}',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted, fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIdlePanel() {
    return Column(
      children: [
        GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.teal.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.biotech_rounded,
                        color: AppColors.teal, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('How This Works',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                        Text('Nova AI analyzes raw ECU bytes to find the correct formula',
                            style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _step('1', 'Captures 8 raw byte samples from your ECU'),
              _step('2', 'Identifies which bytes are headers vs real data'),
              _step('3', 'Nova AI proposes the correct formula'),
              _step('4', 'You verify the value against your gauge or Torque Pro'),
              _step('5', 'Confirmed formula is saved for your vehicle'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.warning.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.tips_and_updates_rounded,
                        color: AppColors.warning, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'For best results: run the engine and vary conditions during capture (e.g. rev it briefly so temps/pressures change)',
                        style: TextStyle(fontSize: 11, color: AppColors.warning, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: _startCapture,
          child: Container(
            width: double.infinity,
            height: 58,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: AppColors.primaryGradient),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppColors.blueCore.withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.radar_rounded, color: Colors.white, size: 22),
                SizedBox(width: 10),
                Text('START BYTE CAPTURE',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _step(String num, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
              color: AppColors.blueElectric.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(num,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppColors.blueElectric)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary, height: 1.4)),
          ),
        ],
      ),
    );
  }

  Widget _buildCapturingPanel() {
    return GlassCard(
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) => Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.teal
                    .withOpacity(0.08 + 0.07 * _pulseCtrl.value),
                border: Border.all(
                  color: AppColors.teal
                      .withOpacity(0.3 + 0.2 * _pulseCtrl.value),
                  width: 1.5,
                ),
              ),
              child: const Icon(Icons.radar_rounded,
                  color: AppColors.teal, size: 36),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _statusMsg,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          // Sample dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(8, (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 10, height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _sampleCount
                    ? AppColors.teal
                    : AppColors.textMuted.withOpacity(0.3),
              ),
            )),
          ),
          if (_samples.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.bgCard2,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Latest: ${_samples.last}',
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppColors.blueElectric),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAnalyzingPanel() {
    return GlassCard(
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) => Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.violetLight
                    .withOpacity(0.08 + 0.07 * _pulseCtrl.value),
                border: Border.all(
                  color: AppColors.violetLight
                      .withOpacity(0.3 + 0.2 * _pulseCtrl.value),
                ),
              ),
              child: const Icon(Icons.psychology_rounded,
                  color: AppColors.violetLight, size: 36),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Nova AI is analyzing your byte samples...',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text('Identifying data bytes vs header bytes',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildResultsPanel() {
    final result = _result!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Formula verdict
        GlassCard(
          borderColor: result.databaseFormulaCorrect
              ? AppColors.success.withOpacity(0.4)
              : AppColors.warning.withOpacity(0.4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    result.databaseFormulaCorrect
                        ? Icons.check_circle_rounded
                        : Icons.warning_rounded,
                    color: result.databaseFormulaCorrect
                        ? AppColors.success
                        : AppColors.warning,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      result.databaseFormulaCorrect
                          ? 'Database formula appears correct'
                          : 'Database formula may be incorrect',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: result.databaseFormulaCorrect
                            ? AppColors.success
                            : AppColors.warning,
                      ),
                    ),
                  ),
                  _confidenceBadge(result.confidence),
                ],
              ),
              if (result.databaseFormulaIssue != null) ...[
                const SizedBox(height: 8),
                Text(
                  result.databaseFormulaIssue!,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.warning, height: 1.4),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Byte map
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel('Byte Analysis'),
              Text(
                result.byteExplanation,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary, height: 1.5),
              ),
              const SizedBox(height: 12),
              _ByteMapWidget(
                samples: _samples,
                staticBytes: result.staticBytes,
                dataBytes: result.dataBytes,
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Proposed formula
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel('Nova\'s Proposed Formula'),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.bgCard2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.blueElectric.withOpacity(0.3)),
                ),
                child: Text(
                  result.proposedFormula,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.blueElectric,
                  ),
                ),
              ),
              if (result.sampleDecodedValues.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Decoded sample values:',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8, runSpacing: 6,
                  children: result.sampleDecodedValues.map((v) => Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.teal.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.teal.withOpacity(0.3)),
                    ),
                    child: Text(
                      '${v.toStringAsFixed(1)} ${widget.pid.unit}',
                      style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: AppColors.teal,
                          fontWeight: FontWeight.w600),
                    ),
                  )).toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      result.expectedRangeMatch
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 14,
                      color: result.expectedRangeMatch
                          ? AppColors.success
                          : AppColors.danger,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      result.expectedRangeMatch
                          ? 'Values are within expected range'
                          : 'Values may be outside expected range — verify manually',
                      style: TextStyle(
                        fontSize: 11,
                        color: result.expectedRangeMatch
                            ? AppColors.success
                            : AppColors.danger,
                      ),
                    ),
                  ],
                ),
              ],
              if (result.notes != null) ...[
                const SizedBox(height: 10),
                Text('Note: ${result.notes}',
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                        fontStyle: FontStyle.italic)),
              ],
            ],
          ),
        ),

        const SizedBox(height: 20),

        // Confirm buttons
        const Text('Does this value look correct on your vehicle?',
            style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ConfirmButton(
                label: 'Matches Torque Pro',
                icon: Icons.smartphone_rounded,
                color: AppColors.success,
                onTap: () => _confirmFormula('Torque Pro'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ConfirmButton(
                label: 'Matches gauge',
                icon: Icons.speed_rounded,
                color: AppColors.teal,
                onTap: () => _confirmFormula('vehicle gauge'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: _startCapture,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.bgCard.withOpacity(0.6),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.refresh_rounded,
                    color: AppColors.textSecondary, size: 16),
                SizedBox(width: 8),
                Text('Recapture samples',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _confidenceBadge(String confidence) {
    final color = confidence == 'high'
        ? AppColors.success
        : confidence == 'medium'
        ? AppColors.warning
        : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        confidence.toUpperCase(),
        style: TextStyle(
            fontSize: 9, fontWeight: FontWeight.w800, color: color),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  BYTE MAP WIDGET
//  Visual table showing each sample's bytes
//  color-coded: gray = static header, blue = data
// ─────────────────────────────────────────────
class _ByteMapWidget extends StatelessWidget {
  final List<String> samples;
  final List<int> staticBytes;
  final List<int> dataBytes;

  const _ByteMapWidget({
    required this.samples,
    required this.staticBytes,
    required this.dataBytes,
  });

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) return const SizedBox();

    // Parse all samples into byte arrays
    final parsedSamples = samples.map((hex) {
      final bytes = <int>[];
      for (int i = 0; i + 1 < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      return bytes;
    }).toList();

    final maxLen = parsedSamples.map((b) => b.length).reduce((a, b) => a > b ? a : b);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              const SizedBox(width: 60),
              ...List.generate(maxLen, (i) {
                final pos = i + 1;
                final isData = dataBytes.contains(pos);
                final isStatic = staticBytes.contains(pos);
                return Container(
                  width: 46,
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: isData
                        ? AppColors.blueElectric.withOpacity(0.15)
                        : isStatic
                        ? AppColors.textMuted.withOpacity(0.08)
                        : AppColors.bgCard2,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    children: [
                      Text('B$pos',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: isData
                                  ? AppColors.blueElectric
                                  : AppColors.textMuted)),
                      Text(isData ? 'DATA' : isStatic ? 'HDR' : '?',
                          style: TextStyle(
                              fontSize: 7,
                              color: isData
                                  ? AppColors.blueElectric
                                  : AppColors.textMuted)),
                    ],
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 4),
          // Sample rows
          ...parsedSamples.asMap().entries.map((entry) {
            final i = entry.key;
            final bytes = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 60,
                    child: Text('S${i + 1}',
                        style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.textMuted,
                            fontFamily: 'monospace')),
                  ),
                  ...List.generate(maxLen, (j) {
                    final pos = j + 1;
                    final isData = dataBytes.contains(pos);
                    final val = j < bytes.length ? bytes[j] : null;
                    return Container(
                      width: 46,
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      decoration: BoxDecoration(
                        color: isData
                            ? AppColors.blueElectric.withOpacity(0.08)
                            : AppColors.bgCard2.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(6),
                        border: isData
                            ? Border.all(
                            color: AppColors.blueElectric.withOpacity(0.25))
                            : null,
                      ),
                      child: Text(
                        val != null
                            ? val.toString().padLeft(3)
                            : '---',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: isData ? FontWeight.w700 : FontWeight.w400,
                          color: isData
                              ? AppColors.blueElectric
                              : AppColors.textMuted,
                        ),
                      ),
                    );
                  }),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _ConfirmButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ConfirmButton({
    required this.label, required this.icon,
    required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

enum _Phase { idle, capturing, analyzing, results }