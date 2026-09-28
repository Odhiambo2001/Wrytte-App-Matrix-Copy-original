import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class KfaceIllustration extends StatelessWidget {
  const KfaceIllustration({super.key, this.size = 112});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: const CustomPaint(painter: _KfacePainter()),
    );
  }
}

class _KfacePainter extends CustomPainter {
  const _KfacePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / 100, size.height / 100);
    final paint = Paint()
      ..color = WrytteColors.textPrimary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final frame = Path()
      ..moveTo(32, 7)
      ..quadraticBezierTo(7, 7, 7, 32)
      ..moveTo(68, 7)
      ..quadraticBezierTo(93, 7, 93, 32)
      ..moveTo(7, 68)
      ..quadraticBezierTo(7, 93, 32, 93)
      ..moveTo(93, 68)
      ..quadraticBezierTo(93, 93, 68, 93);
    final person = Path()
      ..moveTo(25, 74)
      ..quadraticBezierTo(25, 62, 42, 60)
      ..lineTo(42, 53)
      ..cubicTo(30, 42, 35, 23, 50, 23)
      ..cubicTo(65, 23, 70, 42, 58, 53)
      ..lineTo(58, 60)
      ..quadraticBezierTo(75, 62, 75, 74);
    canvas
      ..drawPath(frame, paint)
      ..drawPath(person, paint)
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _KfacePainter oldDelegate) => false;
}
