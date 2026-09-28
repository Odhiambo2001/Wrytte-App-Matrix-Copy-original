import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatMediaPaintColorPicker
    extends StatelessWidget {
  const ChatMediaPaintColorPicker({
    super.key,
    required this.onColorChanged,
  });

  static const double height = 174;
  static const double touchWidth = 28;

  final ValueChanged<Color>
  onColorChanged;

  static const List<Color> _colors =
      <Color>[
    Color(0xFFFFFFFF),
    Color(0xFFC9C9C9),
    Color(0xFF777777),
    Color(0xFF171717),
    Color(0xFF000000),
    Color(0xFFFF0000),
    Color(0xFFFF6A00),
    Color(0xFFFFFF00),
    Color(0xFF66FF00),
    Color(0xFF00FF45),
    Color(0xFF00FFD5),
    Color(0xFF00BFFF),
    Color(0xFF1957FF),
    Color(0xFF5028FF),
    Color(0xFF8A20FF),
    Color(0xFFE51CFF),
    Color(0xFFFF168E),
    Color(0xFFFF3158),
  ];

  static const List<double> _stops =
      <double>[
    0.00,
    0.045,
    0.09,
    0.145,
    0.18,
    0.205,
    0.28,
    0.36,
    0.44,
    0.52,
    0.60,
    0.68,
    0.76,
    0.83,
    0.89,
    0.94,
    0.975,
    1.00,
  ];

  Color _colorAtPosition(
    double localY,
  ) {
    final progress =
        (localY / height)
            .clamp(
              0.0,
              1.0,
            )
            .toDouble();

    for (
      var index = 0;
      index < _stops.length - 1;
      index++
    ) {
      final start =
          _stops[index];

      final end =
          _stops[index + 1];

      if (progress <= end) {
        final sectionProgress =
            ((progress - start) /
                    (end - start))
                .clamp(
                  0.0,
                  1.0,
                )
                .toDouble();

        return Color.lerp(
              _colors[index],
              _colors[index + 1],
              sectionProgress,
            ) ??
            _colors[index];
      }
    }

    return _colors.last;
  }

  void _updateColor(
    double localY,
  ) {
    onColorChanged(
      _colorAtPosition(
        localY.clamp(
          0,
          height,
        ),
      ),
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return GestureDetector(
      behavior:
          HitTestBehavior.opaque,

      onTapDown: (
        details,
      ) {
        unawaited(
          HapticFeedback.selectionClick(),
        );

        _updateColor(
          details.localPosition.dy,
        );
      },

      onVerticalDragStart: (
        details,
      ) {
        unawaited(
          HapticFeedback.selectionClick(),
        );

        _updateColor(
          details.localPosition.dy,
        );
      },

      onVerticalDragUpdate: (
        details,
      ) {
        _updateColor(
          details.localPosition.dy,
        );
      },

      child: SizedBox(
        width: touchWidth,
        height: height,

        child: Center(
          child: Container(
            width: 13,
            height: height,

            decoration:
                BoxDecoration(
              borderRadius:
                  BorderRadius.circular(
                13,
              ),

              border:
                  Border.all(
                color:
                    const Color(
                  0xFFF7F7F7,
                ),
                width: 1,
              ),

              gradient:
                  const LinearGradient(
                begin:
                    Alignment.topCenter,
                end:
                    Alignment.bottomCenter,
                colors:
                    _colors,
                stops:
                    _stops,
              ),

              boxShadow:
                  const [
                BoxShadow(
                  color:
                      Color(
                    0x66000000,
                  ),
                  blurRadius:
                      8,
                  offset:
                      Offset(
                    0,
                    2,
                  ),
                ),
                BoxShadow(
                  color:
                      Color(
                    0x55FFFFFF,
                  ),
                  blurRadius:
                      3,
                  spreadRadius:
                      .5,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}