import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

class ChatMediaTextSizeSlider extends StatefulWidget {
  const ChatMediaTextSizeSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.height,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final double height;

  final ValueChanged<double> onChanged;

  @override
  State<ChatMediaTextSizeSlider> createState() =>
      _ChatMediaTextSizeSliderState();
}

class _ChatMediaTextSizeSliderState
    extends State<ChatMediaTextSizeSlider> {
  static const double _touchWidth = 58;

  static const double _railTopWidth = 33;
  static const double _railBottomWidth = 5.5;

  static const double _railVerticalInset = 2;

  static const double _handleDiameter = 35;

  static const double _activeVisualLeft = 7;
  static const double _idleVisualLeft = -15;

  bool _active = false;

  double? _dragStartLocalY;
  double? _dragStartValue;

  double get _railHeight {
    return math.max(
      1,
      widget.height -
          (_railVerticalInset * 2),
    );
  }

  double get _handleTravel {
    return math.max(
      1,
      _railHeight -
          _handleDiameter,
    );
  }

  double _normalized(
    double value,
  ) {
    if (widget.max <= widget.min) {
      return 0;
    }

    return ((value - widget.min) /
            (widget.max - widget.min))
        .clamp(
          0.0,
          1.0,
        )
        .toDouble();
  }

  double _valueFromLocalY(
    double localY,
  ) {
    final railLocalY =
        (localY -
                _railVerticalInset -
                (_handleDiameter / 2))
            .clamp(
              0.0,
              _handleTravel,
            )
            .toDouble();

    // Top = largest text.
    // Bottom = smallest text.
    final normalized =
        1 -
        (railLocalY /
            _handleTravel);

    return widget.min +
        ((widget.max - widget.min) *
            normalized);
  }

  void _activate() {
    if (_active) {
      return;
    }

    setState(() {
      _active = true;
    });
  }

  void _deactivate() {
    if (!_active) {
      return;
    }

    setState(() {
      _active = false;

      _dragStartLocalY = null;
      _dragStartValue = null;
    });
  }

  void _handleTapDown(
    TapDownDetails details,
  ) {
    _activate();

    widget.onChanged(
      _valueFromLocalY(
        details.localPosition.dy,
      ),
    );
  }

  void _handleDragStart(
    DragStartDetails details,
  ) {
    _activate();

    _dragStartLocalY =
        details.localPosition.dy;

    _dragStartValue =
        widget.value;
  }

  void _handleDragUpdate(
    DragUpdateDetails details,
  ) {
    final startY =
        _dragStartLocalY;

    final startValue =
        _dragStartValue;

    if (startY == null ||
        startValue == null) {
      return;
    }

    // Relative movement prevents the slider handle jumping to the user's
    // finger when the drag begins slightly above/below the visible circle.
    final deltaY =
        details.localPosition.dy -
        startY;

    final valueDelta =
        -(deltaY / _handleTravel) *
        (widget.max - widget.min);

    widget.onChanged(
      (startValue + valueDelta)
          .clamp(
            widget.min,
            widget.max,
          )
          .toDouble(),
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final normalized =
        _normalized(
      widget.value,
    );

    final handleTop =
        _railVerticalInset +
        ((1 - normalized) *
            _handleTravel);

    final visualLeft =
        _active
            ? _activeVisualLeft
            : _idleVisualLeft;

    return Semantics(
      slider: true,
      label: 'Text size',
      value:
          '${(normalized * 100).round()} percent',

      child: SizedBox(
        width:
            _touchWidth,
        height:
            widget.height,

        child: GestureDetector(
          behavior:
              HitTestBehavior
                  .translucent,

          onTapDown:
              _handleTapDown,

          onTapUp:
              (_) =>
                  _deactivate(),

          onTapCancel:
              _deactivate,

          onVerticalDragStart:
              _handleDragStart,

          onVerticalDragUpdate:
              _handleDragUpdate,

          onVerticalDragEnd:
              (_) =>
                  _deactivate(),

          onVerticalDragCancel:
              _deactivate,

          child: Stack(
            clipBehavior:
                Clip.none,

            children: [
              // ==========================================================
              // TAPERED GLASS RAIL
              // ==========================================================

              AnimatedPositioned(
                duration:
                    const Duration(
                  milliseconds:
                      170,
                ),

                curve:
                    Curves.easeOutCubic,

                left:
                    visualLeft,

                top:
                    _railVerticalInset,

                width:
                    _railTopWidth,

                height:
                    _railHeight,

                child: ClipPath(
                  clipper:
                      const _TextSizeRailClipper(
                    topWidth:
                        _railTopWidth,
                    bottomWidth:
                        _railBottomWidth,
                  ),

                  child: BackdropFilter(
                    filter:
                        ImageFilter.blur(
                      sigmaX: 24,
                      sigmaY: 24,
                    ),

                    child:
                        CustomPaint(
                      foregroundPainter:
                          const _TextSizeRailGlassPainter(),

                      child:
                          const DecoratedBox(
                        decoration:
                            BoxDecoration(
                          color:
                              Color(
                            0x182D3035,
                          ),
                        ),

                        child:
                            SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),

              // ==========================================================
              // WHITE SIZE HANDLE
              // ==========================================================

              AnimatedPositioned(
                duration:
                    const Duration(
                  milliseconds:
                      170,
                ),

                curve:
                    Curves.easeOutCubic,

                left:
                    visualLeft -
                    ((_handleDiameter -
                            _railTopWidth) /
                        2),

                top:
                    handleTop,

                width:
                    _handleDiameter,

                height:
                    _handleDiameter,

                child:
                    const DecoratedBox(
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.white,

                    shape:
                        BoxShape.circle,

                    boxShadow:
                        [
                      BoxShadow(
                        color:
                            Color(
                          0x66000000,
                        ),

                        blurRadius:
                            5,

                        offset:
                            Offset(
                          0,
                          1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextSizeRailClipper
    extends CustomClipper<Path> {
  const _TextSizeRailClipper({
    required this.topWidth,
    required this.bottomWidth,
  });

  final double topWidth;
  final double bottomWidth;

  @override
  Path getClip(
    Size size,
  ) {
    final centerX =
        size.width / 2;

    final topRadius =
        topWidth / 2;

    final bottomRadius =
        bottomWidth / 2;

    final topCircle =
        Rect.fromCircle(
      center:
          Offset(
        centerX,
        topRadius,
      ),
      radius:
          topRadius,
    );

    final path =
        Path()
          ..moveTo(
            centerX -
                topRadius,
            topRadius,
          )
          ..arcTo(
            topCircle,
            math.pi,
            math.pi,
            false,
          )
          ..lineTo(
            centerX +
                bottomRadius,
            size.height -
                bottomRadius,
          )
          ..arcTo(
            Rect.fromCircle(
              center:
                  Offset(
                centerX,
                size.height -
                    bottomRadius,
              ),
              radius:
                  bottomRadius,
            ),
            0,
            math.pi,
            false,
          )
          ..lineTo(
            centerX -
                topRadius,
            topRadius,
          )
          ..close();

    return path;
  }

  @override
  bool shouldReclip(
    covariant _TextSizeRailClipper
        oldClipper,
  ) {
    return oldClipper.topWidth !=
            topWidth ||
        oldClipper.bottomWidth !=
            bottomWidth;
  }
}

class _TextSizeRailGlassPainter
    extends CustomPainter {
  const _TextSizeRailGlassPainter();

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final borderPaint =
        Paint()
          ..style =
              PaintingStyle.stroke
          ..strokeWidth =
              .8
          ..color =
              Colors.white.withValues(
            alpha: .11,
          )
          ..isAntiAlias =
              true;

    // ClipPath already supplies the tapered geometry.
    // A subtle edge highlight is enough here.
    final edgePath =
        Path()
          ..moveTo(
            size.width / 2,
            .5,
          )
          ..quadraticBezierTo(
            size.width * .78,
            size.height * .42,
            size.width / 2,
            size.height - .5,
          )
          ..quadraticBezierTo(
            size.width * .22,
            size.height * .42,
            size.width / 2,
            .5,
          );

    canvas.drawPath(
      edgePath,
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(
    covariant _TextSizeRailGlassPainter
        oldDelegate,
  ) {
    return false;
  }
}