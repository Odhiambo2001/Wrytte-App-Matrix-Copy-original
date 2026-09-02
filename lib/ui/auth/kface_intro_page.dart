import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/ui/auth/kface_scan_page.dart';

class KFaceIntroPage extends StatefulWidget {
  final String wrytteId;
  final KFaceRecoveryData? recoveryData;

  const KFaceIntroPage({super.key, required this.wrytteId, this.recoveryData});

  @override
  State<KFaceIntroPage> createState() => _KFaceIntroPageState();
}

class _KFaceIntroPageState extends State<KFaceIntroPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111217),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(28, 10, 28, 18),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 28,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Color(0xFFE8E9ED),
                            size: 28,
                          ),
                        ),
                      ),
                      const SizedBox(height: 45),
                      const SizedBox.square(
                        dimension: 240,
                        child: CustomPaint(painter: _KFacePainter()),
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'How to Log In to Kface',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Position your face in the camera\nframe, then look directly at the\ncamera to recover your key.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF85878F),
                          fontSize: 18,
                          height: 1.32,
                        ),
                      ),
                      const SizedBox(height: 58),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder:
                                    (_) => KFaceScanPage(
                                      wrytteId: widget.wrytteId,
                                      recoveryData: widget.recoveryData,
                                    ),
                              ),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4285DF),
                            disabledBackgroundColor: const Color(0xFF23262C),
                            foregroundColor: Colors.white,
                            disabledForegroundColor: Colors.white38,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                          ),
                          child: const Text(
                            'Get Started',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _KFacePainter extends CustomPainter {
  const _KFacePainter();

  static const _ink = Color(0xFFC7CBD5);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = size.shortestSide / 240;

    final tickPaint =
        Paint()
          ..color = _ink
          ..strokeWidth = 6 * scale
          ..strokeCap = StrokeCap.round;
    const tickCount = 52;
    final innerTickRadius = 99 * scale;
    final outerTickRadius = 113 * scale;
    for (var index = 0; index < tickCount; index++) {
      final angle = (2 * math.pi * index / tickCount) - math.pi / 2;
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * innerTickRadius,
        center + Offset(math.cos(angle), math.sin(angle)) * outerTickRadius,
        tickPaint,
      );
    }

    final ringPaint =
        Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6 * scale;
    canvas.drawCircle(center, 61 * scale, ringPaint);

    final facePaint = Paint()..color = _ink;
    canvas.drawCircle(center, 31 * scale, facePaint);

    final featurePaint = Paint()..color = const Color(0xFF111217);
    canvas.drawCircle(
      center.translate(-11 * scale, -7 * scale),
      4.5 * scale,
      featurePaint,
    );
    canvas.drawCircle(
      center.translate(11 * scale, -7 * scale),
      4.5 * scale,
      featurePaint,
    );

    final mouthPath =
        Path()
          ..moveTo(center.dx - 15 * scale, center.dy + 5 * scale)
          ..quadraticBezierTo(
            center.dx,
            center.dy + 23 * scale,
            center.dx + 15 * scale,
            center.dy + 5 * scale,
          )
          ..close();
    canvas.drawPath(mouthPath, featurePaint);
  }

  @override
  bool shouldRepaint(covariant _KFacePainter oldDelegate) => false;
}
