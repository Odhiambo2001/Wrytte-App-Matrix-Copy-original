import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class WrytteSvgIcon extends StatelessWidget {
  const WrytteSvgIcon({
    super.key,
    required this.asset,
    required this.size,
    required this.color,
  });

  final String asset;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: SvgPicture.asset(
        asset,
        fit: BoxFit.contain,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
    );
  }
}
