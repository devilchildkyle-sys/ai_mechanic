import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'main.dart';
import 'config.dart';
import 'vehicle_profile_screen.dart';

// ─────────────────────────────────────────
//  CHAT MESSAGE MODEL
// ─────────────────────────────────────────
class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final bool isError;

  ChatMessage({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
    this.isError = false,
  }) : timestamp = timestamp ?? DateTime.now();
}

// ─────────────────────────────────────────
//  NOVA CHAT SERVICE
// ─────────────────────────────────────────
class NovaChatService {
  static final _signer = AwsSigV4Signer(
    accessKey: AppConfig.awsAccessKey,
    secretKey: AppConfig.awsSecretKey,
    region: AppConfig.awsRegion,
    service: 'bedrock',
  );

  static const String _model = 'amazon.nova-lite-v1:0';

  // Builds the system prompt with vehicle context baked in
  static String _buildSystemPrompt(VehicleProfile? profile) {
    final vehicleContext = profile != null
        ? '''
The user's vehicle:
- ${profile.displayName}
- Engine: ${profile.engineDisplay}
- Transmission: ${profile.transmission}
- VIN: ${profile.vin}
- Engine was ${profile.engineRunning ? 'RUNNING' : 'OFF'} during scan
- Live readings: ${profile.rawObd.entries.map((e) => '${e.key}: ${e.value}').join(', ')}
- Fault codes: ${profile.rawObd['dtcs']?.isEmpty ?? true ? 'None detected' : profile.rawObd['dtcs']}
'''
        : 'No vehicle data available yet — the user has not connected a dongle.';

    return '''
You are Nova, an expert AI mechanic assistant built into the AI Mechanic app, powered by Amazon Nova.

Your personality:
- Friendly, clear, and helpful — like a knowledgeable friend who happens to be a mechanic
- You explain things simply without being condescending
- You give honest assessments — if something is serious, say so clearly
- You use plain English, not jargon, unless the user asks for technical detail
- You are concise — give direct answers first, then explain if needed
- You never recommend ignoring a safety issue

$vehicleContext

Your capabilities:
- Explain what fault codes mean in plain English
- Rate the severity of issues (use a 0-10 "Scary Rating" when relevant)
- Give estimated repair cost ranges
- Suggest DIY fixes when appropriate and safe
- Recommend when to see a professional mechanic
- Answer general car maintenance questions
- Help the user understand their vehicle health report

Always end serious safety warnings with: ⚠️ DO NOT IGNORE THIS.
For minor issues add: 💡 Safe to drive, but address soon.
For no issues: ✅ You're good to go!
''';
  }

  static Future<String> sendMessage({
    required String userMessage,
    required List<ChatMessage> history,
    VehicleProfile? profile,
  }) async {
    try {
      final url = Uri.parse(
        'https://bedrock-runtime.${AppConfig.awsRegion}.amazonaws.com'
            '/model/$_model/invoke',
      );

      // Build conversation history for context
      final messages = <Map<String, dynamic>>[];

      // Add previous messages (last 10 for context window management)
      final recentHistory = history.length > 10
          ? history.sublist(history.length - 10)
          : history;

      for (final msg in recentHistory) {
        if (!msg.isError && msg.isUser) {
          messages.add({
            'role': 'user',
            'content': [
              {'text': msg.text}
            ],
          });
        } else if (!msg.isError && !msg.isUser && messages.isNotEmpty) {
          messages.add({
            'role': 'assistant',
            'content': [
              {'text': msg.text}
            ],
          });
        }
      }

      // Add current message
      messages.add({
        'role': 'user',
        'content': [
          {'text': userMessage}
        ],
      });

      final body = jsonEncode({
        'system': [
          {'text': _buildSystemPrompt(profile)}
        ],
        'messages': messages,
        'inferenceConfig': {
          'maxTokens': 1024,
          'temperature': 0.7,
        },
      });

      final headers = _signer.sign(method: 'POST', uri: url, body: body);
      final response = await http.post(url, headers: headers, body: body);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['output']['message']['content'][0]['text'] ?? 'No response';
      }

      throw Exception('Nova error ${response.statusCode}: ${response.body}');
    } catch (e) {
      throw Exception('Could not reach Nova AI: $e');
    }
  }
}

// ─────────────────────────────────────────
//  NOVA CHAT SCREEN
// ─────────────────────────────────────────
class NovaChatScreen extends StatefulWidget {
  final VehicleProfile? vehicleProfile;
  final String? initialMessage;

  const NovaChatScreen({
    super.key,
    this.vehicleProfile,
    this.initialMessage,
  });

  @override
  State<NovaChatScreen> createState() => _NovaChatScreenState();
}

class _NovaChatScreenState extends State<NovaChatScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _isTyping = false;

  // Quick prompt suggestions
  static const List<Map<String, String>> _quickPrompts = [
    {'icon': '🔍', 'text': 'Explain my fault codes'},
    {'icon': '❤️', 'text': 'How healthy is my vehicle?'},
    {'icon': '💰', 'text': 'How much will repairs cost?'},
    {'icon': '🔧', 'text': 'What can I fix myself?'},
    {'icon': '⚠️', 'text': 'Is it safe to drive?'},
    {'icon': '🛢️', 'text': 'When do I need an oil change?'},
  ];

  @override
  void initState() {
    super.initState();
    // Send greeting based on vehicle data
    _sendGreeting();
    if (widget.initialMessage != null) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _sendMessage(widget.initialMessage!);
      });
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _sendGreeting() {
    final profile = widget.vehicleProfile;
    String greeting;

    if (profile != null && profile.vin != 'UNKNOWN') {
      final dtcCount = int.tryParse(profile.rawObd['dtc_count'] ?? '0') ?? 0;
      if (dtcCount > 0) {
        greeting =
        'Hey! I\'m Nova 👋 I\'ve analyzed your ${profile.displayName} and found $dtcCount fault code(s). Want me to explain what they mean and how serious they are?';
      } else {
        greeting =
        'Hey! I\'m Nova 👋 Good news — I scanned your ${profile.displayName} and found no active fault codes. Your vehicle looks healthy! Got any questions about maintenance or anything you\'ve noticed?';
      }
    } else {
      greeting =
      'Hey! I\'m Nova 👋 Your AI mechanic, powered by Amazon Nova. I\'m here to help you understand your vehicle, explain fault codes, estimate repair costs, and give you honest advice. What can I help you with?';
    }

    setState(() {
      _messages.add(ChatMessage(text: greeting, isUser: false));
    });
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final userMsg = text.trim();
    _textCtrl.clear();

    setState(() {
      _messages.add(ChatMessage(text: userMsg, isUser: true));
      _isTyping = true;
    });

    _scrollToBottom();

    try {
      final response = await NovaChatService.sendMessage(
        userMessage: userMsg,
        history: _messages,
        profile: widget.vehicleProfile,
      );

      setState(() {
        _isTyping = false;
        _messages.add(ChatMessage(text: response, isUser: false));
      });
    } catch (e) {
      setState(() {
        _isTyping = false;
        _messages.add(ChatMessage(
          text: 'Sorry, I couldn\'t connect to Nova AI right now. Check your internet connection and try again.\n\nError: ${e.toString().replaceAll('Exception: ', '')}',
          isUser: false,
          isError: true,
        ));
      });
    }

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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
              if (widget.vehicleProfile != null) _buildVehicleBanner(),
              Expanded(child: _buildMessageList()),
              if (_messages.length <= 2) _buildQuickPrompts(),
              _buildInputBar(),
            ],
          ),
        ),
      ),
    );
  }

  // ── HEADER ────────────────────────────
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
          // Nova avatar
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: AppColors.primaryGradient),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: AppColors.blueCore.withOpacity(0.4), blurRadius: 10),
              ],
            ),
            child: const Icon(Icons.psychology_rounded,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nova AI',
                    style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                Text('Powered by Amazon Nova',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const LiveIndicator(color: AppColors.blueElectric, label: 'ONLINE'),
        ],
      ),
    );
  }

  // ── VEHICLE CONTEXT BANNER ────────────
  Widget _buildVehicleBanner() {
    final p = widget.vehicleProfile!;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.blueCore.withOpacity(0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.blueCore.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_car_rounded,
              color: AppColors.blueBright, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${p.displayName} · ${p.engineDisplay}',
              style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.blueBright,
                  fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            '${p.rawObd['dtc_count'] ?? 0} code(s)',
            style: TextStyle(
              fontSize: 11,
              color: (int.tryParse(p.rawObd['dtc_count'] ?? '0') ?? 0) > 0
                  ? AppColors.danger
                  : AppColors.success,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // ── MESSAGE LIST ──────────────────────
  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _messages.length + (_isTyping ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _messages.length) return _buildTypingIndicator();
        return _buildMessageBubble(_messages[i]);
      },
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment:
        msg.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!msg.isUser) ...[
            Container(
              width: 28, height: 28,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    colors: AppColors.primaryGradient),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.psychology_rounded,
                  color: Colors.white, size: 14),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: msg.text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: msg.isUser
                      ? const LinearGradient(
                      colors: AppColors.primaryGradient)
                      : null,
                  color: msg.isUser
                      ? null
                      : msg.isError
                      ? AppColors.danger.withOpacity(0.12)
                      : AppColors.bgCard.withOpacity(0.8),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(msg.isUser ? 18 : 4),
                    bottomRight: Radius.circular(msg.isUser ? 4 : 18),
                  ),
                  border: msg.isUser
                      ? null
                      : Border.all(
                      color: msg.isError
                          ? AppColors.danger.withOpacity(0.3)
                          : AppColors.border),
                  boxShadow: msg.isUser
                      ? [
                    BoxShadow(
                      color: AppColors.blueCore.withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    )
                  ]
                      : null,
                ),
                child: Text(
                  msg.text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: msg.isUser
                        ? Colors.white
                        : msg.isError
                        ? AppColors.danger
                        : AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          if (msg.isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 28, height: 28,
            decoration: const BoxDecoration(
              gradient:
              LinearGradient(colors: AppColors.primaryGradient),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.psychology_rounded,
                color: Colors.white, size: 14),
          ),
          const SizedBox(width: 8),
          Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.bgCard.withOpacity(0.8),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
              border: Border.all(color: AppColors.border),
            ),
            child: const _TypingDots(),
          ),
        ],
      ),
    );
  }

  // ── QUICK PROMPTS ─────────────────────
  Widget _buildQuickPrompts() {
    return Container(
      height: 44,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _quickPrompts.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final prompt = _quickPrompts[i];
          return GestureDetector(
            onTap: () => _sendMessage(prompt['text']!),
            child: Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.blueCore.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: AppColors.blueCore.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(prompt['icon']!,
                      style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 6),
                  Text(prompt['text']!,
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.blueBright,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── INPUT BAR ─────────────────────────
  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.bgDeep.withOpacity(0.9),
        border: Border(
            top: BorderSide(color: AppColors.border.withOpacity(0.5))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.bgCard.withOpacity(0.8),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      style: const TextStyle(
                          fontSize: 14, color: AppColors.textPrimary),
                      maxLines: 4,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Ask Nova anything about your car...',
                        hintStyle: TextStyle(
                            fontSize: 13, color: AppColors.textMuted),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 18, vertical: 12),
                      ),
                      onSubmitted: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _isTyping
                ? null
                : () => _sendMessage(_textCtrl.text),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 48, height: 48,
              decoration: BoxDecoration(
                gradient: _isTyping
                    ? null
                    : const LinearGradient(
                    colors: AppColors.primaryGradient),
                color: _isTyping
                    ? AppColors.bgCard.withOpacity(0.5)
                    : null,
                shape: BoxShape.circle,
                boxShadow: _isTyping
                    ? null
                    : [
                  BoxShadow(
                    color: AppColors.blueCore.withOpacity(0.4),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  )
                ],
              ),
              child: Icon(
                _isTyping
                    ? Icons.hourglass_top_rounded
                    : Icons.send_rounded,
                color: _isTyping
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
//  TYPING DOTS ANIMATION
// ─────────────────────────────────────────
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with TickerProviderStateMixin {
  late List<AnimationController> _ctrls;
  late List<Animation<double>> _anims;

  @override
  void initState() {
    super.initState();
    _ctrls = List.generate(
      3,
          (i) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      )..repeat(
        reverse: true,
        period: Duration(milliseconds: 600 + (i * 150)),
      ),
    );
    _anims = _ctrls
        .map((c) =>
        Tween<double>(begin: 0.3, end: 1.0).animate(
          CurvedAnimation(parent: c, curve: Curves.easeInOut),
        ))
        .toList();

    // Stagger start
    for (int i = 0; i < _ctrls.length; i++) {
      Future.delayed(Duration(milliseconds: i * 150), () {
        if (mounted) _ctrls[i].repeat(reverse: true);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _anims[i],
          builder: (_, __) => Container(
            width: 7, height: 7,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.blueElectric
                  .withOpacity(_anims[i].value),
            ),
          ),
        );
      }),
    );
  }
}