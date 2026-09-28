import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const _primary = Color(0xFF4DA3FF);
const _surfaceRaised = Color(0xFF23262C);
const _textPrimary = Color(0xFFF2F2F2);
const _textSecondary = Color(0xFFC6C6C6);

const _pageTitle = TextStyle(
  fontFamily: 'Inter',
  fontSize: 25,
  fontWeight: FontWeight.w600,
  height: 1.2,
  color: _textPrimary,
);

const _subtitle = TextStyle(
  fontFamily: 'Inter',
  fontSize: 14,
  fontWeight: FontWeight.normal,
  height: 1.4,
  color: _textSecondary,
);

const _choiceLabel = TextStyle(
  fontFamily: 'Inter',
  fontSize: 18,
  fontWeight: FontWeight.w500,
  height: 1.2,
  color: _textPrimary,
);

const _footer = TextStyle(
  fontFamily: 'Inter',
  fontSize: 14,
  fontWeight: FontWeight.w500,
  height: 1.3,
  color: Colors.white,
);

const _footerAction = TextStyle(
  fontFamily: 'Inter',
  fontSize: 14,
  fontWeight: FontWeight.w500,
  height: 1.3,
  color: _primary,
);

class WrytteAuthOptions extends StatelessWidget {
  const WrytteAuthOptions({
    super.key,
    required this.onWrytteIdPressed,
    required this.onPhonePressed,
  });

  final VoidCallback onWrytteIdPressed;
  final VoidCallback onPhonePressed;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Sign up', textAlign: TextAlign.center, style: _pageTitle),
      const SizedBox(height: 14),
      const Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: 220,
          child: Text(
            'Choose a sign up option to\ncreate an account',
            textAlign: TextAlign.center,
            style: _subtitle,
          ),
        ),
      ),
      const SizedBox(height: 32),
      WrytteAuthChoiceCard(
        semanticLabel: 'Sign up with a Wrytte ID number',
        title: 'Wrytte ID',
        leading: Image.asset(
          'assets/images/wrytte_id_signup_icon_128.png',
          width: 27,
          height: 27,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
        onPressed: onWrytteIdPressed,
      ),
      const SizedBox(height: 32),
      WrytteAuthChoiceCard(
        semanticLabel: 'Sign up with a phone number',
        title: 'Phone number',
        leading: SvgPicture.asset(
          'assets/svg/solar--phone-linear.svg',
          width: 20,
          height: 20,
          fit: BoxFit.contain,
          colorFilter: const ColorFilter.mode(_textPrimary, BlendMode.srcIn),
        ),
        onPressed: onPhonePressed,
      ),
    ],
  );
}

class WrytteAuthLoginFooter extends StatelessWidget {
  const WrytteAuthLoginFooter({super.key, required this.onLogInPressed});

  final VoidCallback onLogInPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Already have an account?', style: _footer),
          TextButton(
            onPressed: onLogInPressed,
            style: TextButton.styleFrom(
              foregroundColor: _primary,
              fixedSize: const Size.fromHeight(36),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsetsDirectional.only(
                start: 4,
                top: 8,
                end: 4,
                bottom: 8,
              ),
              textStyle: _footerAction,
            ),
            child: const Text('Log in'),
          ),
        ],
      ),
    ),
  );
}

class WrytteAuthChoiceCard extends StatelessWidget {
  const WrytteAuthChoiceCard({
    super.key,
    required this.semanticLabel,
    required this.title,
    required this.leading,
    required this.onPressed,
  });

  final String semanticLabel;
  final String title;
  final Widget leading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(28);
    return Semantics(
      button: true,
      label: semanticLabel,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: const BorderSide(color: _surfaceRaised, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            borderRadius: radius,
            child: SizedBox(
              height: 54,
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    leading,
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: _choiceLabel,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
