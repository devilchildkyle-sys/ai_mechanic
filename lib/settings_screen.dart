import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';

// ─────────────────────────────────────────
//  APP SETTINGS MODEL — singleton
// ─────────────────────────────────────────
class AppSettings {
  static final AppSettings _instance = AppSettings._internal();
  factory AppSettings() => _instance;
  AppSettings._internal();

  bool useFahrenheit = false;
  bool useMiles = false;
  bool darkMode = true;
  bool liveUpdates = true;
  int updateIntervalMs = 500;
  bool showDebugButton = false;

  static const _keyF         = 'use_fahrenheit';
  static const _keyMiles     = 'use_miles';
  static const _keyLive      = 'live_updates';
  static const _keyInterval  = 'update_interval';
  static const _keyDebug     = 'show_debug';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    useFahrenheit    = prefs.getBool(_keyF)        ?? false;
    useMiles         = prefs.getBool(_keyMiles)     ?? false;
    liveUpdates      = prefs.getBool(_keyLive)      ?? true;
    updateIntervalMs = prefs.getInt(_keyInterval)   ?? 500;
    showDebugButton  = prefs.getBool(_keyDebug)     ?? false;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyF,        useFahrenheit);
    await prefs.setBool(_keyMiles,    useMiles);
    await prefs.setBool(_keyLive,     liveUpdates);
    await prefs.setInt(_keyInterval,  updateIntervalMs);
    await prefs.setBool(_keyDebug,    showDebugButton);
  }

  // ── UNIT CONVERTERS ───────────────────

  String formatTemp(int celsius) {
    if (useFahrenheit) {
      final f = (celsius * 9 / 5) + 32;
      return '${f.round()}°F';
    }
    return '$celsius°C';
  }

  String formatSpeed(int kmh) {
    if (useMiles) {
      final mph = (kmh * 0.621371).round();
      return '$mph mph';
    }
    return '$kmh km/h';
  }

  String get tempUnit => useFahrenheit ? '°F' : '°C';
  String get speedUnit => useMiles ? 'mph' : 'km/h';
}

// Global settings instance
final appSettings = AppSettings();

// ─────────────────────────────────────────
//  SETTINGS SCREEN
// ─────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _saving = false;

  Future<void> _toggle(VoidCallback change) async {
    setState(() {
      change();
      _saving = true;
    });
    await appSettings.save();
    setState(() => _saving = false);
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
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildUnitSection(),
                      const SizedBox(height: 20),
                      _buildLiveDataSection(),
                      const SizedBox(height: 20),
                      _buildDeveloperSection(),
                      const SizedBox(height: 20),
                      _buildAboutSection(),
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
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Settings',
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                Text('Customize your experience',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (_saving)
            const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.blueElectric),
            )
          else
            const Icon(Icons.check_circle_rounded,
                color: AppColors.success, size: 20),
        ],
      ),
    );
  }

  // ── UNITS ─────────────────────────────
  Widget _buildUnitSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Units'),
        GlassCard(
          child: Column(
            children: [
              _SettingsTile(
                icon: Icons.thermostat_rounded,
                iconColor: AppColors.warning,
                title: 'Temperature',
                subtitle: appSettings.useFahrenheit
                    ? 'Fahrenheit (°F)'
                    : 'Celsius (°C)',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _UnitChip(
                      label: '°C',
                      selected: !appSettings.useFahrenheit,
                      onTap: () => _toggle(
                              () => appSettings.useFahrenheit = false),
                    ),
                    const SizedBox(width: 6),
                    _UnitChip(
                      label: '°F',
                      selected: appSettings.useFahrenheit,
                      onTap: () => _toggle(
                              () => appSettings.useFahrenheit = true),
                    ),
                  ],
                ),
              ),
              _Divider(),
              _SettingsTile(
                icon: Icons.speed_rounded,
                iconColor: AppColors.violetLight,
                title: 'Speed',
                subtitle:
                appSettings.useMiles ? 'Miles per hour' : 'Kilometers per hour',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _UnitChip(
                      label: 'km/h',
                      selected: !appSettings.useMiles,
                      onTap: () =>
                          _toggle(() => appSettings.useMiles = false),
                    ),
                    const SizedBox(width: 6),
                    _UnitChip(
                      label: 'mph',
                      selected: appSettings.useMiles,
                      onTap: () =>
                          _toggle(() => appSettings.useMiles = true),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── LIVE DATA ─────────────────────────
  Widget _buildLiveDataSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Live Data'),
        GlassCard(
          child: Column(
            children: [
              _SettingsTile(
                icon: Icons.sync_rounded,
                iconColor: AppColors.blueElectric,
                title: 'Live Updates',
                subtitle: 'Auto-refresh sensor readings',
                trailing: Switch(
                  value: appSettings.liveUpdates,
                  onChanged: (v) =>
                      _toggle(() => appSettings.liveUpdates = v),
                  activeThumbColor: AppColors.blueElectric,
                ),
              ),
              if (appSettings.liveUpdates) ...[
                _Divider(),
                _SettingsTile(
                  icon: Icons.timer_rounded,
                  iconColor: AppColors.teal,
                  title: 'Update Speed',
                  subtitle: _intervalLabel(appSettings.updateIntervalMs),
                  trailing: null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppColors.blueElectric,
                          inactiveTrackColor:
                          AppColors.border,
                          thumbColor: AppColors.blueElectric,
                          overlayColor:
                          AppColors.blueElectric.withOpacity(0.2),
                          trackHeight: 3,
                        ),
                        child: Slider(
                          value: appSettings.updateIntervalMs.toDouble(),
                          min: 250,
                          max: 2000,
                          divisions: 7,
                          onChanged: (v) => _toggle(
                                  () => appSettings.updateIntervalMs =
                                  v.round()),
                          onChangeEnd: (_) => appSettings.save(),
                        ),
                      ),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Fast',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textMuted)),
                          Text('Slow',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textMuted)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── DEVELOPER ─────────────────────────
  Widget _buildDeveloperSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Developer'),
        GlassCard(
          child: _SettingsTile(
            icon: Icons.terminal_rounded,
            iconColor: AppColors.textMuted,
            title: 'Show Debug Console',
            subtitle: 'OBD2 raw data and diagnostic tools',
            trailing: Switch(
              value: appSettings.showDebugButton,
              onChanged: (v) =>
                  _toggle(() => appSettings.showDebugButton = v),
              activeThumbColor: AppColors.blueElectric,
            ),
          ),
        ),
      ],
    );
  }

  // ── ABOUT ─────────────────────────────
  Widget _buildAboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('About'),
        GlassCard(
          child: Column(
            children: [
              _SettingsTile(
                icon: Icons.psychology_rounded,
                iconColor: AppColors.blueElectric,
                title: 'AI Mechanic',
                subtitle: 'Version 1.0.0 — Amazon Nova Hackathon',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: AppColors.primaryGradient),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('v1.0',
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              _Divider(),
              const _SettingsTile(
                icon: Icons.bolt_rounded,
                iconColor: AppColors.warning,
                title: 'Powered by Amazon Nova',
                subtitle: 'amazon.nova-lite-v1:0 via AWS Bedrock',
                trailing: null,
              ),
              _Divider(),
              const _SettingsTile(
                icon: Icons.bluetooth_rounded,
                iconColor: AppColors.blueBright,
                title: 'OBD2 Protocol',
                subtitle: 'ELM327 BLE — Veepeak compatible',
                trailing: null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _intervalLabel(int ms) {
    if (ms <= 250) return 'Very fast (250ms — 4x/sec)';
    if (ms <= 500) return 'Fast (500ms — 2x/sec)';
    if (ms <= 750) return 'Normal (750ms)';
    if (ms <= 1000) return 'Moderate (1 sec)';
    return 'Slow (${ms}ms)';
  }
}

// ─────────────────────────────────────────
//  REUSABLE SETTINGS WIDGETS
// ─────────────────────────────────────────
class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _UnitChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _UnitChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(colors: AppColors.primaryGradient)
              : null,
          color: selected ? null : AppColors.bgCard2.withOpacity(0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : AppColors.border,
          ),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected
                    ? Colors.white
                    : AppColors.textMuted)),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: AppColors.border.withOpacity(0.5),
    );
  }
}