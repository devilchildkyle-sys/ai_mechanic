import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bluetooth_screen.dart';
import 'settings_screen.dart';
import 'history_screen.dart';
import 'onboarding_screen.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appSettings.load();
  runApp(const AIMechanicApp());
}

// ─────────────────────────────────────────
//  APP THEME & COLOR SYSTEM
// ─────────────────────────────────────────
class AppColors {
  // Backgrounds
  static const bgDeep    = Color(0xFF050D1A);
  static const bgCard    = Color(0xFF0A1937);
  static const bgCard2   = Color(0xFF0F2350);

  // Blues
  static const blueCore    = Color(0xFF1A6CF5);
  static const blueBright  = Color(0xFF4D9FFF);
  static const blueElectric = Color(0xFF00C3FF);

  // Accents
  static const violet      = Color(0xFF5B4AFF);
  static const violetLight = Color(0xFF8B7FFF);
  static const teal        = Color(0xFF00E5C3);

  // Status colors
  static const success = Color(0xFF00E5A0);
  static const warning = Color(0xFFFFB347);
  static const danger  = Color(0xFFFF4D6D);

  // Text
  static const textPrimary   = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA0B4CC);
  static const textMuted     = Color(0xFF4A6080);

  // Borders
  static const border = Color(0x1A4DA6FF);

  // Gradients
  static const List<Color> primaryGradient = [blueCore, violet];
  static const List<Color> bgGradient = [bgDeep, Color(0xFF0A1F50), Color(0xFF0D0A2E)];
}

class AppTheme {
  static ThemeData dark() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bgDeep,
      fontFamily: 'Exo2',
      colorScheme: const ColorScheme.dark(
        primary: AppColors.blueCore,
        secondary: AppColors.blueElectric,
        surface: AppColors.bgCard,
        error: AppColors.danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          fontFamily: 'Exo2',
        ),
        iconTheme: IconThemeData(color: AppColors.textPrimary),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
        displayMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        displaySmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        headlineMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        bodyLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: AppColors.textPrimary),
        bodyMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: AppColors.textSecondary),
        bodySmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w400, color: AppColors.textMuted),
        labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.5),
      ),
      useMaterial3: true,
    );
  }

  static ThemeData light() {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFE8F0FE),
      fontFamily: 'Exo2',
      colorScheme: const ColorScheme.light(
        primary: AppColors.blueCore,
        secondary: AppColors.blueElectric,
        surface: Colors.white,
        error: AppColors.danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: Color(0xFF1A3A6E),
          fontSize: 18,
          fontWeight: FontWeight.w700,
          fontFamily: 'Exo2',
        ),
        iconTheme: IconThemeData(color: Color(0xFF1A3A6E)),
      ),
      useMaterial3: true,
    );
  }
}

// ─────────────────────────────────────────
//  REUSABLE WIDGETS
// ─────────────────────────────────────────

class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: AppColors.bgGradient,
            ),
          ),
        ),
        Positioned(
          top: -100, left: -60,
          child: Container(
            width: 300, height: 300,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                AppColors.blueCore.withOpacity(0.25),
                Colors.transparent,
              ]),
            ),
          ),
        ),
        Positioned(
          bottom: -80, right: -60,
          child: Container(
            width: 280, height: 280,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                AppColors.violet.withOpacity(0.2),
                Colors.transparent,
              ]),
            ),
          ),
        ),
        Opacity(
          opacity: 0.04,
          child: CustomPaint(
            painter: _StripePainter(),
            size: Size.infinite,
          ),
        ),
        child,
      ],
    );
  }
}

class _StripePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF64A0FF)
      ..strokeWidth = 20;
    for (double i = -size.height; i < size.width + size.height; i += 80) {
      canvas.drawLine(Offset(i, 0), Offset(i + size.height, size.height), paint);
    }
  }
  @override
  bool shouldRepaint(_) => false;
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final double borderRadius;
  final Color? borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius = 20,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.bgCard.withOpacity(0.7),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: borderColor ?? AppColors.border,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.blueCore.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;

  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: AppColors.primaryGradient,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppColors.blueCore.withOpacity(0.45),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: isLoading ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: isLoading
              ? const SizedBox(
            width: 22, height: 22,
            child: CircularProgressIndicator(
              color: Colors.white, strokeWidth: 2.5,
            ),
          )
              : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: Colors.white),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  const SecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Color(0x4D4DA6FF), width: 1),
          backgroundColor: AppColors.blueCore.withOpacity(0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: AppColors.blueBright),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.blueBright,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 2.5,
              color: AppColors.blueElectric,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(height: 1, color: AppColors.border),
          ),
        ],
      ),
    );
  }
}

class LiveIndicator extends StatefulWidget {
  final Color color;
  final String label;
  const LiveIndicator({super.key, this.color = AppColors.success, this.label = 'LIVE'});

  @override
  State<LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<LiveIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 1.0, end: 0.3).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: widget.color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: widget.color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _anim,
            builder: (_, __) => Opacity(
              opacity: _anim.value,
              child: Container(
                width: 6, height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                  boxShadow: [BoxShadow(color: widget.color.withOpacity(0.8), blurRadius: 4)],
                ),
              ),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            widget.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: widget.color,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class NovaBadge extends StatelessWidget {
  const NovaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.blueElectric.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.blueElectric.withOpacity(0.3)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LiveIndicator(color: AppColors.blueElectric, label: 'Powered by Amazon Nova'),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  MAIN APP
// ─────────────────────────────────────────
class AIMechanicApp extends StatelessWidget {
  const AIMechanicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nova AI Mechanic',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const _AppEntry(),
    );
  }
}

// Checks whether to show onboarding or go straight to home
class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool _loading = true;
  bool _showOnboarding = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final done = await OnboardingService.isComplete();
    setState(() {
      _showOnboarding = !done;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(backgroundColor: AppColors.bgDeep);
    }
    if (_showOnboarding) {
      return OnboardingScreen(
        onComplete: () {
          setState(() => _showOnboarding = false);
        },
      );
    }
    return const HomeScreen();
  }
}

// ─────────────────────────────────────────
//  HOME SCREEN — real, functional
// ─────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late AnimationController _entryCtrl;
  late Animation<double> _pulseAnim;

  ScanRecord? _lastScan;
  int _totalScans = 0;
  int _totalVehicles = 0;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();

    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _loadHistory();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _entryCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final records = await HistoryService.loadAll();
    if (!mounted) return;
    final vins = records.map((r) => r.vin).toSet();
    setState(() {
      _lastScan = records.isNotEmpty ? records.first : null;
      _totalScans = records.length;
      _totalVehicles = vins.length;
    });
  }

  void _goToScan() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BluetoothScreen()),
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
              _buildTopBar(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 20),
                      _buildHero(),
                      const SizedBox(height: 32),
                      _buildScanButton(),
                      const SizedBox(height: 28),
                      if (_lastScan != null) ...[
                        _buildLastVehicleCard(),
                        const SizedBox(height: 24),
                      ],
                      if (_totalScans > 0) _buildStatsRow(),
                      if (_totalScans == 0) _buildFirstTimeHint(),
                      const SizedBox(height: 24),
                      _buildQuickActions(),
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

  // ── TOP BAR ──────────────────────────────────────────
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: AppColors.primaryGradient),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(color: AppColors.blueCore.withOpacity(0.5), blurRadius: 12),
              ],
            ),
            child: const Icon(Icons.electric_bolt_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('NOVA',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w900,
                  color: AppColors.blueElectric, letterSpacing: 3)),
          const SizedBox(width: 4),
          const Text('MECHANIC',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w300,
                  color: AppColors.textSecondary, letterSpacing: 2)),
          const Spacer(),
          GestureDetector(
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: AppColors.bgCard.withOpacity(0.7),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Icons.settings_rounded,
                  color: AppColors.textSecondary, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  // ── HERO ─────────────────────────────────────────────
  Widget _buildHero() {
    return AnimatedBuilder(
      animation: _entryCtrl,
      builder: (_, child) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.3), end: Offset.zero,
        ).animate(CurvedAnimation(
            parent: _entryCtrl,
            curve: const Interval(0.0, 0.6, curve: Curves.easeOut)));
        final fade = Tween<double>(begin: 0, end: 1).animate(
            CurvedAnimation(parent: _entryCtrl,
                curve: const Interval(0.0, 0.5, curve: Curves.easeOut)));
        return FadeTransition(
            opacity: fade, child: SlideTransition(position: slide, child: child));
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pulsing radar circle
          Center(
            child: AnimatedBuilder(
              animation: _pulseAnim,
              builder: (_, __) => Stack(
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: _pulseAnim.value * 1.4,
                    child: Container(
                      width: 100, height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.blueElectric
                              .withOpacity(0.15 * _pulseAnim.value),
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: _pulseAnim.value * 1.15,
                    child: Container(
                      width: 100, height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.blueElectric
                              .withOpacity(0.25 * _pulseAnim.value),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    width: 100, height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.bgCard2,
                      border: Border.all(
                          color: AppColors.blueElectric.withOpacity(0.4),
                          width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.blueCore.withOpacity(0.3),
                          blurRadius: 30, spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.directions_car_rounded,
                        color: AppColors.blueElectric, size: 44),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'AI Vehicle\nDiagnostics',
            style: TextStyle(
              fontSize: 38, fontWeight: FontWeight.w900,
              height: 1.1, letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Connect your OBD2 dongle and let Nova AI\nidentify your vehicle, read sensors, and\nspot problems before they become costly.',
            style: TextStyle(
                fontSize: 13, color: AppColors.textSecondary, height: 1.6),
          ),
        ],
      ),
    );
  }

  // ── SCAN BUTTON ──────────────────────────────────────
  Widget _buildScanButton() {
    return AnimatedBuilder(
      animation: _entryCtrl,
      builder: (_, child) {
        final fade = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
            parent: _entryCtrl,
            curve: const Interval(0.3, 0.8, curve: Curves.easeOut)));
        return FadeTransition(opacity: fade, child: child);
      },
      child: GestureDetector(
        onTap: _goToScan,
        child: AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, __) => Container(
            width: double.infinity,
            height: 64,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: AppColors.primaryGradient,
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: AppColors.blueCore
                      .withOpacity(0.35 + 0.15 * _pulseAnim.value),
                  blurRadius: 20 + 10 * _pulseAnim.value,
                  spreadRadius: 2,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.bluetooth_searching_rounded,
                      color: Colors.white, size: 18),
                ),
                const SizedBox(width: 12),
                const Text(
                  'START NEW SCAN',
                  style: TextStyle(
                    color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w800, letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward_rounded,
                    color: Colors.white, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── LAST VEHICLE CARD ────────────────────────────────
  Widget _buildLastVehicleCard() {
    final scan = _lastScan!;
    final dtcCount =
        int.tryParse(scan.rawObd['dtc_count'] ?? '0') ?? 0;

    return AnimatedBuilder(
      animation: _entryCtrl,
      builder: (_, child) {
        final fade = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
            parent: _entryCtrl,
            curve: const Interval(0.5, 1.0, curve: Curves.easeOut)));
        return FadeTransition(opacity: fade, child: child);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('Last Scanned Vehicle')),
              GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const HistoryScreen()))
                    .then((_) => _loadHistory()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.blueElectric.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppColors.blueElectric.withOpacity(0.3)),
                  ),
                  child: const Row(
                    children: [
                      Text('View All',
                          style: TextStyle(
                              fontSize: 10,
                              color: AppColors.blueElectric,
                              fontWeight: FontWeight.w700)),
                      SizedBox(width: 4),
                      Icon(Icons.arrow_forward_rounded,
                          size: 12, color: AppColors.blueElectric),
                    ],
                  ),
                ),
              ),
            ],
          ),
          GlassCard(
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 52, height: 52,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: AppColors.primaryGradient),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                              color: AppColors.blueCore.withOpacity(0.35),
                              blurRadius: 12)
                        ],
                      ),
                      child: const Icon(Icons.directions_car_rounded,
                          color: Colors.white, size: 26),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${scan.year} ${scan.make} ${scan.model}',
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(scan.engine,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                          const SizedBox(height: 2),
                          Text(
                            _formatDate(scan.scanTime),
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    // DTC badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: dtcCount > 0
                            ? AppColors.danger.withOpacity(0.15)
                            : AppColors.success.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: dtcCount > 0
                              ? AppColors.danger.withOpacity(0.3)
                              : AppColors.success.withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            dtcCount > 0
                                ? Icons.warning_rounded
                                : Icons.check_circle_rounded,
                            color: dtcCount > 0
                                ? AppColors.danger
                                : AppColors.success,
                            size: 18,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            dtcCount > 0 ? '$dtcCount DTCs' : 'Clear',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: dtcCount > 0
                                  ? AppColors.danger
                                  : AppColors.success,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // VIN strip
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.bgCard2.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.fingerprint_rounded,
                          size: 12, color: AppColors.textMuted),
                      const SizedBox(width: 6),
                      const Text('VIN',
                          style: TextStyle(
                              fontSize: 9,
                              color: AppColors.textMuted,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          scan.vin,
                          style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: AppColors.blueElectric,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── STATS ROW ─────────────────────────────────────────
  Widget _buildStatsRow() {
    return AnimatedBuilder(
      animation: _entryCtrl,
      builder: (_, child) {
        final fade = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
            parent: _entryCtrl,
            curve: const Interval(0.6, 1.0, curve: Curves.easeOut)));
        return FadeTransition(opacity: fade, child: child);
      },
      child: Row(
        children: [
          Expanded(child: _StatCard(
              icon: Icons.history_rounded,
              label: 'TOTAL SCANS',
              value: _totalScans.toString(),
              color: AppColors.blueElectric)),
          const SizedBox(width: 12),
          Expanded(child: _StatCard(
              icon: Icons.directions_car_rounded,
              label: 'VEHICLES',
              value: _totalVehicles.toString(),
              color: AppColors.violetLight)),
          const SizedBox(width: 12),
          const Expanded(child: _StatCard(
              icon: Icons.electric_bolt_rounded,
              label: 'AI POWERED',
              value: 'Nova',
              color: AppColors.teal)),
        ],
      ),
    );
  }

  // ── FIRST TIME HINT ───────────────────────────────────
  Widget _buildFirstTimeHint() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: AppColors.blueElectric.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.info_outline_rounded,
                color: AppColors.blueElectric, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Getting Started',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                SizedBox(height: 2),
                Text(
                  'Plug in your OBD2 dongle, pair it via Bluetooth, then tap Start Scan. Nova AI will handle the rest.',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                      height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── QUICK ACTIONS ─────────────────────────────────────
  Widget _buildQuickActions() {
    return AnimatedBuilder(
      animation: _entryCtrl,
      builder: (_, child) {
        final fade = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
            parent: _entryCtrl,
            curve: const Interval(0.7, 1.0, curve: Curves.easeOut)));
        return FadeTransition(opacity: fade, child: child);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Quick Actions'),
          _QuickActionButton(
            icon: Icons.history_rounded,
            label: 'View Scan History',
            color: AppColors.violetLight,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const HistoryScreen()))
                .then((_) => _loadHistory()),
          ),
          const SizedBox(height: 16),
          // AWS branding strip
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.bgCard.withOpacity(0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.blueElectric.withOpacity(0.2)),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.auto_awesome_rounded,
                    size: 12, color: AppColors.blueElectric),
                SizedBox(width: 6),
                Text(
                  'Powered by Amazon Nova AI  ·  AWS Bedrock',
                  style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textMuted,
                      letterSpacing: 0.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

// ─────────────────────────────────────────
//  STAT CARD
// ─────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatCard({
    required this.icon, required this.label,
    required this.value, required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w900,
                  color: color, fontFamily: 'monospace')),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 7, color: AppColors.textMuted,
                  fontWeight: FontWeight.w700, letterSpacing: 0.8),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  QUICK ACTION BUTTON
// ─────────────────────────────────────────
class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.icon, required this.label,
    required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }
}