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
    this.waiting = false,
    this.success = false,
    this.failure = false,
  });

  final double faceDiameter;
  final bool showTicks;
  final bool scanning;
  final double progress;
  final double movement;
  final bool waiting;
  final bool success;
  final bool failure;

  @override
  State<KFaceScanOverlay> createState() => _KFaceScanOverlayState();
}

class _KFaceScanOverlayState extends State<KFaceScanOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  );
  // Throttles the [ScanMotion] diagnostic log to ~10 lines/sec instead of
  // once per animation frame (60/sec), so it's readable and cheap to leave
  // in during testing.
  final Stopwatch _logStopwatch = Stopwatch()..start();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(covariant KFaceScanOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.waiting && !oldWidget.waiting) {
      _motion
        ..stop()
        ..value = 0
        ..repeat();
    }
    _updateMotion();
  }

  void _updateMotion() {
    if ((widget.scanning || widget.waiting) &&
        !MediaQuery.disableAnimationsOf(context)) {
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
              builder: (context, child) {
                // The ribbon's rotation is driven only by _motion — a
                // continuous, constant-speed clock — never by capture
                // progress. Previously `progress * 2π` was added here,
                // which made the sweep advance in a fast burst each time a
                // candidate was accepted (via the easeOut tween above), then
                // sit almost still until the next candidate was accepted.
                // Since acceptance timing depends on the network/backend,
                // that produced visible "stuck on rotation 2/3/4" stalls
                // that had nothing to do with animation math.
                final phase = _motion.value * math.pi * 2;
                if (widget.scanning &&
                    !widget.waiting &&
                    _logStopwatch.elapsedMilliseconds >= 100) {
                  _logStopwatch.reset();
                  final longitude =
                      _ScanOverlayPainter._sweepAngle(phase, 0.95) +
                      (widget.movement - 0.5) * 0.18;
                  debugPrint(
                    '[ScanMotion] t=${DateTime.now().millisecondsSinceEpoch} '
                    'motion=${_motion.value.toStringAsFixed(4)} '
                    'phase=${phase.toStringAsFixed(3)} '
                    'longitude=${longitude.toStringAsFixed(3)}',
                  );
                }
                return CustomPaint(
                  painter: _ScanOverlayPainter(
                    faceDiameter: widget.faceDiameter,
                    showTicks: widget.showTicks,
                    scanning: widget.scanning && !reduceMotion,
                    progress: progress,
                    movement: widget.movement,
                    waiting: widget.waiting,
                    success: widget.success,
                    failure: widget.failure,
                    phase: phase,
                  ),
                  child: const SizedBox.expand(),
                );
              },
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
    required this.waiting,
    required this.success,
    required this.failure,
    required this.phase,
  });

  final double faceDiameter;
  final bool showTicks;
  final bool scanning;
  final double progress;
  final double movement;
  final bool waiting;
  final bool success;
  final bool failure;
  final double phase;

  /// Converts a phase angle into a constant-speed triangle wave in [-1, 1].
  /// A raw sin(phase) mapping decelerates to zero speed at its extremes
  /// (derivative cos(phase) -> 0), which reads as the sweep "hanging" at
  /// the edges. asin(sin(phase)) is linear in phase almost everywhere,
  /// producing uniform sweep speed with only an instantaneous turnaround
  /// at each edge instead of a visible stall.
  static double _triangleWave(double phase) =>
      (2 / math.pi) * math.asin(math.sin(phase));

  /// The meridian angle is fed through sin() a second time inside point()
  /// (`sweep = sin(meridian) * depth`) to project it onto the sphere. That
  /// second sine has its own deceleration near the sweep's extremes, most
  /// noticeable during the very first excursion away from center. Pre-warp
  /// the meridian with asin so the *projected* screen position — not just
  /// the angle — advances at constant speed.
  static double _sweepAngle(double phase, double maxAngle) {
    final linear = _triangleWave(phase) * math.sin(maxAngle);
    return math.asin(linear.clamp(-1.0, 1.0));
  }

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
          ..color =
              failure
                  ? const Color(0xFFFF4655)
                  : success
                  ? const Color(0xFF18D85B)
                  : const Color(0xFFF5F5F5)
          ..strokeWidth = 3,
      );
      if (!scanning && !waiting && !success) return;
    }

    const count = 72;
    if (showTicks) {
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
    }

    if (success) {
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

    if (waiting) {
      final arcPaint =
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xFF18D85B);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius + 3.5),
        -math.pi / 2,
        (phase / (math.pi * 2)).clamp(0.0, 1.0) * math.pi * 2,
        false,
        arcPaint,
      );
      return;
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
            // _sweepAngle pre-compensates for the sin() applied again inside
            // point() below, so the actual on-screen sweep position moves at
            // constant speed with no deceleration at the extremes or during
            // the first excursion away from center.
            ? _sweepAngle(phase, 0.95) + (movement - 0.5) * 0.18
            : _sweepAngle(phase + math.pi / 2, 0.65);
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
        Color(0xFF1565D8),
        Color(0xFF258BFF),
        Color(0xFFEAF4FF),
        Color(0xFF4AA3FF),
      ],
      stops: const [0, 0.35, 0.68, 1],
    ).createShader(bounds);

    // One soft halo behind the entire sheet keeps the fine gaps crisp.
    canvas.drawPath(
      strip(longitude, longitude + spread),
      Paint()
        ..color = const Color(0xFF1976FF).withValues(alpha: 0.18)
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
      oldDelegate.waiting != waiting ||
      oldDelegate.success != success ||
      oldDelegate.failure != failure ||
      oldDelegate.phase != phase;
}
