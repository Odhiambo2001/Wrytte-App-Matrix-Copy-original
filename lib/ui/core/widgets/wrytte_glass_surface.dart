import 'dart:ui';

import 'package:flutter/material.dart';

class WrytteGlassSurface extends StatelessWidget {
  const WrytteGlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    this.padding,
    this.color = const Color(0xB31B1E24),
    this.blur = 24,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final Color color;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: borderRadius,
            border: Border.all(
              color: Colors.white.withValues(alpha: .09),
              width: .8,
            ),
          ),
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    );
  }
}
