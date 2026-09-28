import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class CameraPlaceholderTile extends StatelessWidget {
  const CameraPlaceholderTile({super.key, this.onPressed, this.preview});

  final VoidCallback? onPressed;
  final Widget? preview;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: 'Open camera',
      child: Material(
        color: const Color(0xFF171A1F),
        child: InkWell(
          onTap: onPressed,
          splashFactory: NoSplash.splashFactory,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF24282E), Color(0xFF14171B)],
                  ),
                ),
              ),
              if (preview != null)
                Positioned.fill(child: IgnorePointer(child: preview)),
              ColoredBox(color: Colors.black.withValues(alpha: .06)),
              const PositionedDirectional(
                top: 8,
                end: 8,
                child: WrytteSvgIcon(
                  asset: 'assets/svg/Camera icon .svg',
                  color: Colors.white,
                  size: 25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
