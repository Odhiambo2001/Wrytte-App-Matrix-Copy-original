import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatMediaTextColorPicker
    extends StatelessWidget {
  const ChatMediaTextColorPicker({
    super.key,
    required this.height,
    required this.onColorChanged,
  });

  final double height;

  final ValueChanged<Color>
  onColorChanged;

  static const double touchWidth =
      28;

  static const colors = <Color>[
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

  static const stops = <double>[
    0,
    .045,
    .09,
    .145,
    .18,
    .205,
    .28,
    .36,
    .44,
    .52,
    .60,
    .68,
    .76,
    .83,
    .89,
    .94,
    .975,
    1,
  ];

  Color _colorAt(
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
      index < stops.length - 1;
      index++
    ) {
      final start =
          stops[index];

      final end =
          stops[index + 1];

      if (progress <= end) {
        final section =
            ((progress - start) /
                    (end - start))
                .clamp(
                  0.0,
                  1.0,
                )
                .toDouble();

        return Color.lerp(
              colors[index],
              colors[index + 1],
              section,
            ) ??
            colors[index];
      }
    }

    return colors.last;
  }

  void _update(
    double y,
  ) {
    onColorChanged(
      _colorAt(
        y.clamp(
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

        _update(
          details.localPosition.dy,
        );
      },

      onVerticalDragStart: (
        details,
      ) {
        unawaited(
          HapticFeedback.selectionClick(),
        );

        _update(
          details.localPosition.dy,
        );
      },

      onVerticalDragUpdate: (
        details,
      ) {
        _update(
          details.localPosition.dy,
        );
      },

      child:
          SizedBox(
        width:
            touchWidth,
        height:
            height,

        child:
            Center(
          child:
              Container(
            width:
                13,
            height:
                height,

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
                width:
                    1,
              ),

              gradient:
                  const LinearGradient(
                begin:
                    Alignment.topCenter,
                end:
                    Alignment.bottomCenter,
                colors:
                    colors,
                stops:
                    stops,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}