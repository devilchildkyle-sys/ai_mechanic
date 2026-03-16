import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'main.dart';
import 'vehicle_profile_screen.dart';
import 'binary_wrench_widget.dart';

// ─────────────────────────────────────────
//  VEHICLE RUNNING CHECK SCREEN
// ─────────────────────────────────────────
class VehicleCheckScreen extends StatefulWidget {
  final String deviceName;
  final String deviceId;
  final bool isClassic;

  const VehicleCheckScreen({
    super.key,
    required this.deviceName,
    required this.deviceId,
    this.isClassic = false,
  });

  @override
  State<VehicleCheckScreen> createState() => _VehicleCheckScreenState();
}

class _VehicleCheckScreenState extends State<VehicleCheckScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _onEngineChoice(bool isRunning) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => LoadingScreen(
          deviceName: widget.deviceName,
          deviceId: widget.deviceId,
          engineRunning: isRunning,
          isClassic: widget.isClassic,
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
          child: FadeTransition(
            opacity: _fadeAnim,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Header
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 40,
                          height: 40,
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
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Connected',
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w800)),
                          Text(widget.deviceName,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                        ],
                      ),
                      const Spacer(),
                      const LiveIndicator(
                          color: AppColors.success, label: 'LIVE'),
                    ],
                  ),

                  const Spacer(),

                  // Car icon
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      gradient: RadialGradient(colors: [
                        AppColors.blueCore.withOpacity(0.3),
                        AppColors.bgCard.withOpacity(0.8),
                      ]),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AppColors.blueCore.withOpacity(0.4),
                          width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.blueCore.withOpacity(0.3),
                          blurRadius: 30,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.directions_car_rounded,
                        size: 48, color: AppColors.blueBright),
                  ),

                  const SizedBox(height: 32),

                  const Text(
                    'Is your engine\ncurrently running?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'This helps Nova AI determine which\nsensors are available to read from.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),

                  const Spacer(),

                  Row(
                    children: [
                      Expanded(
                        child: _ChoiceCard(
                          icon: Icons.local_fire_department_rounded,
                          label: 'Yes',
                          sublabel: 'Engine on',
                          color: AppColors.success,
                          onTap: () => _onEngineChoice(true),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _ChoiceCard(
                          icon: Icons.power_settings_new_rounded,
                          label: 'No',
                          sublabel: 'Engine off',
                          color: AppColors.warning,
                          onTap: () => _onEngineChoice(false),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  const GlassCard(
                    padding: EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded,
                            color: AppColors.blueElectric, size: 18),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Some sensors like O2 and fuel trim are only readable while the engine is running.',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                                height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color color;
  final VoidCallback onTap;

  const _ChoiceCard({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
    required this.onTap,
  });

  @override
  State<_ChoiceCard> createState() => _ChoiceCardState();
}

class _ChoiceCardState extends State<_ChoiceCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        transform: Matrix4.identity()..scale(_pressed ? 0.96 : 1.0),
        padding: const EdgeInsets.symmetric(vertical: 28),
        decoration: BoxDecoration(
          color: widget.color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: widget.color.withOpacity(0.4),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: widget.color.withOpacity(0.15),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(widget.icon, color: widget.color, size: 36),
            const SizedBox(height: 12),
            Text(widget.label,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: widget.color,
                )),
            Text(widget.sublabel,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                )),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
//  LOADING SCREEN WITH NOVA AI TIPS
// ─────────────────────────────────────────
class LoadingScreen extends StatefulWidget {
  final String deviceName;
  final String deviceId;
  final bool engineRunning;
  final bool isClassic;

  const LoadingScreen({
    super.key,
    required this.deviceName,
    required this.deviceId,
    required this.engineRunning,
    this.isClassic = false,
  });

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with TickerProviderStateMixin {
  int _currentTip = 0;
  double _progress = 0.0;
  String _statusText = 'Connecting to vehicle...';
  Timer? _tipTimer;
  Timer? _progressTimer;

  late AnimationController _tipFadeCtrl;
  late Animation<double> _tipFadeAnim;

  static const List<Map<String, String>> _tips = [
    {
      'icon': '🔧',
      'title': 'Check Your Oil Regularly',
      'body': 'Most modern engines need an oil change every 5,000–7,500 miles. Fresh oil keeps your engine running smoothly and extends its life significantly.',
    },
    {
      'icon': '🌡️',
      'title': 'Watch Your Temperature Gauge',
      'body': 'If your temp gauge climbs toward the red, pull over immediately. Overheating can cause permanent engine damage in just minutes.',
    },
    {
      'icon': '🛞',
      'title': 'Tire Pressure Saves Fuel',
      'body': 'Properly inflated tires can improve fuel efficiency by up to 3%. Check your door jamb sticker for the correct PSI for your vehicle.',
    },
    {
      'icon': '⚡',
      'title': 'Battery Life Span',
      'body': 'Most car batteries last 3–5 years. If your engine cranks slowly or your lights dim, it may be time for a battery test.',
    },
    {
      'icon': '🍃',
      'title': 'Air Filter Affects Performance',
      'body': 'A clogged air filter reduces engine power and fuel economy. They\'re cheap to replace and easy to check — just open the airbox.',
    },
    {
      'icon': '💧',
      'title': 'Coolant Is Critical',
      'body': 'Low coolant is one of the most common causes of breakdowns. Check it when the engine is cold and top it up with the correct mixture.',
    },
    {
      'icon': '🔦',
      'title': 'Check Engine Light',
      'body': 'A solid check engine light usually means a minor issue. A flashing one means stop driving — a misfire can damage your catalytic converter.',
    },
    {
      'icon': '🛑',
      'title': 'Brake Fluid Matters',
      'body': 'Brake fluid absorbs moisture over time, lowering its boiling point. Most manufacturers recommend replacing it every 2 years regardless of mileage.',
    },
    {
      'icon': '🔩',
      'title': 'Spark Plugs & Fuel Economy',
      'body': 'Worn spark plugs cause misfires and poor fuel economy. Most iridium plugs last 60,000–100,000 miles.',
    },
    {
      'icon': '📋',
      'title': 'Keep Your Records',
      'body': 'A well-documented maintenance history increases your car\'s resale value and helps mechanics diagnose issues faster.',
    },
  ];

  static const List<Map<String, dynamic>> _stages = [
    {'text': 'Connecting to vehicle...', 'progress': 0.15},
    {'text': 'Reading VIN number...', 'progress': 0.35},
    {'text': 'Identifying year, make & model...', 'progress': 0.55},
    {'text': 'Loading vehicle sensor map...', 'progress': 0.75},
    {'text': 'Preparing Nova AI analysis...', 'progress': 0.90},
    {'text': 'Almost ready...', 'progress': 1.0},
  ];

  int _stageIndex = 0;

  @override
  void initState() {
    super.initState();

    _tipFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..value = 1.0;

    _tipFadeAnim =
        CurvedAnimation(parent: _tipFadeCtrl, curve: Curves.easeInOut);

    _startTipCycle();
    _startProgressSimulation();
  }

  void _startTipCycle() {
    _tipTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
      await _tipFadeCtrl.reverse();
      if (!mounted) return;
      setState(() {
        _currentTip = (_currentTip + 1) % _tips.length;
      });
      await _tipFadeCtrl.forward();
    });
  }

  void _startProgressSimulation() {
    _progressTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (!mounted) return;
      if (_stageIndex < _stages.length - 1) {
        _stageIndex++;
        setState(() {
          _progress = _stages[_stageIndex]['progress'];
          _statusText = _stages[_stageIndex]['text'];
        });
      } else {
        _progressTimer?.cancel();
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) _onLoadingComplete();
        });
      }
    });
  }

  void _onLoadingComplete() {
    if (widget.isClassic) {
      // Classic BT — pass MAC address, VehicleProfileScreen handles RFCOMM
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => VehicleProfileScreen(
            classicMac: widget.deviceId,
            engineRunning: widget.engineRunning,
          ),
        ),
      );
      return;
    }
    // BLE — use connected device
    final connected = FlutterBluePlus.connectedDevices;
    if (connected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No device connected. Please reconnect.'),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => VehicleProfileScreen(
          device: connected.first,
          engineRunning: widget.engineRunning,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tipTimer?.cancel();
    _progressTimer?.cancel();
    _tipFadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tip = _tips[_currentTip];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Scanning Vehicle',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w800)),
                        Text(
                          widget.engineRunning
                              ? 'Engine running — full scan available'
                              : 'Engine off — basic scan available',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                    LiveIndicator(
                      color: widget.engineRunning
                          ? AppColors.success
                          : AppColors.warning,
                      label: widget.engineRunning ? 'ENGINE ON' : 'ENGINE OFF',
                    ),
                  ],
                ),

                const Spacer(),

                _buildNovaRing(),

                const SizedBox(height: 32),

                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Text(
                    _statusText,
                    key: ValueKey(_statusText),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 4,
                    backgroundColor: Colors.white.withOpacity(0.06),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.blueElectric),
                  ),
                ),

                const SizedBox(height: 6),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Nova AI is analyzing your vehicle',
                        style: TextStyle(
                            fontSize: 10, color: AppColors.textMuted)),
                    Text('${(_progress * 100).toInt()}%',
                        style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.blueElectric,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600)),
                  ],
                ),

                const Spacer(),

                const SectionLabel('Did you know?'),

                FadeTransition(
                  opacity: _tipFadeAnim,
                  child: GlassCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tip['icon']!, style: const TextStyle(fontSize: 32)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(tip['title']!,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  )),
                              const SizedBox(height: 6),
                              Text(tip['body']!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                    height: 1.5,
                                  )),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_tips.length, (i) {
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: i == _currentTip ? 16 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == _currentTip
                            ? AppColors.blueElectric
                            : AppColors.textMuted.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  }),
                ),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNovaRing() {
    return const BinaryWrenchWidget(size: 170);
  }
}