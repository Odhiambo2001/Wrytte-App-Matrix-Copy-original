import 'package:flutter/material.dart';

const _welcomeTitleStyle = TextStyle(
  fontFamily: 'Inter',
  fontSize: 26,
  fontWeight: FontWeight.w600,
  height: 1.2,
  letterSpacing: 0,
  color: Color(0xFFF2F2F2),
);

const _welcomeDescriptionStyle = TextStyle(
  inherit: false,
  fontFamily: 'Inter',
  fontSize: 14,
  fontWeight: FontWeight.normal,
  height: 1.4,
  letterSpacing: 0,
  color: Colors.white,
);

class WelcomeIntro extends StatelessWidget {
  const WelcomeIntro({
    super.key,
    required this.compact,
    required this.descriptionWidth,
  });

  final bool compact;
  final double descriptionWidth;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Center(child: _WrytteLogo()),
      SizedBox(height: compact ? 32 : 68),
      const Text(
        'Welcome to Wrytte',
        textAlign: TextAlign.center,
        style: _welcomeTitleStyle,
      ),
      const SizedBox(height: 24),
      Center(child: _WelcomeDescription(width: descriptionWidth)),
    ],
  );
}

class _WelcomeDescription extends StatelessWidget {
  const _WelcomeDescription({required this.width});

  final double width;
  static const _reference =
      'A secure social messenger for chatting,\n'
      'sharing moments, creating communities, and\n'
      'staying connected with the people who\n'
      'matter most.';

  @override
  Widget build(BuildContext context) {
    final measurement = TextPainter(
      text: const TextSpan(text: _reference, style: _welcomeDescriptionStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    final fitsReference = measurement.width <= width;
    measurement.dispose();
    return SizedBox(
      width: width,
      child: Text(
        fitsReference ? _reference : _reference.replaceAll('\n', ' '),
        key: const ValueKey('welcome-description'),
        textAlign: TextAlign.center,
        style: _welcomeDescriptionStyle,
      ),
    );
  }
}

class _WrytteLogo extends StatelessWidget {
  const _WrytteLogo();

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
    child: SizedBox.square(
      dimension: 84,
      child: CustomPaint(painter: _WrytteLogoPainter()),
    ),
  );
}

class _WrytteLogoPainter extends CustomPainter {
  const _WrytteLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 88, size.height / 88);

    final letter = Path()
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

    final paint = Paint()..color = const Color(0xFFF2F2F2);
    canvas
      ..drawPath(letter, paint)
      ..drawPath(letter.shift(const Offset(34, 0)), paint)
      ..drawCircle(const Offset(77, 8), 6, Paint()..color = const Color(0xFFFF5E5E))
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _WrytteLogoPainter oldDelegate) => false;
}
