import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/face/biometric_prewarm_service.dart';
import 'package:wrytte/ui/auth/kface_scan_page.dart';
import 'package:wrytte/ui/auth/widgets/auth_bottom_action.dart';
import 'package:wrytte/ui/auth/widgets/auth_intro_body.dart';
import 'package:wrytte/ui/auth/widgets/kface_illustration.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class KfaceView extends StatefulWidget {
  const KfaceView({
    super.key,
    required this.wrytteId,
    required this.isEnrollment,
    this.userId,
    this.attachToExistingUser = false,
    this.recoveryData,
    this.prewarm,
  });

  final String wrytteId;
  final bool isEnrollment;
  final String? userId;
  final bool attachToExistingUser;
  final KFaceRecoveryData? recoveryData;
  final BiometricPrewarmBundle? prewarm;

  @override
  State<KfaceView> createState() => _KfaceViewState();
}

class _KfaceViewState extends State<KfaceView> {
  late final TapGestureRecognizer _learnMoreRecognizer;
  late final BiometricPrewarmBundle _prewarm;

  @override
  void initState() {
    super.initState();
    _prewarm =
        widget.prewarm ??
        BiometricPrewarmService.prewarm(
          wrytteId: widget.wrytteId,
          userId: widget.userId,
          isEnrollment: widget.isEnrollment,
          attachToExistingUser: widget.attachToExistingUser,
        );
    _learnMoreRecognizer = TapGestureRecognizer()
      ..onTap = () => _showInformation(context);
  }

  @override
  void dispose() {
    _learnMoreRecognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enlargedText = MediaQuery.textScalerOf(context).scale(14) > 20;
    return Scaffold(
      backgroundColor: WrytteColors.background,
      bottomNavigationBar: AuthBottomAction(
        label: 'Get started',
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => KFaceScanPage(
                wrytteId: widget.wrytteId,
                userId: widget.userId,
                recoveryData: widget.recoveryData,
                isEnrollment: widget.isEnrollment,
                attachToExistingUser: widget.attachToExistingUser,
                prewarm: _prewarm,
              ),
            ),
          );
        },
      ),
      body: AuthIntroBody(
        spacious: true,
        visualGap: 32,
        detailsGap: 40,
        title: 'Kface',
        contentKey: const ValueKey('kface-content'),
        onBack: () => Navigator.of(context).pop(),
        subtitle: const SizedBox(
          width: 220,
          child: Text(
            'Create a recovery key for\nyour account and data.',
            textAlign: TextAlign.center,
            style: WrytteTypography.authSubtitle,
          ),
        ),
        visual: const KfaceIllustration(),
        details: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: enlargedText ? double.infinity : 290,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'What is the Kface?',
                  textAlign: TextAlign.center,
                  style: WrytteTypography.authSectionTitle,
                ),
                const SizedBox(height: 12),
                const Text(
                  'KFace is a secure facial key created and stored only on your device.',
                  textAlign: TextAlign.center,
                  style: WrytteTypography.authBody,
                ),
                const SizedBox(height: 20),
                Text.rich(
                  key: const ValueKey('kface-recovery-description'),
                  TextSpan(
                    style: WrytteTypography.authBody,
                    children: [
                      const TextSpan(
                        text:
                            'It helps recover your account and data, and is never accessible to Wrytte App or third parties. ',
                      ),
                      TextSpan(
                        text: 'Learn\u00a0more',
                        style: const TextStyle(color: WrytteColors.primary),
                        recognizer: _learnMoreRecognizer,
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showInformation(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About Kface'),
        content: const SingleChildScrollView(
          child: Text(
            'Kface is a planned on-device recovery feature. Enrollment and recovery are not connected in this build. No facial data has been captured and no recovery key has been created.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
