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
  });

  final double faceDiameter;
  final bool showTicks;
  final bool scanning;
  final double progress;

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
                      phase: _motion.value * math.pi * 2,
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
    required this.phase,
  });

  final double faceDiameter;
  final bool showTicks;
  final bool scanning;
  final double progress;
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

    if (!scanning) return;
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    // Project two perpendicular ribbons onto a sphere. Their front halves
    // sweep over the live preview while their back halves remain hidden.
    _drawRibbon(canvas, center, radius, vertical: false);
    _drawRibbon(canvas, center, radius, vertical: true);
    canvas.restore();
  }

  void _drawRibbon(
    Canvas canvas,
    Offset center,
    double radius, {
    required bool vertical,
  }) {
    final tilt = vertical ? math.sin(phase) * 0.75 : math.cos(phase) * 0.5;
    const steps = 100;
    for (var i = 0; i < steps; i++) {
      Offset point(double t) {
        final across = math.sin(t) * radius;
        final depth = math.cos(t) * radius;
        return center +
            (vertical
                ? Offset(depth * tilt, across)
                : Offset(across, depth * tilt));
      }

      final t = -math.pi / 2 + math.pi * i / steps;
      final next = t + math.pi / steps;
      final depth = math.cos((t + next) / 2);
      final width = 1.0 + depth * radius * 0.075 * (0.35 + tilt.abs());
      final paint =
          Paint()
            ..strokeCap = StrokeCap.round
            ..strokeWidth = width + 5
            ..color = const Color(0xFF52FFE8).withValues(alpha: 0.18 * depth)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawLine(point(t), point(next), paint);
      paint
        ..maskFilter = null
        ..strokeWidth = width
        ..color = const Color(0xFF7FFFF0).withValues(alpha: 0.65 * depth);
      canvas.drawLine(point(t), point(next), paint);
      paint
        ..strokeWidth = 0.8
        ..color = Colors.white.withValues(alpha: 0.8 * depth);
      canvas.drawLine(point(t), point(next), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScanOverlayPainter oldDelegate) =>
      oldDelegate.faceDiameter != faceDiameter ||
      oldDelegate.showTicks != showTicks ||
      oldDelegate.scanning != scanning ||
      oldDelegate.progress != progress ||
      oldDelegate.phase != phase;
}
