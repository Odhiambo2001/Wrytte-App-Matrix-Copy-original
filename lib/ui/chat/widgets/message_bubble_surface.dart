import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Wrytte's proven unified body-and-tail surface from the original chat UI.
///
/// The body and tail are one path, so a tail-bearing message cannot expose the
/// wallpaper through its body or develop a seam between the two shapes.
class MessageBubbleSurface extends StatelessWidget {
  const MessageBubbleSurface({
    super.key,
    required this.isMine,
    required this.showTail,
    required this.color,
    required this.child,
    this.radius = defaultRadius,
  });

  static const double tailExtent = 8;
  static const double defaultRadius = 18;

  final bool isMine;
  final bool showTail;
  final Color color;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final tailOnRight = switch ((direction, isMine)) {
      (TextDirection.ltr, true) || (TextDirection.rtl, false) => true,
      _ => false,
    };
    return CustomPaint(
      painter: _MessageBubbleSurfacePainter(
        tailOnRight: tailOnRight,
        showTail: showTail,
        color: color,
        radius: radius,
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: showTail && !tailOnRight ? tailExtent : 0,
          right: showTail && tailOnRight ? tailExtent : 0,
        ),
        child: child,
      ),
    );
  }
}

class _MessageBubbleSurfacePainter extends CustomPainter {
  const _MessageBubbleSurfacePainter({
    required this.tailOnRight,
    required this.showTail,
    required this.color,
    required this.radius,
  });

  final bool tailOnRight;
  final bool showTail;
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final fillPath = _WrytteMessageBubblePath.create(
      size: size,
      tailOnRight: tailOnRight,
      showTail: showTail,
      strokeInset: 0,
      radius: radius,
    );
    canvas.drawPath(
      fillPath,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.fill
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _MessageBubbleSurfacePainter oldDelegate) {
    return oldDelegate.tailOnRight != tailOnRight ||
        oldDelegate.showTail != showTail ||
        oldDelegate.color != color ||
        oldDelegate.radius != radius;
  }
}

class _WrytteMessageBubblePath {
  static const double _templateDiameter = 33;
  static const double _bottomEllipseLeftInset = 10.5;
  static const double _bottomEllipseWidth = 30;
  static const double _bottomEllipseHeight = 17;
  static const double _innerEllipseWidth = 22;
  static const double _innerEllipseHeight = 20;
  static const double _bridgeWidth = 18;
  static const double _bridgeTopInset = 17;
  static const double _bridgeBottomInset = 8;

  static Path create({
    required Size size,
    required bool tailOnRight,
    required bool showTail,
    required double strokeInset,
    required double radius,
  }) {
    if (size.isEmpty) return Path();
    if (!showTail) {
      return _roundedBody(
        Rect.fromLTRB(
          strokeInset,
          strokeInset,
          size.width - strokeInset,
          size.height - strokeInset,
        ),
        radius,
      );
    }

    final outgoingPath = _createRightTailBubble(
      size: size,
      strokeInset: strokeInset,
      radius: radius,
    );
    if (tailOnRight) return outgoingPath;

    return outgoingPath.transform(
      Float64List.fromList(<double>[
        -1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        size.width,
        0,
        0,
        1,
      ]),
    );
  }

  static Path _createRightTailBubble({
    required Size size,
    required double strokeInset,
    required double radius,
  }) {
    final availableWidth = math.max(0.0, size.width - strokeInset * 2);
    final availableHeight = math.max(0.0, size.height - strokeInset * 2);
    if (availableWidth <= 0 || availableHeight <= 0) return Path();

    final tailScale = math.min(1.0, availableHeight / _templateDiameter);
    final reservedTail = math.min(
      MessageBubbleSurface.tailExtent,
      math.max(0.0, availableWidth - 1),
    );
    final bodyRect = Rect.fromLTRB(
      strokeInset,
      strokeInset,
      size.width - strokeInset - reservedTail,
      size.height - strokeInset,
    );
    if (bodyRect.width <= 0 || bodyRect.height <= 0) return Path();

    final bodyPath = _roundedBody(bodyRect, radius);
    final bodyRight = bodyRect.right;
    final bottom = bodyRect.bottom;
    final bottomEllipse = Rect.fromLTWH(
      bodyRight - (_bottomEllipseLeftInset * tailScale),
      bottom - (_bottomEllipseHeight * tailScale),
      _bottomEllipseWidth * tailScale,
      _bottomEllipseHeight * tailScale,
    );
    final lowerLobe = Path()
      ..moveTo(bottomEllipse.left, bottomEllipse.center.dy)
      ..quadraticBezierTo(
        bottomEllipse.left,
        bottomEllipse.bottom,
        bottomEllipse.center.dx,
        bottomEllipse.bottom,
      )
      ..quadraticBezierTo(
        bottomEllipse.right,
        bottomEllipse.bottom,
        bottomEllipse.right,
        bottomEllipse.center.dy,
      )
      ..close();
    final bridge = Path()
      ..addRect(
        Rect.fromLTRB(
          bodyRight - (_bridgeWidth * tailScale),
          bottom - (_bridgeTopInset * tailScale),
          bodyRight,
          bottom - (_bridgeBottomInset * tailScale),
        ),
      );

    var combined = Path.combine(PathOperation.union, bodyPath, lowerLobe);
    combined = Path.combine(PathOperation.union, combined, bridge);
    final innerCutout = Path()
      ..addOval(
        Rect.fromLTWH(
          bodyRight,
          bottom - (19 * tailScale),
          _innerEllipseWidth * tailScale,
          _innerEllipseHeight * tailScale,
        ),
      );
    return Path.combine(PathOperation.difference, combined, innerCutout);
  }

  static Path _roundedBody(Rect rect, double requestedRadius) {
    if (rect.width <= 0 || rect.height <= 0) return Path();
    final radius = Radius.circular(
      math.min(requestedRadius, math.min(rect.width / 2, rect.height / 2)),
    );
    return Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
  }
}
