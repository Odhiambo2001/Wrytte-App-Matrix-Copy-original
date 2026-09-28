import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class CameraControlButton extends StatelessWidget {
  const CameraControlButton({
    super.key,
    required this.semanticLabel,
    required this.onPressed,
    this.svgAsset,
    this.icon,
    this.iconSize = 27,
    this.iconColor = const Color(0xFFF5F5F5),
    this.backgroundColor = Colors.transparent,
    this.size = 52,
  }) : assert(svgAsset != null || icon != null);

  final String semanticLabel;
  final VoidCallback? onPressed;
  final String? svgAsset;
  final IconData? icon;
  final double iconSize;
  final Color iconColor;
  final Color backgroundColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final child = svgAsset != null
        ? WrytteSvgIcon(asset: svgAsset!, size: iconSize, color: iconColor)
        : Icon(icon, size: iconSize, color: iconColor);
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: backgroundColor,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            splashFactory: NoSplash.splashFactory,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
