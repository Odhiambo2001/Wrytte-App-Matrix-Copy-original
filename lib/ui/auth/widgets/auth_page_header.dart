import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wrytte/core/theme.dart';

class WrytteAuthBackButton extends StatelessWidget {
  const WrytteAuthBackButton({super.key, required this.onPressed});

  static const double touchTarget = 48;
  static const double iconSize = 25;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Back',
    child: SizedBox.square(
      dimension: touchTarget,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        splashRadius: touchTarget / 2,
        icon: SvgPicture.asset(
          'assets/svg/ic--round-arrow-back-ios.svg',
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          colorFilter: const ColorFilter.mode(
            WrytteColors.iconPrimary,
            BlendMode.srcIn,
          ),
        ),
      ),
    ),
  );
}

class AuthPageHeader extends StatelessWidget {
  const AuthPageHeader({
    super.key,
    required this.title,
    this.onBack,
    this.titleStyle,
  });

  static const double topInset = 8;
  static const double horizontalInset = 8;
  static const double barHeight = 64;
  static const double navigationControlTop =
      (barHeight - WrytteAuthBackButton.touchTarget) / 2;
  static const double titleTop = navigationControlTop + 26;
  static const double titleSubtitleGap = 8;
  static const double subtitleMinHeight = 48;

  final String title;
  final VoidCallback? onBack;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      horizontalInset,
      topInset,
      horizontalInset,
      0,
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: barHeight),
      child: Stack(
        children: [
          if (onBack != null)
            PositionedDirectional(
              start: 0,
              top: navigationControlTop,
              child: WrytteAuthBackButton(onPressed: onBack!),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WrytteAuthBackButton.touchTarget,
              titleTop,
              WrytteAuthBackButton.touchTarget,
              0,
            ),
            child: Semantics(
              header: true,
              child: SizedBox(
                height: 30,
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: titleStyle ?? WrytteTypography.authPageTitle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class AuthPageSubtitle extends StatelessWidget {
  const AuthPageSubtitle({
    super.key,
    required this.child,
    this.topGap = AuthPageHeader.titleSubtitleGap,
  });

  final Widget child;
  final double topGap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: topGap),
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: AuthPageHeader.subtitleMinHeight,
      ),
      child: Center(child: child),
    ),
  );
}
