import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'main.dart';
import 'config.dart';
import 'vehicle_profile_screen.dart';
// for OBD2Service
import 'location_service.dart';

// ─────────────────────────────────────────
//  AI OVERVIEW SCREEN
//
//  On open:
//    1. Reads a fresh snapshot of live OBD data
//    2. Sends it all to Nova with a structured prompt
//    3. Displays the analysis (overview, issues, recommendations)
//    4. Chat input at the bottom — typing transitions to conversation
//
//  AI is only invoked when:
//    a) Screen opens (auto analysis)
//    b) User sends a message (conversation)
//  Never called in the background. Never called during scan.
// ─────────────────────────────────────────

class AiOverviewScreen extends StatefulWidget {
  final VehicleProfile vehicleProfile;
  final OBD2Service obdService;

  const AiOverviewScreen({
    super.key,
    required this.vehicleProfile,
    required this.obdService,
  });

  @override
  State<AiOverviewScreen> createState() => _AiOverviewScreenState();
}

class _AiOverviewScreenState extends State<AiOverviewScreen>
    with SingleTickerProviderStateMixin {
  // ── State ──────────────────────────────────────────────────────────
  final List<_ChatMessage> _messages = [];
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  bool _loadingAnalysis = true;
  bool _sendingMessage = false;
  bool _inChatMode = false;       // true once user sends first message
  Map<String, String> _liveSnapshot = {};
  LocationInfo? _location;         // city/state/country for AI context

  // ── Init ───────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _fetchLocationThenAnalyse();
  }

  Future<void> _fetchLocationThenAnalyse() async {
    // Fetch location in parallel with analysis — don't block if slow
    LocationService.getLocation().then((loc) {
      if (mounted) setState(() => _location = loc);
    });
    _runInitialAnalysis();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // ── Live data snapshot ─────────────────────────────────────────────
  Future<Map<String, String>> _readLiveSnapshot() async {
    final snap = <String, String>{};
    // Start from whatever the profile already has (last known values)
    snap.addAll(widget.vehicleProfile.rawObd);

    // Try to refresh a few key readings from the live connection
    try {
      final rpm = await widget.obdService.readRpm();
      snap['rpm'] = '$rpm rpm';
    } catch (_) {}
    try {
      final tempC = await widget.obdService.readCoolantTemp();
      snap['coolant'] = '${(tempC * 9 / 5 + 32).toStringAsFixed(0)}°F';
    } catch (_) {}
    try {
      final bat = await widget.obdService.readBattery();
      snap['battery'] = '${bat.toStringAsFixed(1)}V';
    } catch (_) {}
    try {
      final spd = await widget.obdService.readSpeed();
      snap['speed'] = '$spd mph';
    } catch (_) {}

    return snap;
  }

  // ── Initial analysis ───────────────────────────────────────────────
  Future<void> _runInitialAnalysis() async {
    setState(() => _loadingAnalysis = true);

    // Read fresh live data
    _liveSnapshot = await _readLiveSnapshot();

    final p = widget.vehicleProfile;
    final dtcs = p.rawObd['dtcs'] ?? '';
    final dtcList = dtcs.isNotEmpty ? dtcs : 'None detected';

    final dataLines = _liveSnapshot.entries
        .where((e) => e.key != 'dtcs' && e.key != 'dtc_count')
        .map((e) => '  • ${e.key}: ${e.value}')
        .join('\n');

    // Location context — wait up to 3s for it if not yet available
    if (_location == null) {
      for (int i = 0; i < 6; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_location != null) break;
      }
    }
    final locCtx = _location != null
        ? 'LOCATION: ${_location!.aiContextString}\nDRIVER SEAT: ${_location!.driverSideDescription}\nLABOR RATES: ${_location!.laborRateHint}'
        : 'LOCATION: Unknown (assume USA, driver on left)';

    final prompt = '''
You are Nova, an expert AI mechanic. Analyze this vehicle's live OBD2 data and give a clear health overview.

VEHICLE: ${p.displayName}
ENGINE: ${p.engineDisplay}
TRANSMISSION: ${p.transmission}
VIN: ${p.vin}
ENGINE WAS: ${p.engineRunning ? 'RUNNING during scan' : 'OFF during scan'}
$locCtx

LIVE DATA SNAPSHOT:
$dataLines

FAULT CODES: $dtcList

Respond with a structured analysis in this exact JSON format:
{
  "health_score": <0-100 integer>,
  "status": "<one of: Excellent | Good | Fair | Needs Attention | Critical>",
  "summary": "<2-3 sentence plain-English overview of the vehicle's condition>",
  "issues": [
    {"severity": "<critical|warning|info>", "title": "<short title>", "detail": "<1-2 sentence explanation>"}
  ],
  "recommendations": [
    "<actionable recommendation as a string>"
  ],
  "safe_to_drive": <true|false>
}

If there are no issues, return an empty issues array.
Respond ONLY with the JSON object. No markdown, no explanation outside the JSON.
''';

    try {
      final response = await _NovaService.sendMessage(
        userMessage: prompt,
        history: [],
        systemPrompt: _NovaService.mechanicSystemPrompt,
        isAnalysis: true,
      );

      // Parse structured response
      final jsonStr = _extractJson(response);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      setState(() {
        _messages.add(_ChatMessage(
          content: _AnalysisResult.fromJson(json),
          isUser: false,
          isAnalysis: true,
        ));
        _loadingAnalysis = false;
      });
    } catch (e) {
      setState(() {
        _messages.add(_ChatMessage(
          content: 'I had trouble analyzing your vehicle data. '
              'You can still ask me questions below.',
          isUser: false,
          isAnalysis: false,
          isError: true,
        ));
        _loadingAnalysis = false;
      });
    }

    _scrollToBottom();
  }

  // ── User sends a message ───────────────────────────────────────────
  Future<void> _sendMessage() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sendingMessage) return;

    _inputCtrl.clear();
    setState(() {
      _inChatMode = true;
      _sendingMessage = true;
      _messages.add(_ChatMessage(content: text, isUser: true, isAnalysis: false));
    });
    _scrollToBottom();

    try {
      // Build history from previous text chat messages only
      final history = _messages
          .where((m) => !m.isAnalysis)
          .map((m) => _ChatMsg(text: m.content is String ? m.content as String : '', isUser: m.isUser))
          .toList();

      // Inject vehicle context into first user message
      final contextualMessage = _messages.where((m) => !m.isAnalysis).length <= 1
          ? '${widget.vehicleProfile.displayName} | ${widget.vehicleProfile.engineDisplay}\n'
          'Live data: ${_liveSnapshot.entries.take(6).map((e) => '${e.key}=${e.value}').join(', ')}\n\n'
          'User question: $text'
          : text;

      final reply = await _NovaService.sendMessage(
        userMessage: contextualMessage,
        history: history.length > 1 ? history.sublist(0, history.length - 1) : [],
        systemPrompt: _NovaService.mechanicSystemPromptWithVehicle(
          widget.vehicleProfile,
          _liveSnapshot,
          location: _location,
        ),
        isAnalysis: false,
      );

      setState(() {
        _messages.add(_ChatMessage(content: reply, isUser: false, isAnalysis: false));
        _sendingMessage = false;
      });
    } catch (e) {
      setState(() {
        _messages.add(_ChatMessage(
          content: 'Connection error. Check your internet and try again.',
          isUser: false,
          isAnalysis: false,
          isError: true,
        ));
        _sendingMessage = false;
      });
    }

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _extractJson(String text) {
    final start = text.indexOf('{');
    final end   = text.lastIndexOf('}');
    if (start >= 0 && end > start) return text.substring(start, end + 1);
    return text;
  }

  // ── Build ──────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _loadingAnalysis ? _buildLoadingState() : _buildMessageList(),
            ),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final p = widget.vehicleProfile;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.bgCard.withOpacity(0.8),
        border: const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: AppColors.bgCard2,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: AppColors.textSecondary, size: 16),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.blueElectric, AppColors.violet],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.auto_awesome_rounded,
                color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('AI Overview',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary)),
                Text(
                  // If make/model resolved, show them. Otherwise show VIN.
                  (p.make != 'Unknown' && p.model != 'Unknown')
                      ? p.displayName
                      : (p.vin != 'UNKNOWN' ? 'VIN: ${p.vin}' : 'Vehicle connected'),
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Live indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.success.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.success.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.success,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                const Text('LIVE',
                    style: TextStyle(
                        fontSize: 9,
                        color: AppColors.success,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.blueElectric, AppColors.violet],
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.auto_awesome_rounded,
                color: Colors.white, size: 30),
          ),
          const SizedBox(height: 20),
          const Text('Reading your vehicle...',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          const Text('Nova is analyzing live data',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
          const SizedBox(height: 24),
          SizedBox(
            width: 40,
            child: LinearProgressIndicator(
              backgroundColor: AppColors.border,
              valueColor: const AlwaysStoppedAnimation(AppColors.blueElectric),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _messages.length + (_sendingMessage ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i == _messages.length) return _buildTypingIndicator();
        final msg = _messages[i];
        if (msg.isAnalysis && msg.content is _AnalysisResult) {
          return _AnalysisCard(result: msg.content as _AnalysisResult);
        }
        return _buildChatBubble(msg);
      },
    );
  }

  Widget _buildChatBubble(_ChatMessage msg) {
    final isUser = msg.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? AppColors.blueElectric.withOpacity(0.2)
              : msg.isError
              ? AppColors.danger.withOpacity(0.1)
              : AppColors.bgCard,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: Border.all(
            color: isUser
                ? AppColors.blueElectric.withOpacity(0.3)
                : msg.isError
                ? AppColors.danger.withOpacity(0.3)
                : AppColors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 18, height: 18,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.blueElectric, AppColors.violet],
                      ),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Icon(Icons.auto_awesome_rounded,
                        color: Colors.white, size: 10),
                  ),
                  const SizedBox(width: 6),
                  const Text('Nova',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppColors.blueElectric)),
                ],
              ),
              const SizedBox(height: 6),
            ],
            Text(
              msg.content is String ? msg.content as String : '',
              style: TextStyle(
                fontSize: 14,
                color: isUser ? AppColors.textPrimary : AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
          ),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) => _Dot(delay: i * 200)),
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      decoration: const BoxDecoration(
        color: AppColors.bgCard,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              focusNode: _inputFocus,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 14),
              maxLines: 4,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              onTap: () {
                // Smooth transition into chat mode when input is focused
                if (!_inChatMode && _messages.isNotEmpty) {
                  setState(() => _inChatMode = true);
                  Future.delayed(const Duration(milliseconds: 300),
                      _scrollToBottom);
                }
              },
              onSubmitted: (_) => _sendMessage(),
              decoration: InputDecoration(
                hintText: _inChatMode
                    ? 'Ask Nova anything...'
                    : 'Ask a follow-up question...',
                hintStyle: const TextStyle(
                    color: AppColors.textMuted, fontSize: 14),
                filled: true,
                fillColor: AppColors.bgCard2,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(
                      color: AppColors.blueElectric, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _sendMessage,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: _sendingMessage
                    ? null
                    : const LinearGradient(
                  colors: [AppColors.blueElectric, AppColors.violet],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                color: _sendingMessage ? AppColors.bgCard2 : null,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                _sendingMessage
                    ? Icons.hourglass_top_rounded
                    : Icons.send_rounded,
                color: _sendingMessage
                    ? AppColors.textMuted
                    : Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  ANALYSIS RESULT CARD
// ─────────────────────────────────────────
class _AnalysisResult {
  final int healthScore;
  final String status;
  final String summary;
  final List<Map<String, String>> issues;
  final List<String> recommendations;
  final bool safeToDrive;

  _AnalysisResult({
    required this.healthScore,
    required this.status,
    required this.summary,
    required this.issues,
    required this.recommendations,
    required this.safeToDrive,
  });

  factory _AnalysisResult.fromJson(Map<String, dynamic> j) {
    return _AnalysisResult(
      healthScore: (j['health_score'] as num?)?.toInt() ?? 50,
      status: j['status']?.toString() ?? 'Unknown',
      summary: j['summary']?.toString() ?? '',
      issues: (j['issues'] as List<dynamic>? ?? [])
          .map((i) => {
        'severity': i['severity']?.toString() ?? 'info',
        'title': i['title']?.toString() ?? '',
        'detail': i['detail']?.toString() ?? '',
      })
          .toList(),
      recommendations: (j['recommendations'] as List<dynamic>? ?? [])
          .map((r) => r.toString())
          .toList(),
      safeToDrive: j['safe_to_drive'] as bool? ?? true,
    );
  }

  Color get scoreColor {
    if (healthScore >= 80) return AppColors.success;
    if (healthScore >= 60) return AppColors.warning;
    return AppColors.danger;
  }
}

class _AnalysisCard extends StatelessWidget {
  final _AnalysisResult result;
  const _AnalysisCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Score + status ─────────────────────────────────────────
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: result.scoreColor.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Big score circle
                  Container(
                    width: 72, height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: result.scoreColor.withOpacity(0.1),
                      border: Border.all(
                          color: result.scoreColor.withOpacity(0.4), width: 3),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('${result.healthScore}',
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                                color: result.scoreColor)),
                        Text('/ 100',
                            style: TextStyle(
                                fontSize: 9,
                                color: result.scoreColor.withOpacity(0.7))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              result.safeToDrive
                                  ? Icons.check_circle_rounded
                                  : Icons.error_rounded,
                              color: result.safeToDrive
                                  ? AppColors.success
                                  : AppColors.danger,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              result.safeToDrive ? 'Safe to drive' : 'Do not drive',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: result.safeToDrive
                                      ? AppColors.success
                                      : AppColors.danger),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(result.status,
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: result.scoreColor)),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              width: 18, height: 18,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [AppColors.blueElectric, AppColors.violet],
                                ),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Icon(Icons.auto_awesome_rounded,
                                  color: Colors.white, size: 10),
                            ),
                            const SizedBox(width: 5),
                            const Text('Nova Analysis',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.textMuted,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(result.summary,
                  style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      height: 1.5)),
            ],
          ),
        ),

        // ── Issues ────────────────────────────────────────────────
        if (result.issues.isNotEmpty) ...[
          const _SectionLabel('Issues Found'),
          const SizedBox(height: 8),
          ...result.issues.map((issue) {
            final sev = issue['severity'] ?? 'info';
            final color = sev == 'critical'
                ? AppColors.danger
                : sev == 'warning'
                ? AppColors.warning
                : AppColors.blueElectric;
            final icon = sev == 'critical'
                ? Icons.error_rounded
                : sev == 'warning'
                ? Icons.warning_rounded
                : Icons.info_rounded;
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: color.withOpacity(0.07),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withOpacity(0.25)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(issue['title'] ?? '',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: color)),
                        const SizedBox(height: 4),
                        Text(issue['detail'] ?? '',
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                                height: 1.4)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 6),
        ],

        // ── Recommendations ───────────────────────────────────────
        if (result.recommendations.isNotEmpty) ...[
          const _SectionLabel('Recommendations'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: result.recommendations.asMap().entries.map((entry) {
                return Padding(
                  padding: EdgeInsets.only(
                      bottom: entry.key < result.recommendations.length - 1 ? 10 : 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 20, height: 20,
                        decoration: BoxDecoration(
                          color: AppColors.blueElectric.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text('${entry.key + 1}',
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.blueElectric)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(entry.value,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                                height: 1.4)),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // ── Chat prompt ───────────────────────────────────────────
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.blueElectric.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.blueElectric.withOpacity(0.2)),
          ),
          child: const Row(
            children: [
              Icon(Icons.chat_bubble_outline_rounded,
                  color: AppColors.blueElectric, size: 16),
              SizedBox(width: 8),
              Text('Type a question below to dig deeper',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.blueElectric,
                      fontStyle: FontStyle.italic)),
            ],
          ),
        ),

        const SizedBox(height: 20),
      ],
    );
  }
}

// ─────────────────────────────────────────
//  CHAT MESSAGE MODEL
// ─────────────────────────────────────────
class _ChatMessage {
  final dynamic content; // String or _AnalysisResult
  final bool isUser;
  final bool isAnalysis;
  final bool isError;

  _ChatMessage({
    required this.content,
    required this.isUser,
    required this.isAnalysis,
    this.isError = false,
  });
}

class _ChatMsg {
  final String text;
  final bool isUser;
  _ChatMsg({required this.text, required this.isUser});
}

// ─────────────────────────────────────────
//  NOVA SERVICE (lean - only chat/analysis)
// ─────────────────────────────────────────
class _NovaService {
  static final _signer = AwsSigV4Signer(
    accessKey: AppConfig.awsAccessKey,
    secretKey: AppConfig.awsSecretKey,
    region: AppConfig.awsRegion,
    service: 'bedrock',
  );
  static const String _model = 'amazon.nova-lite-v1:0';

  static const String mechanicSystemPrompt = '''
You are Nova, an expert AI mechanic built into the AI Mechanic app.
- Friendly, clear, direct — like a knowledgeable friend who's a mechanic
- Explain things in plain English, not jargon
- Be honest: if something is serious, say so
- Give direct answers first, then explain
- Never tell someone to ignore a safety issue
''';

  static String mechanicSystemPromptWithVehicle(
      VehicleProfile p, Map<String, String> liveData,
      {LocationInfo? location}) {
    // Separate standard OBD PIDs from manufacturer-specific PIDs
    final stdPids = liveData.entries
        .where((e) => !e.key.startsWith('ps_') && !e.key.startsWith('to_'))
        .take(8)
        .map((e) => '${e.key}=${e.value}')
        .join(', ');

    // Powerstroke Mode 22 PIDs (ps_ prefix)
    final psPids = liveData.entries
        .where((e) => e.key.startsWith('ps_'))
        .map((e) {
      final label = e.key
          .replaceFirst('ps_', '')
          .replaceAll('_', ' ')
          .toUpperCase();
      return '$label: ${e.value}';
    })
        .join(', ');

    final psSection = psPids.isNotEmpty
        ? '\nPowerstroke Mode 22 extended PIDs: $psPids'
        '\n(Ford Powerstroke diesel — key values: '
        'ICP=injector control pressure (idle ~500psi, WOT ~3800psi); '
        'FICM logic/main voltage should be 48V on 6.0L (not 12V); '
        'VGT=variable geometry turbo vane position; '
        'IPR=injection pressure regulator duty cycle; '
        'CHT=cylinder head temp; '
        'EGR cooler inlet/outlet delta >50°C indicates failing cooler (6.0L killer); '
        'DPF soot >80% needs regeneration (6.4L/6.7L); '
        'DEF level/quality critical for emissions compliance (6.7L); '
        'CP4 wear index >50% indicates pump replacement soon (6.4L/6.7L); '
        'Rail pressure in MPa for common rail engines (6.4L/6.7L); '
        'Oil pressure 25-80 psi normal at operating temp)'
        : '';

    // Toyota Mode 21 enhanced PIDs (to_ prefix)
    final toPids = liveData.entries
        .where((e) => e.key.startsWith('to_'))
        .map((e) {
      final label = e.key
          .replaceFirst('to_', '')
          .replaceAll('_', ' ')
          .toUpperCase();
      return '$label: ${e.value}';
    })
        .join(', ');

    final toSection = toPids.isNotEmpty
        ? '\nToyota Mode 21 enhanced PIDs: $toPids'
        '\n(VVTI=variable valve timing cam angle, normal ~0-40° at cruise; '
        'STFT/LTFT=fuel trims, healthy within ±5%; '
        'O2 B1S1/B2S1=upstream wideband sensors; '
        'KNOCK B1/B2=knock retard, should be near 0° healthy engine; '
        'CAT TEMP=catalyst temperature; 4WD=transfer case mode)'
        : '';

    final gmPids = liveData.entries
        .where((e) => e.key.startsWith('gm_'))
        .map((e) {
      final label = e.key.replaceFirst('gm_', '').replaceAll('_', ' ').toUpperCase();
      return '$label: ${e.value}';
    }).join(', ');
    final gmSection = gmPids.isNotEmpty
        ? '\nGM Mode 22 enhanced PIDs: $gmPids'
        '\n(EGR cooler Δ >50°C = failing cooler; DPF soot >80% needs regen; DEF >10% required; '
        'CP4 wear >50% = pump failure risk; VVT cam angles normal 0-40°; knock retard ~0° healthy; '
        'AFM=cylinder deactivation status; oil life = GM Oil Life Monitor)'
        : '';

    final locSection = location != null
        ? '\nUser location: ${location.aiContextString}'
        '\nDriver seat: ${location.driverSideDescription}'
        '\nLocal labor rates: ${location.laborRateHint}'
        '\nAlways use this location when giving directions like "left side" or "passenger side", and when estimating repair costs.'
        : '\nUser location: Unknown — assume USA, driver seat on LEFT side of vehicle.';

    return '''
$mechanicSystemPrompt

Current vehicle: ${p.displayName} | ${p.engineDisplay}
VIN: ${p.vin}
Engine was: ${p.engineRunning ? 'running' : 'off'} during scan
Live data: $stdPids$psSection$toSection
Fault codes: ${p.rawObd['dtcs']?.isNotEmpty == true ? p.rawObd['dtcs'] : 'None'}$locSection
''';
  }

  static Future<String> sendMessage({
    required String userMessage,
    required List<_ChatMsg> history,
    required String systemPrompt,
    bool isAnalysis = false,
  }) async {
    final url = Uri.parse(
      'https://bedrock-runtime.${AppConfig.awsRegion}.amazonaws.com'
          '/model/$_model/invoke',
    );

    final messages = <Map<String, dynamic>>[];
    for (final h in history.take(10)) {
      messages.add({
        'role': h.isUser ? 'user' : 'assistant',
        'content': [{'text': h.text}],
      });
    }
    messages.add({
      'role': 'user',
      'content': [{'text': userMessage}],
    });

    final body = jsonEncode({
      'system': [{'text': systemPrompt}],
      'messages': messages,
      'inferenceConfig': {
        'maxTokens': isAnalysis ? 1000 : 800,
        'temperature': isAnalysis ? 0.2 : 0.7,
      },
    });

    final headers = _signer.sign(method: 'POST', uri: url, body: body);
    final response = await http.post(url, headers: headers, body: body);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['output']['message']['content'][0]['text'] ?? '';
    }
    throw Exception('Nova ${response.statusCode}: ${response.body}');
  }
}

// ─────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: AppColors.textMuted,
            letterSpacing: 1.2));
  }
}

class _Dot extends StatefulWidget {
  final int delay;
  const _Dot({required this.delay});
  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        width: 8, height: 8,
        decoration: BoxDecoration(
          color: AppColors.blueElectric.withOpacity(_anim.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}