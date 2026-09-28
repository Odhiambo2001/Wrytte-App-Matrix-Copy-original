import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:wrytte/core/theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_logo.dart';

class SplashLogoAnimation extends StatefulWidget {
  const SplashLogoAnimation({
    super.key,
    required this.onCompleted,
    this.animate = true,
  });

  final VoidCallback onCompleted;
  final bool animate;

  static const Duration duration = Duration(milliseconds: 2000);

  @override
  State<SplashLogoAnimation> createState() => _SplashLogoAnimationState();
}

class _SplashLogoAnimationState extends State<SplashLogoAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  _SplashLogoGeometry? _geometry;
  double? _geometryLogoSize;

  bool _started = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: SplashLogoAnimation.duration,
      value: widget.animate ? 0.0 : 1.0,
    )..addStatusListener(_handleAnimationStatus);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (!mounted || status != AnimationStatus.completed) {
      return;
    }

    widget.onCompleted();
  }

  @override
  void didUpdateWidget(covariant SplashLogoAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate && !widget.animate) {
      _controller.value = 1.0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_started) {
      return;
    }

    _started = true;

    if (!widget.animate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        widget.onCompleted();
      });

      return;
    }

    if (MediaQuery.disableAnimationsOf(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        _controller.value = 1.0;
      });

      return;
    }

    _controller.forward();
  }

  _SplashLogoGeometry _geometryFor(double logoSize) {
    if (_geometry == null || _geometryLogoSize != logoSize) {
      _geometry?.dispose();

      _geometry = _SplashLogoGeometry(logoSize);
      _geometryLogoSize = logoSize;
    }

    return _geometry!;
  }

  @override
  void dispose() {
    _geometry?.dispose();
    _controller.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final insets = media.padding;

    const welcomeLogoSize = wrytteBrandDisplaySize;

    final showStaticLogo = !widget.animate || media.disableAnimations;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: math.max(insets.left, insets.right),
        vertical: math.max(insets.top, insets.bottom),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Semantics(
              label: 'Wrytte',
              image: true,
              child: RepaintBoundary(
                key: const ValueKey('splash-animated-artwork'),
                child:
                    showStaticLogo
                        ? const WrytteLogo(size: welcomeLogoSize)
                        : SizedBox(
                          width: double.infinity,
                          height: welcomeLogoSize * 2.25,
                          child: CustomPaint(
                            painter: _SplashLogoPainter(
                              animation: _controller,
                              geometry: _geometryFor(welcomeLogoSize),
                            ),
                          ),
                        ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

abstract final class _SplashTimeline {
  static const double totalSeconds = 2.0;

  // W / R / Y / E
  static const double outerMotionStart = 0.00;
  static const double outerMotionEnd = 0.52;

  static const double outerScaleStart = 0.00;
  static const double outerScaleEnd = 0.52;

  static const double outerFadeStart = 0.405;
  static const double outerFadeEnd = 0.520;

  // SURVIVING TT
  static const double ttMotionStart = 0.00;
  static const double ttMotionEnd = 1.07;

  // RED DOT
  static const double dotAppear = 0.53;
  static const double dotVisible = 0.55;

  static const double dotFallStart = 0.58;

  static const double dotFirstImpact = 1.00;

  static const double dotLargeApex = 1.15;

  static const double dotSecondLanding = 1.37;

  static const double dotSmallApex = 1.49;

  static const double dotSmallLanding = 1.63;

  static const double dotTinyApex = 1.72;

  static const double dotSettled = 1.88;
}

class _SplashLogoGeometry {
  _SplashLogoGeometry(this.logoSize)
    : scale = logoSize / wrytteLogoReferenceExtent,
      style = TextStyle(
        fontFamily: WrytteTypography.primaryFontFamily,
        fontSize: logoSize,
        fontWeight: FontWeight.w700,
        height: 1,
        letterSpacing: 0,
        color: WrytteColors.textPrimary,
      ) {
    w = _measure('W');
    r = _measure('r');
    y = _measure('y');
    e = _measure('e');

    pairWidth = (wrytteLogoTtRight - wrytteLogoTtLeft) * scale;

    wordWidth = w.width + r.width + y.width + pairWidth + e.width;
  }

  final double logoSize;
  final double scale;
  final TextStyle style;

  late final TextPainter w;
  late final TextPainter r;
  late final TextPainter y;
  late final TextPainter e;

  late final double pairWidth;
  late final double wordWidth;

  TextPainter _measure(String character) {
    return TextPainter(
      text: TextSpan(text: character, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
  }

  void dispose() {
    w.dispose();
    r.dispose();
    y.dispose();
    e.dispose();
  }
}

class _SplashLogoPainter extends CustomPainter {
  _SplashLogoPainter({required this.animation, required this.geometry})
    : super(repaint: animation);

  final Animation<double> animation;
  final _SplashLogoGeometry geometry;

  static const double _wTravelFactor = 0.785;
  static const double _rTravelFactor = 0.320;
  static const double _yTravelFactor = 0.110;
  static const double _eTravelFactor = -0.940;

  static const Curve _outerMotionCurve = Curves.easeInCubic;
  static const Curve _ttMotionCurve = Curves.easeInOutSine;

  static double _phase(double seconds, double start, double end) {
    if (end <= start) {
      return seconds >= end ? 1.0 : 0.0;
    }

    return ((seconds - start) / (end - start)).clamp(0.0, 1.0).toDouble();
  }

  static double _between(
    double seconds,
    double start,
    double end,
    double from,
    double to,
    Curve curve,
  ) {
    final progress = curve.transform(_phase(seconds, start, end));

    return ui.lerpDouble(from, to, progress)!;
  }

  static double _dotY(double seconds, double restY, double logoSize) {
    final startY = restY - logoSize * 0.62;

    final firstImpactY = restY + logoSize * 0.075;

    final largeApexY = restY - logoSize * 0.34;

    final secondLandingY = restY + logoSize * 0.022;

    final smallApexY = restY - logoSize * 0.13;

    final smallLandingY = restY + logoSize * 0.009;

    final tinyApexY = restY - logoSize * 0.045;

    if (seconds <= _SplashTimeline.dotFallStart) {
      return startY;
    }

    if (seconds <= _SplashTimeline.dotFirstImpact) {
      return _between(
        seconds,
        _SplashTimeline.dotFallStart,
        _SplashTimeline.dotFirstImpact,
        startY,
        firstImpactY,
        Curves.easeInCubic,
      );
    }

    if (seconds <= _SplashTimeline.dotLargeApex) {
      return _between(
        seconds,
        _SplashTimeline.dotFirstImpact,
        _SplashTimeline.dotLargeApex,
        firstImpactY,
        largeApexY,
        Curves.easeOutCubic,
      );
    }

    if (seconds <= _SplashTimeline.dotSecondLanding) {
      return _between(
        seconds,
        _SplashTimeline.dotLargeApex,
        _SplashTimeline.dotSecondLanding,
        largeApexY,
        secondLandingY,
        Curves.easeInCubic,
      );
    }

    if (seconds <= _SplashTimeline.dotSmallApex) {
      return _between(
        seconds,
        _SplashTimeline.dotSecondLanding,
        _SplashTimeline.dotSmallApex,
        secondLandingY,
        smallApexY,
        Curves.easeOutCubic,
      );
    }

    if (seconds <= _SplashTimeline.dotSmallLanding) {
      return _between(
        seconds,
        _SplashTimeline.dotSmallApex,
        _SplashTimeline.dotSmallLanding,
        smallApexY,
        smallLandingY,
        Curves.easeInCubic,
      );
    }

    if (seconds <= _SplashTimeline.dotTinyApex) {
      return _between(
        seconds,
        _SplashTimeline.dotSmallLanding,
        _SplashTimeline.dotTinyApex,
        smallLandingY,
        tinyApexY,
        Curves.easeOutQuad,
      );
    }

    return _between(
      seconds,
      _SplashTimeline.dotTinyApex,
      _SplashTimeline.dotSettled,
      tinyApexY,
      restY,
      Curves.easeInOutSine,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = animation.value * _SplashTimeline.totalSeconds;

    final g = geometry;

    final centre = size.center(Offset.zero);

    final logoOrigin = Offset(
      centre.dx - g.logoSize / 2,
      centre.dy - g.logoSize / 2,
    );

    // INITIAL WRYTTE GEOMETRY

    final wordLeft = centre.dx - g.wordWidth / 2;

    final textTop = centre.dy - g.w.height / 2;

    final wLeft = wordLeft;
    final rLeft = wLeft + g.w.width;
    final yLeft = rLeft + g.r.width;

    final pairPaintLeft = yLeft + g.y.width;

    final eLeft = pairPaintLeft + g.pairWidth;

    final initialPairOrigin = Offset(
      pairPaintLeft - wrytteLogoTtLeft * g.scale,
      logoOrigin.dy,
    );

    // SURVIVING TT

    final ttProgress = _ttMotionCurve.transform(
      _phase(
        seconds,
        _SplashTimeline.ttMotionStart,
        _SplashTimeline.ttMotionEnd,
      ),
    );

    final pairOrigin = Offset.lerp(initialPairOrigin, logoOrigin, ttProgress)!;

    // W / R / Y / E MOVEMENT

    final outerProgress = _outerMotionCurve.transform(
      _phase(
        seconds,
        _SplashTimeline.outerMotionStart,
        _SplashTimeline.outerMotionEnd,
      ),
    );

    final wOffsetX = g.logoSize * _wTravelFactor * outerProgress;

    final rOffsetX = g.logoSize * _rTravelFactor * outerProgress;

    final yOffsetX = g.logoSize * _yTravelFactor * outerProgress;

    final eOffsetX = g.logoSize * _eTravelFactor * outerProgress;

    // OUTER LETTER SCALE

    final scaleProgress = Curves.easeInCubic.transform(
      _phase(
        seconds,
        _SplashTimeline.outerScaleStart,
        _SplashTimeline.outerScaleEnd,
      ),
    );

    final letterScale = ui.lerpDouble(1.0, 0.50, scaleProgress)!;

    // FAST LATE DIMMING

    final fadeProgress = _phase(
      seconds,
      _SplashTimeline.outerFadeStart,
      _SplashTimeline.outerFadeEnd,
    );

    final opacity =
        math
            .pow(1.0 - fadeProgress, 1.30)
            .toDouble()
            .clamp(0.0, 1.0)
            .toDouble();

    void paintOuterLetter(
      TextPainter letter,
      double initialLeft,
      double translateX,
    ) {
      if (opacity <= 0.001) {
        return;
      }

      final originalCentre = Offset(
        initialLeft + letter.width / 2,
        textTop + letter.height / 2,
      );

      final movingCentre = Offset(
        originalCentre.dx + translateX,
        originalCentre.dy,
      );

      canvas.save();

      canvas.translate(movingCentre.dx, movingCentre.dy);

      canvas.scale(letterScale);

      canvas.translate(-letter.width / 2, -letter.height / 2);

      letter.paint(canvas, Offset.zero);

      canvas.restore();
    }

    // DRAW W / R / Y / E

    if (opacity > 0.001) {
      final needsOpacityLayer = opacity < 0.999;

      if (needsOpacityLayer) {
        canvas.saveLayer(
          Rect.fromCenter(
            center: centre,
            width: g.wordWidth * 1.15,
            height: g.logoSize * 1.45,
          ),
          Paint()..color = Colors.white.withValues(alpha: opacity),
        );
      }

      paintOuterLetter(g.w, wLeft, wOffsetX);

      paintOuterLetter(g.r, rLeft, rOffsetX);

      paintOuterLetter(g.y, yLeft, yOffsetX);

      paintOuterLetter(g.e, eLeft, eOffsetX);

      if (needsOpacityLayer) {
        canvas.restore();
      }
    }

    // PERMANENT TT

    canvas.save();

    canvas.translate(pairOrigin.dx, pairOrigin.dy);

    canvas.scale(g.scale);

    paintCanonicalWrytteTt(canvas);

    canvas.restore();

    // RED DOT

    if (seconds >= _SplashTimeline.dotAppear) {
      final dotX = logoOrigin.dx + wrytteLogoDotCenter.dx * g.scale;

      final dotRestY = logoOrigin.dy + wrytteLogoDotCenter.dy * g.scale;

      final dotOpacity = Curves.easeOut.transform(
        _phase(seconds, _SplashTimeline.dotAppear, _SplashTimeline.dotVisible),
      );

      canvas.drawCircle(
        Offset(dotX, _dotY(seconds, dotRestY, g.logoSize)),
        wrytteLogoDotRadius * g.scale,
        Paint()..color = WrytteColors.destructive.withValues(alpha: dotOpacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SplashLogoPainter oldDelegate) {
    return oldDelegate.animation != animation ||
        oldDelegate.geometry != geometry;
  }
}
