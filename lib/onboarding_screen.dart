import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';

// ─────────────────────────────────────────────
//  ONBOARDING SERVICE — tracks first launch
// ─────────────────────────────────────────────
class OnboardingService {
  static const _key = 'onboarding_complete';

  static Future<bool> isComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  static Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

// ─────────────────────────────────────────────
//  ONBOARDING SCREEN
// ─────────────────────────────────────────────
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageCtrl = PageController();
  int _currentPage = 0;
  late AnimationController _entryCtrl;

  static const _pages = [
    _OnboardingPage(
      icon: Icons.electric_bolt_rounded,
      iconColor: AppColors.blueElectric,
      title: 'Meet Nova\nAI Mechanic',
      subtitle:
      'Your intelligent vehicle diagnostics assistant, powered by Amazon Nova AI and AWS Bedrock.',
      tag: 'AMAZON NOVA AI HACKATHON',
    ),
    _OnboardingPage(
      icon: Icons.bluetooth_searching_rounded,
      iconColor: AppColors.violetLight,
      title: 'Plug In &\nConnect',
      subtitle:
      'Grab any OBD2 Bluetooth dongle, plug it into your car\'s diagnostic port under the dash, and pair it in seconds.',
      tag: 'STEP 1',
    ),
    _OnboardingPage(
      icon: Icons.psychology_rounded,
      iconColor: AppColors.teal,
      title: 'Nova AI Reads\nYour Vehicle',
      subtitle:
      'Nova decodes your VIN, selects the right sensors for your specific engine, monitors live data, and watches for issues in real time.',
      tag: 'STEP 2',
    ),
    _OnboardingPage(
      icon: Icons.health_and_safety_rounded,
      iconColor: AppColors.success,
      title: 'Know Before\nIt Gets Costly',
      subtitle:
      'Full health reports, fault code explanations, and an AI chat that answers any question about your car — in plain English.',
      tag: 'STEP 3',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _entryCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentPage < _pages.length - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _finish();
    }
  }

  void _skip() => _finish();

  Future<void> _finish() async {
    await OnboardingService.markComplete();
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              // Top bar
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 30, height: 30,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                colors: AppColors.primaryGradient),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.electric_bolt_rounded,
                              color: Colors.white, size: 16),
                        ),
                        const SizedBox(width: 8),
                        const Text('NOVA',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w900,
                                color: AppColors.blueElectric,
                                letterSpacing: 2)),
                      ],
                    ),
                    if (_currentPage < _pages.length - 1)
                      GestureDetector(
                        onTap: _skip,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: AppColors.bgCard.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: const Text('Skip',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                  ],
                ),
              ),

              // Pages
              Expanded(
                child: PageView.builder(
                  controller: _pageCtrl,
                  onPageChanged: (i) {
                    setState(() => _currentPage = i);
                    _entryCtrl.reset();
                    _entryCtrl.forward();
                  },
                  itemCount: _pages.length,
                  itemBuilder: (_, i) => _PageContent(
                    page: _pages[i],
                    entryCtrl: _entryCtrl,
                  ),
                ),
              ),

              // Bottom controls
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
                child: Column(
                  children: [
                    // Dot indicators
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_pages.length, (i) {
                        final isActive = i == _currentPage;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: isActive ? 24 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: isActive
                                ? AppColors.blueElectric
                                : AppColors.textMuted.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 28),

                    // CTA button
                    GestureDetector(
                      onTap: _next,
                      child: Container(
                        width: double.infinity,
                        height: 60,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: AppColors.primaryGradient,
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.blueCore.withOpacity(0.45),
                              blurRadius: 24,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _currentPage < _pages.length - 1
                                  ? 'CONTINUE'
                                  : 'GET STARTED',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              _currentPage < _pages.length - 1
                                  ? Icons.arrow_forward_rounded
                                  : Icons.electric_bolt_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  PAGE CONTENT WIDGET
// ─────────────────────────────────────────────
class _PageContent extends StatelessWidget {
  final _OnboardingPage page;
  final AnimationController entryCtrl;

  const _PageContent({required this.page, required this.entryCtrl});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: entryCtrl,
      builder: (_, child) {
        final fade = Tween<double>(begin: 0, end: 1).animate(
          CurvedAnimation(
              parent: entryCtrl,
              curve: const Interval(0.0, 0.6, curve: Curves.easeOut)),
        );
        final slideUp = Tween<Offset>(
          begin: const Offset(0, 0.12),
          end: Offset.zero,
        ).animate(CurvedAnimation(
            parent: entryCtrl,
            curve: const Interval(0.0, 0.7, curve: Curves.easeOut)));

        return FadeTransition(
          opacity: fade,
          child: SlideTransition(position: slideUp, child: child),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),

            // Tag chip
            Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: page.iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border:
                Border.all(color: page.iconColor.withOpacity(0.3)),
              ),
              child: Text(
                page.tag,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: page.iconColor,
                  letterSpacing: 2,
                ),
              ),
            ),

            const SizedBox(height: 40),

            // Big glowing icon
            Center(
              child: Container(
                width: 140, height: 140,
                decoration: BoxDecoration(
                  color: page.iconColor.withOpacity(0.07),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: page.iconColor.withOpacity(0.25), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: page.iconColor.withOpacity(0.2),
                      blurRadius: 50,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: Icon(page.icon, color: page.iconColor, size: 64),
              ),
            ),

            const SizedBox(height: 44),

            // Title
            Text(
              page.title,
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w900,
                height: 1.1,
                letterSpacing: -1,
              ),
            ),

            const SizedBox(height: 16),

            // Subtitle
            Text(
              page.subtitle,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.textSecondary,
                height: 1.65,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  DATA CLASS
// ─────────────────────────────────────────────
class _OnboardingPage {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String tag;

  const _OnboardingPage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.tag,
  });
}