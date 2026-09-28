import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class WrytteIdCheckmark extends StatelessWidget {
  const WrytteIdCheckmark({super.key});

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/svg/Checkmark icon Wrytte.svg',
    width: 22,
    height: 22,
    fit: BoxFit.contain,
    colorFilter: const ColorFilter.mode(Color(0xFF4DA3FF), BlendMode.srcIn),
  );
}
