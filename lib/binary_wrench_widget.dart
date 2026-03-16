import 'dart:math' as math;
import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════
//  BinaryWrenchWidget
//
//  Animated wrench silhouette built entirely from '1' and '0'
//  characters. No paths or fills — only text painted by CustomPainter.
//
//  Animations:
//   • Glow pulse  — overall brightness breathes in/out (3 s loop)
//   • Scanline    — electric line sweeps top→bottom (2.5 s loop)
//   • Flicker     — occasional random brightness spike (random timer)
//   • Char cycle  — digits subtly shift every 1.5 s (optional)
//
//  Usage:
//    BinaryWrenchWidget(size: 160)
//    BinaryWrenchWidget(size: 80, showScanline: false)
// ═══════════════════════════════════════════════════════════════════

class BinaryWrenchWidget extends StatefulWidget {
  final double size;
  final bool showScanline;

  const BinaryWrenchWidget({
    super.key,
    this.size = 160,
    this.showScanline = true,
  });

  @override
  State<BinaryWrenchWidget> createState() => _BinaryWrenchWidgetState();
}

class _BinaryWrenchWidgetState extends State<BinaryWrenchWidget>
    with TickerProviderStateMixin {
  // Glow pulse: 0.0 → 1.0 → 0.0
  late AnimationController _glowCtrl;
  late Animation<double> _glowAnim;

  // Scanline: 0.0 (top) → 1.0 (bottom)
  late AnimationController _scanCtrl;
  late Animation<double> _scanAnim;

  // Flicker: brief spike to max brightness
  late AnimationController _flickerCtrl;
  late Animation<double> _flickerAnim;

  // Char seed — increments to shift 1/0 pattern
  int _charSeed = 0;
  late AnimationController _charCtrl;

  @override
  void initState() {
    super.initState();

    // ── Glow pulse ───────────────────────────────────────────
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);

    _glowAnim = CurvedAnimation(
      parent: _glowCtrl,
      curve: Curves.easeInOut,
    );

    // ── Scanline sweep ───────────────────────────────────────
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    _scanAnim = CurvedAnimation(
      parent: _scanCtrl,
      curve: Curves.linear,
    );

    // ── Flicker ──────────────────────────────────────────────
    _flickerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );

    _flickerAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1, end: 0.4), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 0.4, end: 1), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 30),
    ]).animate(_flickerCtrl);

    _scheduleFlicker();

    // ── Char shift ───────────────────────────────────────────
    _charCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _charCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _charSeed++);
      }
    });
  }

  void _scheduleFlicker() {
    final delay = 3000 + math.Random().nextInt(5000); // 3–8 s random
    Future.delayed(Duration(milliseconds: delay), () {
      if (!mounted) return;
      _flickerCtrl.forward(from: 0).then((_) => _scheduleFlicker());
    });
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    _scanCtrl.dispose();
    _flickerCtrl.dispose();
    _charCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _glowAnim,
        _scanAnim,
        _flickerAnim,
      ]),
      builder: (context, _) {
        // Combine glow + flicker into one brightness multiplier
        final brightness =
            0.65 + _glowAnim.value * 0.35 + _flickerAnim.value * 0.25;

        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: _BinaryWrenchPainter(
              size: widget.size,
              brightness: brightness.clamp(0.0, 1.0),
              scanlineY: widget.showScanline ? _scanAnim.value : -1,
              charSeed: _charSeed,
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  _BinaryWrenchPainter
// ═══════════════════════════════════════════════════════════════════

class _BinaryWrenchPainter extends CustomPainter {
  final double size;
  final double brightness;   // 0.0–1.0
  final double scanlineY;    // 0.0–1.0, -1 = hidden
  final int charSeed;

  // Cached wrench cell grid — rebuilt only when size changes
  static List<Offset>? _cachedCells;
  static double _cachedSize = 0;

  _BinaryWrenchPainter({
    required this.size,
    required this.brightness,
    required this.scanlineY,
    required this.charSeed,
  });

  // ── Wrench geometry (design space = size × size) ────────────
  static const double _headCxRatio  = 0.275;
  static const double _headCyRatio  = 0.275;
  static const double _rOutRatio    = 0.185;
  static const double _rInRatio     = 0.090;
  static const double _jawHalfDeg   = 33.0;
  static const double _jawAngleDeg  = -135.0; // top-left
  static const double _shaftWRatio  = 0.090;
  static const double _tailWRatio   = 0.140;
  static const double _tailHRatio   = 0.085;

  bool _pointInWrench(double px, double py) {
    final hcx   = size * _headCxRatio;
    final hcy   = size * _headCyRatio;
    final rOut  = size * _rOutRatio;
    final rIn   = size * _rInRatio;
    const jawH  = _jawHalfDeg  * math.pi / 180;
    const jawA  = _jawAngleDeg * math.pi / 180;

    // ── Head donut check ────────────────────────────────────
    final dx = px - hcx;
    final dy = py - hcy;
    final dist = math.sqrt(dx * dx + dy * dy);

    if (dist >= rIn && dist <= rOut) {
      // In the ring — check it's not in the jaw gap
      double angle = math.atan2(dy, dx);
      // Normalise angle relative to jaw axis
      double rel = angle - jawA;
      // Wrap to -π…π
      while (rel >  math.pi) {
        rel -= 2 * math.pi;
      }
      while (rel < -math.pi) {
        rel += 2 * math.pi;
      }
      if (rel.abs() > jawH) return true;
    }

    // ── Jaw tip caps ────────────────────────────────────────
    final midR  = (rOut + rIn) / 2;
    final tipR  = (rOut - rIn) / 2;
    for (final ang in [jawA + jawH, jawA - jawH]) {
      final tcx = hcx + math.cos(ang) * midR;
      final tcy = hcy + math.sin(ang) * midR;
      final ddx = px - tcx;
      final ddy = py - tcy;
      if (ddx * ddx + ddy * ddy <= tipR * tipR) return true;
    }

    // ── Handle (rotated AABB) ────────────────────────────────
    final shaftW      = size * _shaftWRatio;
    final shaftStart  = rIn + size * 0.01;
    final shaftEnd    = shaftStart + size * 0.590;
    const angle45     = math.pi / 4;

    // Rotate point into shaft-local space (aligned along 45° axis)
    final rdx = px - hcx;
    final rdy = py - hcy;
    final lx  = rdx * math.cos(-angle45) - rdy * math.sin(-angle45);
    final ly  = rdx * math.sin(-angle45) + rdy * math.cos(-angle45);

    if (lx >= shaftStart && lx <= shaftEnd &&
        ly >= -shaftW / 2 && ly <= shaftW / 2) {
      return true;
    }

    // ── Tail (rounded rect at far end of shaft) ─────────────
    final tailDist = shaftStart + size * 0.590;
    final tailCx   = hcx + math.cos(angle45) * tailDist;
    final tailCy   = hcy + math.sin(angle45) * tailDist;
    final tailW    = size * _tailWRatio;
    final tailH    = size * _tailHRatio;

    final tdx  = px - tailCx;
    final tdy  = py - tailCy;
    final tlx  = tdx * math.cos(-angle45) - tdy * math.sin(-angle45);
    final tly  = tdx * math.sin(-angle45) + tdy * math.cos(-angle45);

    if (tlx >= -tailW / 2 && tlx <= tailW / 2 &&
        tly >= -tailH / 2 && tly <= tailH / 2) {
      return true;
    }

    return false;
  }

  // Build or reuse the cell grid
  List<Offset> _getCells() {
    if (_cachedCells != null && _cachedSize == size) return _cachedCells!;

    const cellSize = 9.5; // density of 1/0 grid (logical pixels)
    final cells = <Offset>[];

    final cols = (size / cellSize).ceil() + 2;
    final rows = (size / cellSize).ceil() + 2;

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final cx = c * cellSize + cellSize * 0.5;
        final cy = r * cellSize + cellSize * 0.5;

        // Sample 9 points — majority vote
        const s = cellSize * 0.28;
        int hits = 0;
        for (final d in [
          [0.0, 0.0],
          [s, 0.0], [-s, 0.0], [0.0, s], [0.0, -s],
          [s, s], [-s, s], [s, -s], [-s, -s],
        ]) {
          if (_pointInWrench(cx + d[0], cy + d[1])) hits++;
        }
        if (hits >= 5) cells.add(Offset(cx, cy));
      }
    }

    _cachedCells = cells;
    _cachedSize  = size;
    return cells;
  }

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final cells = _getCells();

    // ── Gradient: cyan → violet → teal ──────────────────────
    // Boost colour channels by brightness multiplier
    Color lerp(Color c, double t) {
      return Color.fromARGB(
        255,
        (c.red   * t).round().clamp(0, 255),
        (c.green * t).round().clamp(0, 255),
        (c.blue  * t).round().clamp(0, 255),
      );
    }

    final cCyan   = lerp(const Color(0xFF40DFFF), brightness);
    final cViolet = lerp(const Color(0xFF8B78FF), brightness);
    final cTeal   = lerp(const Color(0xFF00FFD6), brightness);

    final grad = LinearGradient(
      begin: Alignment.topLeft,
      end:   Alignment.bottomRight,
      colors: [cCyan, cViolet, cTeal],
      stops: const [0.0, 0.45, 1.0],
    ).createShader(Rect.fromLTWH(0, 0, size, size));

    // ── Text style ───────────────────────────────────────────
    const cellSize = 9.5;
    final fontSize = (cellSize * 0.84).clamp(6.0, 12.0);

    // glow pass paint
    final glowPaint = Paint()
      ..color = Colors.transparent; // used via canvas.drawParagraph

    // We'll use TextPainter per character for proper gradient + shadow

    // Build a single TextPainter factory
    TextPainter makeChar(String ch, {bool isGlow = false, Color? glowColor}) {
      return TextPainter(
        text: TextSpan(
          text: ch,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            fontFamily: 'Courier New',
            foreground: isGlow
                ? (Paint()
              ..color = (glowColor ?? const Color(0xFF40DFFF))
                  .withOpacity(0.6)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal,
                  3.0 * brightness))
                : (Paint()..shader = grad),
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
    }

    final scanTop    = scanlineY * size;
    final scanHeight = size * 0.08; // scanline influence band

    for (int i = 0; i < cells.length; i++) {
      final cell = cells[i];
      // Checkerboard + seed shift
      final row = (cell.dy / cellSize).round();
      final col = (cell.dx / cellSize).round();
      final ch  = (row + col + charSeed) % 2 == 0 ? '1' : '0';

      // Scanline brightness boost
      double scanBoost = 0;
      if (scanlineY >= 0) {
        final dist = (cell.dy - scanTop).abs();
        if (dist < scanHeight) {
          scanBoost = (1 - dist / scanHeight) * 0.5;
        }
      }

      // Alternate glow colour per character for depth
      final glowCol = col % 3 == 0
          ? const Color(0xFF8B78FF)
          : const Color(0xFF40DFFF);

      // Glow pass
      final glowChar = makeChar(ch, isGlow: true, glowColor: glowCol);
      glowChar.paint(
        canvas,
        Offset(cell.dx - glowChar.width / 2,
            cell.dy - glowChar.height / 2),
      );

      // If near scanline, paint an extra bright pass
      if (scanBoost > 0.05) {
        final brightPaint = Paint()
          ..color = Colors.white.withOpacity(scanBoost * brightness * 0.9)
          ..maskFilter =
          MaskFilter.blur(BlurStyle.normal, 2 * scanBoost);
        final scanChar = TextPainter(
          text: TextSpan(
            text: ch,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              fontFamily: 'Courier New',
              foreground: brightPaint,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        scanChar.paint(
          canvas,
          Offset(cell.dx - scanChar.width / 2,
              cell.dy - scanChar.height / 2),
        );
      }

      // Crisp gradient pass on top
      final mainChar = makeChar(ch);
      mainChar.paint(
        canvas,
        Offset(cell.dx - mainChar.width / 2,
            cell.dy - mainChar.height / 2),
      );
    }

    // ── Scanline streak ──────────────────────────────────────
    if (scanlineY >= 0 && scanlineY < 1.0) {
      final scanPaint = Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            const Color(0xFF00C3FF).withOpacity(0.55 * brightness),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(0, 0, size, size))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);

      canvas.drawRect(
        Rect.fromLTWH(0, scanTop - 1, size, 2.5),
        scanPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_BinaryWrenchPainter old) =>
      old.brightness != brightness ||
          old.scanlineY  != scanlineY  ||
          old.charSeed   != charSeed;
}