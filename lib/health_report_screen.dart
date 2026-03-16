import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'main.dart';
import 'config.dart';
import 'vehicle_profile_screen.dart';
import 'nova_chat_screen.dart';

// ─────────────────────────────────────────
//  HEALTH REPORT MODEL
// ─────────────────────────────────────────
class HealthReport {
  final int scaryRating;       // 0-10 (0 = perfect, 10 = call a tow truck)
  final String headline;       // One-liner summary
  final String summary;        // 2-3 sentence overall assessment
  final List<HealthItem> items; // Individual findings
  final String novaAdvice;     // What Nova recommends doing next
  final DateTime generatedAt;

  HealthReport({
    required this.scaryRating,
    required this.headline,
    required this.summary,
    required this.items,
    required this.novaAdvice,
  }) : generatedAt = DateTime.now();

  // 0-3 = green, 4-6 = yellow, 7-8 = orange, 9-10 = red
  Color get ratingColor {
    if (scaryRating <= 3) return AppColors.success;
    if (scaryRating <= 6) return AppColors.warning;
    if (scaryRating <= 8) return const Color(0xFFFF6B35);
    return AppColors.danger;
  }

  String get ratingEmoji {
    if (scaryRating <= 2) return '😊';
    if (scaryRating <= 4) return '🙂';
    if (scaryRating <= 6) return '😐';
    if (scaryRating <= 8) return '😟';
    return '😱';
  }

  String get ratingLabel {
    if (scaryRating <= 2) return 'All Good';
    if (scaryRating <= 4) return 'Minor Issues';
    if (scaryRating <= 6) return 'Needs Attention';
    if (scaryRating <= 8) return 'Concerning';
    return 'Critical';
  }
}

class HealthItem {
  final String title;
  final String detail;
  final int severity;    // 0 = good, 1 = info, 2 = warning, 3 = critical
  final String emoji;
  final String? estimatedCost;

  HealthItem({
    required this.title,
    required this.detail,
    required this.severity,
    required this.emoji,
    this.estimatedCost,
  });

  Color get color {
    switch (severity) {
      case 0: return AppColors.success;
      case 1: return AppColors.blueElectric;
      case 2: return AppColors.warning;
      case 3: return AppColors.danger;
      default: return AppColors.textSecondary;
    }
  }

  IconData get icon {
    switch (severity) {
      case 0: return Icons.check_circle_rounded;
      case 1: return Icons.info_rounded;
      case 2: return Icons.warning_rounded;
      case 3: return Icons.error_rounded;
      default: return Icons.circle;
    }
  }
}

// ─────────────────────────────────────────
//  NOVA HEALTH REPORT SERVICE
// ─────────────────────────────────────────
class HealthReportService {
  static final _signer = AwsSigV4Signer(
    accessKey: AppConfig.awsAccessKey,
    secretKey: AppConfig.awsSecretKey,
    region: AppConfig.awsRegion,
    service: 'bedrock',
  );

  static const String _model = 'amazon.nova-lite-v1:0';

  static Future<HealthReport> generateReport(VehicleProfile profile) async {
    final prompt = '''
You are Nova, an expert AI mechanic. Analyze this vehicle data and generate a health report.

Vehicle: ${profile.displayName}
Engine: ${profile.engineDisplay}
Transmission: ${profile.transmission}
VIN: ${profile.vin}
Engine was: ${profile.engineRunning ? 'RUNNING' : 'OFF'} during scan

Live sensor readings:
${profile.rawObd.entries.map((e) => '- ${e.key}: ${e.value}').join('\n')}

Fault codes: ${(profile.rawObd['dtcs'] ?? '').isEmpty ? 'None' : profile.rawObd['dtcs']}

Known issues with ${profile.year} ${profile.make} ${profile.model} ${profile.engine}:
- Consider common problems for this specific vehicle when generating your report

Generate a JSON health report. The "scary_rating" is 0-10 where:
0-2 = perfect condition
3-4 = minor maintenance needed  
5-6 = some issues to address
7-8 = concerning issues
9-10 = critical, may not be safe to drive

Respond ONLY with this JSON, no other text:
{
  "scary_rating": 3,
  "headline": "Your truck is in solid shape with a few things to watch",
  "summary": "2-3 sentences about overall vehicle health based on the data",
  "items": [
    {
      "title": "Engine RPM",
      "detail": "Idle RPM of 686 is normal and healthy for this engine",
      "severity": 0,
      "emoji": "✅",
      "estimated_cost": null
    },
    {
      "title": "Coolant Temperature", 
      "detail": "77°C is slightly below normal operating temp — engine may still be warming up",
      "severity": 1,
      "emoji": "🌡️",
      "estimated_cost": null
    },
    {
      "title": "Battery Voltage",
      "detail": "10.9V is low — a healthy charging system should read 13.5-14.5V while running. Could indicate alternator or battery issue.",
      "severity": 2,
      "emoji": "⚡",
      "estimated_cost": "\$150-\$400"
    }
  ],
  "nova_advice": "What Nova recommends the owner do next, 1-2 sentences, friendly tone"
}

Be specific to THIS vehicle's actual data. Reference the real numbers. If there are fault codes explain each one.
The 6.0L Ford Power Stroke diesel has known issues — mention relevant ones if applicable.
''';

    try {
      final url = Uri.parse(
        'https://bedrock-runtime.${AppConfig.awsRegion}.amazonaws.com'
            '/model/$_model/invoke',
      );

      final body = jsonEncode({
        'messages': [
          {
            'role': 'user',
            'content': [
              {'text': prompt}
            ],
          }
        ],
        'inferenceConfig': {
          'maxTokens': 2048,
          'temperature': 0.3,
        },
      });

      final headers = _signer.sign(method: 'POST', uri: url, body: body);
      final response = await http.post(url, headers: headers, body: body);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = data['output']['message']['content'][0]['text'] ?? '';
        return _parseReport(text, profile);
      }
      throw Exception('Nova error ${response.statusCode}');
    } catch (e) {
      return _fallbackReport(profile);
    }
  }

  static HealthReport _parseReport(String text, VehicleProfile profile) {
    try {
      final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (match == null) return _fallbackReport(profile);

      final json = jsonDecode(match.group(0)!);

      final itemsList = (json['items'] as List? ?? []).map((item) {
        return HealthItem(
          title: item['title']?.toString() ?? 'Unknown',
          detail: item['detail']?.toString() ?? '',
          severity: (item['severity'] as num?)?.toInt() ?? 1,
          emoji: item['emoji']?.toString() ?? '•',
          estimatedCost: item['estimated_cost']?.toString(),
        );
      }).toList();

      return HealthReport(
        scaryRating: (json['scary_rating'] as num?)?.toInt() ?? 5,
        headline: json['headline']?.toString() ?? 'Health report generated',
        summary: json['summary']?.toString() ?? '',
        items: itemsList,
        novaAdvice: json['nova_advice']?.toString() ?? '',
      );
    } catch (e) {
      return _fallbackReport(profile);
    }
  }

  static HealthReport _fallbackReport(VehicleProfile profile) {
    return HealthReport(
      scaryRating: 5,
      headline: 'Partial data available',
      summary:
      'Nova could not fully analyze your vehicle right now. Check your connection and try again.',
      items: [
        HealthItem(
          title: 'Analysis Incomplete',
          detail: 'Could not connect to Nova AI for full analysis.',
          severity: 1,
          emoji: '⚠️',
        ),
      ],
      novaAdvice: 'Try again with a stable internet connection.',
    );
  }
}

// ─────────────────────────────────────────
//  HEALTH REPORT SCREEN
// ─────────────────────────────────────────
class HealthReportScreen extends StatefulWidget {
  final VehicleProfile vehicleProfile;

  const HealthReportScreen({super.key, required this.vehicleProfile});

  @override
  State<HealthReportScreen> createState() => _HealthReportScreenState();
}

class _HealthReportScreenState extends State<HealthReportScreen>
    with TickerProviderStateMixin {
  HealthReport? _report;
  bool _loading = true;
  String? _error;

  late AnimationController _ratingCtrl;
  late Animation<double> _ratingAnim;
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();

    _ratingCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _ratingAnim = CurvedAnimation(
      parent: _ratingCtrl,
      curve: Curves.elasticOut,
    );

    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

    _generateReport();
  }

  @override
  void dispose() {
    _ratingCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _generateReport() async {
    setState(() { _loading = true; _error = null; });
    try {
      final report = await HealthReportService.generateReport(
          widget.vehicleProfile);
      setState(() {
        _report = report;
        _loading = false;
      });
      _ratingCtrl.forward();
      _fadeCtrl.forward();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: _loading
              ? _buildLoading()
              : _error != null
              ? _buildError()
              : _buildReport(),
        ),
      ),
    );
  }

  // ── LOADING ───────────────────────────
  Widget _buildLoading() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100, height: 100,
              decoration: BoxDecoration(
                gradient: RadialGradient(colors: [
                  AppColors.blueCore.withOpacity(0.3),
                  Colors.transparent,
                ]),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.psychology_rounded,
                  color: AppColors.blueElectric, size: 48),
            ),
            const SizedBox(height: 28),
            const Text('Nova is analyzing your vehicle...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text(
                'Checking sensors, fault codes, and known issues\nfor your specific vehicle',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    height: 1.5)),
            const SizedBox(height: 32),
            const LinearProgressIndicator(
              backgroundColor: Colors.white12,
              valueColor:
              AlwaysStoppedAnimation<Color>(AppColors.blueElectric),
            ),
          ],
        ),
      ),
    );
  }

  // ── ERROR ─────────────────────────────
  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: AppColors.danger, size: 48),
            const SizedBox(height: 16),
            const Text('Report Failed',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 24),
            PrimaryButton(
                label: 'Try Again',
                icon: Icons.refresh_rounded,
                onPressed: _generateReport),
          ],
        ),
      ),
    );
  }

  // ── REPORT ────────────────────────────
  Widget _buildReport() {
    final r = _report!;
    return FadeTransition(
      opacity: _fadeAnim,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
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
                      const Text('Health Report',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800)),
                      Text(widget.vehicleProfile.displayName,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                const NovaBadge(),
              ],
            ),

            const SizedBox(height: 24),

            // ── SCARY RATING CARD ────────
            GlassCard(
              child: Column(
                children: [
                  const Text('SCARY RATING',
                      style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textMuted,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),

                  // Animated rating dial
                  AnimatedBuilder(
                    animation: _ratingAnim,
                    builder: (_, __) {
                      return _buildRatingDial(r, _ratingAnim.value);
                    },
                  ),

                  const SizedBox(height: 20),

                  // Headline
                  Text(r.headline,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.3)),

                  const SizedBox(height: 12),

                  // Summary
                  Text(r.summary,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                          height: 1.5)),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── NOVA ADVICE ──────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.blueCore.withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: AppColors.blueCore.withOpacity(0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          colors: AppColors.primaryGradient),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.psychology_rounded,
                        color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Nova recommends',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.blueBright,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5)),
                        const SizedBox(height: 4),
                        Text(r.novaAdvice,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textPrimary,
                                height: 1.4)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),
            const SectionLabel('Detailed Findings'),

            // ── HEALTH ITEMS ─────────────
            ...r.items.map((item) => _buildHealthItem(item)),

            const SizedBox(height: 20),

            // ── SEVERITY LEGEND ──────────
            GlassCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SEVERITY KEY',
                      style: TextStyle(
                          fontSize: 9,
                          color: AppColors.textMuted,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _legendItem(AppColors.success, 'Good'),
                      _legendItem(AppColors.blueElectric, 'Info'),
                      _legendItem(AppColors.warning, 'Warning'),
                      _legendItem(AppColors.danger, 'Critical'),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            PrimaryButton(
              label: 'Discuss with Nova AI',
              icon: Icons.chat_bubble_rounded,
              onPressed: () {
                final prompt =
                    'I just got my health report. My ${widget.vehicleProfile.displayName} has a scary rating of ${r.scaryRating}/10. ${r.headline}. Can you walk me through the findings and tell me what I should prioritize?';
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
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Regenerate Report',
              icon: Icons.refresh_rounded,
              onPressed: () {
                _ratingCtrl.reset();
                _fadeCtrl.reset();
                _generateReport();
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // ── RATING DIAL ───────────────────────
  Widget _buildRatingDial(HealthReport r, double animValue) {
    final displayRating = (r.scaryRating * animValue).round();
    final sweepAngle = (r.scaryRating / 10) * pi * 1.5 * animValue;

    return SizedBox(
      width: 180, height: 180,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background arc
          CustomPaint(
            size: const Size(180, 180),
            painter: _ArcPainter(
              sweepAngle: pi * 1.5,
              color: Colors.white.withOpacity(0.06),
              strokeWidth: 14,
            ),
          ),
          // Colored arc
          CustomPaint(
            size: const Size(180, 180),
            painter: _ArcPainter(
              sweepAngle: sweepAngle,
              color: r.ratingColor,
              strokeWidth: 14,
              withGlow: true,
            ),
          ),
          // Center content
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(r.ratingEmoji,
                  style: const TextStyle(fontSize: 32)),
              const SizedBox(height: 4),
              Text('$displayRating',
                  style: TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      color: r.ratingColor,
                      fontFamily: 'monospace')),
              const Text('/ 10',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted)),
              Text(r.ratingLabel,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: r.ratingColor,
                      letterSpacing: 0.5)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHealthItem(HealthItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: item.color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: item.color.withOpacity(0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.emoji, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(item.title,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700)),
                    ),
                    Icon(item.icon, color: item.color, size: 16),
                  ],
                ),
                const SizedBox(height: 4),
                Text(item.detail,
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        height: 1.4)),
                if (item.estimatedCost != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: AppColors.warning.withOpacity(0.3)),
                    ),
                    child: Text('Est. ${item.estimatedCost}',
                        style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.warning,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Expanded(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  ARC PAINTER for rating dial
// ─────────────────────────────────────────
class _ArcPainter extends CustomPainter {
  final double sweepAngle;
  final Color color;
  final double strokeWidth;
  final bool withGlow;

  _ArcPainter({
    required this.sweepAngle,
    required this.color,
    required this.strokeWidth,
    this.withGlow = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.width / 2 - strokeWidth / 2,
    );

    if (withGlow) {
      final glowPaint = Paint()
        ..color = color.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 8
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawArc(rect, pi * 0.75, sweepAngle, false, glowPaint);
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, pi * 0.75, sweepAngle, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.sweepAngle != sweepAngle || old.color != color;
}