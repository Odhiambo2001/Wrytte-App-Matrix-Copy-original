import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/widgets/wrytte_logo.dart';

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
      const Center(child: WrytteLogo()),
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
