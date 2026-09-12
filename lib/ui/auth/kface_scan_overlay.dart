import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Decorative scan motion; only accepted capture progress colors the ticks.
class KFaceScanOverlay extends StatefulWidget {
  const KFaceScanOverlay({
    super.key,
    required this.faceDiameter,
    required this.showTicks,
    required this.scanning,
    required this.progress,
    this.movement = 0.5,
  });

  final double faceDiameter;
  final bool showTicks;
  final bool scanning;
  final double progress;
  final double movement;

  @override
  State<KFaceScanOverlay> createState() => _KFaceScanOverlayState();
}

class _KFaceScanOverlayState extends State<KFaceScanOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(covariant KFaceScanOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  void _updateMotion() {
    if (widget.scanning && !MediaQuery.disableAnimationsOf(context)) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
      if (!widget.showTicks) _motion.value = 0;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: widget.progress.clamp(0.0, 1.0)),
        duration:
            reduceMotion ? Duration.zero : const Duration(milliseconds: 450),
        curve: Curves.easeOut,
        builder:
            (context, progress, child) => AnimatedBuilder(
              animation: _motion,
              builder:
                  (context, child) => CustomPaint(
                    painter: _ScanOverlayPainter(
                      faceDiameter: widget.faceDiameter,
                      showTicks: widget.showTicks,
                      scanning: widget.scanning && !reduceMotion,
                      progress: progress,
                      movement: widget.movement,
                      // Capture progress is driven by valid head movement. The small
                      // time component keeps the light alive between accepted frames.
                      phase:
                          progress * math.pi * 2 + _motion.value * math.pi * 2,
                    ),
                    child: const SizedBox.expand(),
                  ),
            ),
      ),
    );
  }
}

class _ScanOverlayPainter extends CustomPainter {
  const _ScanOverlayPainter({
    required this.faceDiameter,
    required this.showTicks,
    required this.scanning,
    required this.progress,
    required this.movement,
    required this.phase,
  });

  final double faceDiameter;
  final bool showTicks;
  final bool scanning;
  final double progress;
  final double movement;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = faceDiameter / 2;
    final paint = Paint()..style = PaintingStyle.stroke;
    if (!showTicks) {
      canvas.drawCircle(
        center,
        radius + 3.5,
        paint
          ..color = const Color(0xFF999999)
          ..strokeWidth = 3,
      );
      return;
    }

    const count = 72;
    for (var index = 0; index < count; index++) {
      // Begin on the right, then advance clockwise, as in the reference.
      final angle = 2 * math.pi * index / count;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final filled = (progress * count - index).clamp(0.0, 1.0);
      paint
        ..color =
            Color.lerp(
              const Color(0xFF999999),
              const Color(0xFF32E875),
              filled,
            )!
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        center + direction * (radius + 5),
        center + direction * (radius + 10 + filled * 7),
        paint,
      );
    }

    if (progress >= 0.999) {
      final check =
          Path()
            ..moveTo(center.dx - radius * 0.22, center.dy + radius * 0.02)
            ..lineTo(center.dx - radius * 0.06, center.dy + radius * 0.18)
            ..lineTo(center.dx + radius * 0.27, center.dy - radius * 0.20);
      canvas.drawPath(
        check,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xFF32E875),
      );
    }

    if (!scanning) return;
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    // Project two perpendicular ribbons onto a sphere. Their front halves
    // sweep over the live preview while their back halves remain hidden.
    _drawRibbon(canvas, center, radius, vertical: true);
    canvas.restore();
  }

  void _drawRibbon(
    Canvas canvas,
    Offset center,
    double radius, {
    required bool vertical,
  }) {
    // A fan of meridians, not a thick stroked arc: the lines converge at
    // the poles and spread across the face, producing the ribbed light sheet.
    final longitude =
        vertical
            // This is a UI scan: it sweeps left and right continuously even
            // when the head is still. Face position adds a small offset.
            ? math.sin(phase) * 0.95 + (movement - 0.5) * 0.18
            : math.cos(phase) * 0.65;
    const spread = 0.42;
    const ribs = 28;
    const steps = 80;

    Offset point(double latitude, double meridian) {
      final across = math.sin(latitude) * radius;
      final depth = math.cos(latitude) * radius;
      final sweep = math.sin(meridian) * depth;
      return center +
          (vertical ? Offset(sweep, across) : Offset(across, sweep));
    }

    Path meridian(double angle) {
      final path = Path();
      for (var i = 0; i <= steps; i++) {
        final p = point(-math.pi / 2 + math.pi * i / steps, angle);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path;
    }

    Path strip(double start, double end) {
      final path = meridian(start);
      for (var i = steps; i >= 0; i--) {
        final p = point(-math.pi / 2 + math.pi * i / steps, end);
        path.lineTo(p.dx, p.dy);
      }
      return path..close();
    }

    final bounds = Rect.fromCircle(center: center, radius: radius);
    final gradient = LinearGradient(
      begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
      end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
      colors: const [
        Color(0xFF62FFE4),
        Color(0xFF9FFFF3),
        Color(0xFFF1FFFF),
        Color(0xFF84FFE9),
      ],
      stops: const [0, 0.35, 0.68, 1],
    ).createShader(bounds);

    // One soft halo behind the entire sheet keeps the fine gaps crisp.
    canvas.drawPath(
      strip(longitude, longitude + spread),
      Paint()
        ..color = const Color(0xFF6EFFE2).withValues(alpha: 0.15)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.018),
    );
    for (var rib = 0; rib < ribs; rib++) {
      final fraction = rib / ribs;
      final angle = longitude + spread * fraction;
      final next = longitude + spread * (rib + 1) / ribs;
      final fade = math.pow(1 - fraction, 1.4).toDouble();
      // Translucent body plus discrete luminous ribs; the camera is visible
      // through both the sheet and the spaces between its parallel lines.
      canvas.drawPath(
        strip(angle, next),
        Paint()
          ..shader = gradient
          ..color = Colors.white.withValues(alpha: 0.32 * fade),
      );
      canvas.drawPath(
        meridian(angle),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 0.0045
          ..shader = gradient
          ..color = Colors.white.withValues(alpha: 0.92 * fade),
      );
    }
    canvas.drawPath(
      meridian(longitude),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.007
        ..shader = gradient
        ..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(covariant _ScanOverlayPainter oldDelegate) =>
      oldDelegate.faceDiameter != faceDiameter ||
      oldDelegate.showTicks != showTicks ||
      oldDelegate.scanning != scanning ||
      oldDelegate.progress != progress ||
      oldDelegate.movement != movement ||
      oldDelegate.phase != phase;
}
