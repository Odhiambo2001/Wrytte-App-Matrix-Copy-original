import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class ChatMediaCropRotationDial extends StatefulWidget {
  const ChatMediaCropRotationDial({
    super.key,
    required this.valueDegrees,
    required this.onChanged,
    required this.onChangeEnd,
  });

  static const double height = 76;

  final double valueDegrees;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  State<ChatMediaCropRotationDial> createState() =>
      _ChatMediaCropRotationDialState();
}

class _ChatMediaCropRotationDialState
    extends State<ChatMediaCropRotationDial> {
  static const double _minimumAngle = -80;
  static const double _maximumAngle = 80;

  static const double _pixelsPerDegree = 4;
  static const double _hapticStep = 2.5;

  late double _displayDegrees =
      _clamp(widget.valueDegrees);

  double _dragStartX = 0;
  double _dragStartDegrees = 0;

  int _lastHapticIndex = 0;

  bool _dragging = false;
  bool _dragChanged = false;

  static double _clamp(double value) {
    return value
        .clamp(
          _minimumAngle,
          _maximumAngle,
        )
        .toDouble();
  }

  @override
  void didUpdateWidget(
    covariant ChatMediaCropRotationDial oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);

    if (_dragging) {
      return;
    }

    final nextValue =
        _clamp(widget.valueDegrees);

    if ((nextValue - _displayDegrees).abs() <= .001) {
      return;
    }

    setState(() {
      _displayDegrees = nextValue;
    });
  }

  void _startDrag(
    DragStartDetails details,
  ) {
    _dragging = true;

    _dragStartX =
        details.localPosition.dx;

    _dragStartDegrees =
        _displayDegrees;

    _lastHapticIndex =
        (_displayDegrees / _hapticStep).round();

    _dragChanged = false;
  }

  void _updateDrag(
    DragUpdateDetails details,
  ) {
    var nextValue = _clamp(
      _dragStartDegrees +
          (_dragStartX -
                  details.localPosition.dx) /
              _pixelsPerDegree,
    );

    // Tiny magnetic settle around perfectly straight.
    if (nextValue.abs() < .12) {
      nextValue = 0;
    }

    if ((nextValue - _displayDegrees).abs() <= .001) {
      return;
    }

    final hapticIndex =
        (nextValue / _hapticStep).round();

    if (hapticIndex != _lastHapticIndex) {
      _lastHapticIndex =
          hapticIndex;

      unawaited(
        HapticFeedback.selectionClick(),
      );
    }

    _dragChanged = true;

    setState(() {
      _displayDegrees = nextValue;
    });

    widget.onChanged(
      nextValue,
    );
  }

  void _finishDrag() {
    if (!_dragging) {
      return;
    }

    _dragging = false;

    if (!_dragChanged) {
      return;
    }

    widget.onChangeEnd(
      _displayDegrees,
    );
  }

  void _nudge(
    double amount,
  ) {
    final next =
        _clamp(
      _displayDegrees + amount,
    );

    if (next == _displayDegrees) {
      return;
    }

    setState(() {
      _displayDegrees = next;
    });

    unawaited(
      HapticFeedback.selectionClick(),
    );

    widget.onChanged(next);
    widget.onChangeEnd(next);
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Semantics(
      slider: true,
      label: 'Straighten photo',
      value:
          '${_displayDegrees.toStringAsFixed(1)} degrees',
      increasedValue:
          '${_clamp(_displayDegrees + 1).toStringAsFixed(1)} degrees',
      decreasedValue:
          '${_clamp(_displayDegrees - 1).toStringAsFixed(1)} degrees',
      onIncrease: () => _nudge(1),
      onDecrease: () => _nudge(-1),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart:
            _startDrag,
        onHorizontalDragUpdate:
            _updateDrag,
        onHorizontalDragEnd: (_) {
          _finishDrag();
        },
        onHorizontalDragCancel:
            _finishDrag,
        child: SizedBox(
          height:
              ChatMediaCropRotationDial.height,
          width: double.infinity,
          child: CustomPaint(
            painter:
                _ChatMediaCropRotationDialPainter(
              valueDegrees:
                  _displayDegrees,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatMediaCropRotationDialPainter
    extends CustomPainter {
  const _ChatMediaCropRotationDialPainter({
    required this.valueDegrees,
  });

  final double valueDegrees;

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    if (size.isEmpty) {
      return;
    }

    const horizontalInset = 2.5;

    final halfChord = math.max(
      1.0,
      (size.width / 2) -
          horizontalInset,
    );

    // Sagitta = how deep the visible circular arc bows downward.
    //
    // This makes the ruler an actual section of a LARGE circle rather than
    // approximating the curve by arbitrary Y offsets.
    final sagitta = math
        .max(
          35.0,
          math.min(
            47.0,
            size.width * .125,
          ),
        )
        .toDouble();

    // Circle radius derived from chord + sagitta:
    //
    // R = (a² + s²) / 2s
    //
    // a = half chord
    // s = sagitta
    //
    // This guarantees the arc touches y=0 at both ends.
    final radius =
        ((halfChord * halfChord) +
                (sagitta * sagitta)) /
            (2 * sagitta);

    final centerX =
        size.width / 2;

    final circleCenterY =
        sagitta - radius;

    const pixelsPerDegree =
        _ChatMediaCropRotationDialState
            ._pixelsPerDegree;

    final minorPaint =
        Paint()
          ..color =
              WrytteColors.textSecondary
                  .withValues(
                    alpha: .72,
                  )
          ..isAntiAlias = true;

    final majorPaint =
        Paint()
          ..color =
              WrytteColors.textPrimary
                  .withValues(
                    alpha: .92,
                  )
          ..isAntiAlias = true;

    final selectedPaint =
        Paint()
          ..color =
              WrytteColors.textPrimary
          ..isAntiAlias = true;

    for (
      var degree = -80;
      degree <= 80;
      degree += 2
    ) {
      final x =
          centerX +
          (degree - valueDegrees) *
              pixelsPerDegree;

      if (x <
              horizontalInset ||
          x >
              size.width -
                  horizontalInset) {
        continue;
      }

      final localX =
          x - centerX;

      if (localX.abs() > radius) {
        continue;
      }

      final circleY =
          circleCenterY +
          math.sqrt(
            math.max(
              0,
              radius * radius -
                  localX * localX,
            ),
          );

      final major =
          degree % 10 == 0;

      final terminal =
          degree.abs() == 80;

      final selected =
          (degree - valueDegrees)
                  .abs() <
              .55;

      final dotRadius =
          selected
              ? 2.35
              : major || terminal
              ? 1.9
              : 1.3;

      canvas.drawCircle(
        Offset(
          x,
          circleY,
        ),
        dotRadius,
        selected
            ? selectedPaint
            : major || terminal
            ? majorPaint
            : minorPaint,
      );

      // Keep labels away from the extreme edges.
      final normalizedDistance =
          (localX.abs() /
                  halfChord)
              .clamp(
                0.0,
                1.0,
              );

      if (major &&
          !terminal &&
          normalizedDistance < .82) {
        final verticalRadius =
            math.sqrt(
          math.max(
            1,
            radius * radius -
                localX * localX,
          ),
        );

        final tangentAngle =
            math.atan2(
          -localX,
          verticalRadius,
        );

        final painter =
            TextPainter(
          text: TextSpan(
            text:
                '$degree',
            style:
                const TextStyle(
              color:
                  WrytteColors
                      .textPrimary,
              fontFamily:
                  WrytteTypography
                      .primaryFontFamily,
              fontSize: 10,
              fontWeight:
                  FontWeight.w400,
              height: 1,
            ),
          ),
          textDirection:
              TextDirection.ltr,
        )..layout();

        canvas.save();

        canvas.translate(
          x,
          circleY + 15,
        );

        canvas.rotate(
          tangentAngle,
        );

        painter.paint(
          canvas,
          Offset(
            -painter.width / 2,
            -painter.height / 2,
          ),
        );

        canvas.restore();
      }
    }

    // Fixed pointer under the moving circular ruler.
    final pointerTop =
        math.min(
      size.height - 12,
      sagitta + 23,
    );

    final pointer =
        Path()
          ..moveTo(
            centerX,
            pointerTop,
          )
          ..lineTo(
            centerX - 4.7,
            pointerTop + 8,
          )
          ..lineTo(
            centerX + 4.7,
            pointerTop + 8,
          )
          ..close();

    canvas.drawPath(
      pointer,
      selectedPaint,
    );
  }

  @override
  bool shouldRepaint(
    covariant _ChatMediaCropRotationDialPainter
    oldDelegate,
  ) {
    return (oldDelegate.valueDegrees -
                valueDegrees)
            .abs() >
        .001;
  }
}