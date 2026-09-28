import 'package:flutter/material.dart';

import 'package:wrytte/core/theme.dart';

const double wrytteLogoReferenceExtent = 88;

const double wrytteBrandDisplaySize = 84;

const double wrytteLogoTtLeft = 6;

const double wrytteLogoTtRight = 73;

const Offset wrytteLogoDotCenter = Offset(77, 8);

const double wrytteLogoDotRadius = 6;

/// The final `tt` mark produced by the startup animation.
///
/// This explicit name prevents reduced-motion surfaces from accidentally
/// substituting the full Wrytte wordmark when the morph animation is skipped.
class WrytteTtMark extends StatelessWidget {
  const WrytteTtMark({super.key, this.size = wrytteBrandDisplaySize});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: _WrytteLogoPainter()),
      ),
    );
  }
}

/// Backwards-compatible name used by existing auth surfaces.
class WrytteLogo extends WrytteTtMark {
  const WrytteLogo({super.key, super.size});
}

class _WrytteLogoPainter extends CustomPainter {
  const _WrytteLogoPainter();

  @override
  void paint(Canvas canvas, Size size) =>
      paintCanonicalWrytteLogo(canvas, size);

  @override
  bool shouldRepaint(covariant _WrytteLogoPainter oldDelegate) => false;
}

/// Paints the one canonical TT/red-ball mark.
///
/// The geometry uses the original 88×88 Wrytte coordinate space so the
/// static logo and startup animation always render the same final mark.
void paintCanonicalWrytteLogo(Canvas canvas, Size size, {double opacity = 1}) {
  final safeOpacity = opacity.clamp(0.0, 1.0).toDouble();

  if (safeOpacity <= 0) {
    return;
  }

  canvas.save();

  canvas.scale(
    size.width / wrytteLogoReferenceExtent,
    size.height / wrytteLogoReferenceExtent,
  );

  paintCanonicalWrytteTt(canvas, opacity: safeOpacity);

  canvas.drawCircle(
    wrytteLogoDotCenter,
    wrytteLogoDotRadius,
    Paint()..color = WrytteColors.destructive.withValues(alpha: safeOpacity),
  );

  canvas.restore();
}

/// Paints only the canonical two `t` paths.
///
/// SplashLogoAnimation uses this directly so the same pair of `t`s survives
/// from the initial Wrytte wordmark into the final logo.
void paintCanonicalWrytteTt(Canvas canvas, {double opacity = 1}) {
  final safeOpacity = opacity.clamp(0.0, 1.0).toDouble();

  if (safeOpacity <= 0) {
    return;
  }

  final letter =
      Path()
        ..moveTo(14, 16)
        ..lineTo(26, 16)
        ..lineTo(26, 28)
        ..lineTo(38, 28)
        ..lineTo(38, 38)
        ..lineTo(26, 38)
        ..lineTo(26, 63)
        ..quadraticBezierTo(26, 72, 34, 72)
        ..lineTo(38, 71)
        ..lineTo(39, 81)
        ..quadraticBezierTo(31, 84, 23, 81)
        ..quadraticBezierTo(14, 78, 14, 65)
        ..lineTo(14, 38)
        ..lineTo(6, 38)
        ..lineTo(6, 28)
        ..lineTo(14, 28)
        ..close();

  final paint =
      Paint()..color = WrytteColors.textPrimary.withValues(alpha: safeOpacity);

  canvas.drawPath(letter, paint);

  canvas.drawPath(letter.shift(const Offset(34, 0)), paint);
}
