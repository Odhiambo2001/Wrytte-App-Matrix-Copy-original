import 'package:flutter/material.dart';

/// The branding and copy shown on the Wrytte welcome page.
class WelcomeIntro extends StatelessWidget {
  const WelcomeIntro({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _TtMark(),
      SizedBox(height: 68),
      Text(
        'Welcome to Wrytte',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: 28,
          height: 1.1,
          fontWeight: FontWeight.w600,
        ),
      ),
      SizedBox(height: 24),
      SizedBox(
        width: 328,
        child: Text(
          'A secure social messenger for chatting,\n'
          'sharing moments, creating communities, and\n'
          'staying connected with the people who\n'
          'matter most.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: 17, height: 1.35),
        ),
      ),
    ],
  );
}

class _TtMark extends StatelessWidget {
  const _TtMark();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 86,
    height: 84,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        const Positioned(
          left: 0,
          bottom: 0,
          child: Text(
            'tt',
            style: TextStyle(
              color: Colors.white,
              fontSize: 78,
              height: .8,
              fontWeight: FontWeight.w900,
              letterSpacing: -12,
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 0,
          child: Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: Color(0xFFFF5964),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    ),
  );
}
