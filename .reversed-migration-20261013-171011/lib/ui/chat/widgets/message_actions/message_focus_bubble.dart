import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class MessageFocusBubble extends StatelessWidget {
  const MessageFocusBubble({
    super.key,
    required this.image,
    required this.size,
    required this.animation,
  });

  final ui.Image image;
  final Size size;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    // Keep only an extremely small focus emphasis for the faster transition.
    //
    // Position is NOT animated here. MessageActionOverlay moves the complete
    // reaction + bubble + menu cluster from one shared transform, so this widget
    // only owns the subtle visual focus scale.
    //
    // At animation value 0 this is exactly 1.0, which keeps opening pixel-for-
    // pixel aligned with the real source and closing aligned when it gets home.
    final Animation<double> scaleAnimation = Tween<double>(
      begin: 1,
      end: 1.004,
    ).animate(
      CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );

    return IgnorePointer(
      child: RepaintBoundary(
        child: ScaleTransition(
          scale: scaleAnimation,
          child: SizedBox.fromSize(
            size: size,
            child: RawImage(
              image: image,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      ),
    );
  }
}
