import 'package:flutter/material.dart';
import 'package:wrytte/ui/auth/widgets/auth_page_header.dart';

class AuthIntroBody extends StatelessWidget {
  const AuthIntroBody({
    super.key,
    required this.title,
    required this.subtitle,
    required this.visual,
    required this.details,
    required this.onBack,
    this.contentKey,
    this.spacious = false,
    this.subtitleGap = AuthPageHeader.titleSubtitleGap,
    this.visualGap,
    this.detailsGap = 40,
  });

  final String title;
  final Widget subtitle;
  final Widget visual;
  final Widget details;
  final VoidCallback onBack;
  final Key? contentKey;
  final bool spacious;
  final double subtitleGap;
  final double? visualGap;
  final double detailsGap;

  @override
  Widget build(BuildContext context) => spacious
      ? _spaciousBody()
      : SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AuthPageHeader(title: title, onBack: onBack),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                      child: Column(
                        key: contentKey,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AuthPageSubtitle(
                            topGap: subtitleGap,
                            child: subtitle,
                          ),
                          const SizedBox(height: 16),
                          Center(child: visual),
                          const SizedBox(height: 24),
                          details,
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

  Widget _spaciousBody() => SafeArea(
    bottom: false,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AuthPageHeader(title: title, onBack: onBack),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                  child: Column(
                    key: contentKey,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AuthPageSubtitle(topGap: subtitleGap, child: subtitle),
                      SizedBox(
                        height:
                            visualGap ??
                            (constraints.maxHeight * .19).clamp(24.0, 140.0),
                      ),
                      Center(child: visual),
                      SizedBox(height: detailsGap),
                      details,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
