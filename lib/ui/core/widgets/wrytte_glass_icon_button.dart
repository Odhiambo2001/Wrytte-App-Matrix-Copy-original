import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class WrytteGlassIconButton extends StatelessWidget {
  const WrytteGlassIconButton({
    super.key,
    required this.semanticLabel,
    required this.onPressed,
    required this.child,
    this.size = 48,
  });

  final String semanticLabel;
  final VoidCallback? onPressed;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticLabel,
      child: SizedBox.square(
        dimension: size,
        child: WrytteGlassSurface(
          borderRadius: BorderRadius.circular(size / 2),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              splashFactory: NoSplash.splashFactory,
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
