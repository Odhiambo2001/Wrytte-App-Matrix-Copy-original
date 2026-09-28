import 'dart:ui';

import 'package:flutter/material.dart';

class MediaCircleButton extends StatelessWidget {
  const MediaCircleButton({
    super.key,
    required this.semanticLabel,
    required this.onPressed,
    required this.child,
    this.size = 42,
    this.backgroundColor,
  });

  final String semanticLabel;
  final VoidCallback? onPressed;
  final Widget child;
  final double size;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox.square(
      dimension: size,
      child: Material(
        color: backgroundColor ?? Colors.white.withValues(alpha: .07),
        shape: CircleBorder(
          side: backgroundColor == null
              ? BorderSide(color: Colors.white.withValues(alpha: .10))
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          splashFactory: NoSplash.splashFactory,
          child: Center(child: child),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticLabel,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: AnimatedOpacity(
            opacity: onPressed == null ? .45 : 1,
            duration: const Duration(milliseconds: 140),
            child: button,
          ),
        ),
      ),
    );
  }
}
