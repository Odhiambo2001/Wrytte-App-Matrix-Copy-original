import 'package:flutter/material.dart';
import 'package:wrytte/services/face/biometric_prewarm_service.dart';
import 'package:wrytte/ui/auth/kface_intro_page.dart';
import 'package:wrytte/ui/auth/widgets/auth_bottom_action.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

/// Gives a phone account an explicit KFace opt-in. Skipping leaves the account
/// usable with its phone OTP; choosing KFace starts the five-candidate
/// liveness flow and attaches the resulting recovery data to that account.
class KFaceChoicePage extends StatefulWidget {
  const KFaceChoicePage({
    super.key,
    required this.phoneNumber,
    required this.userId,
    this.isExistingUser = false,
    this.username,
  });

  final String phoneNumber;
  final String userId;
  final bool isExistingUser;
  final String? username;

  @override
  State<KFaceChoicePage> createState() => _KFaceChoicePageState();
}

class _KFaceChoicePageState extends State<KFaceChoicePage> {
  late final BiometricPrewarmBundle _prewarm;

  @override
  void initState() {
    super.initState();
    _prewarm = BiometricPrewarmService.prewarm(
      wrytteId: widget.phoneNumber,
      userId: widget.userId,
      isEnrollment: true,
      attachToExistingUser: true,
    );
  }

  void _skip() {
    if (widget.isExistingUser) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<void>(
          builder:
              (_) => HomeScreen(
                currentUserId: widget.userId,
                initialProfileName: widget.username,
                initialPhone: widget.phoneNumber,
              ),
        ),
        (_) => false,
      );
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, '/auth/profile', (_) => false);
  }

  void _startKFace() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder:
            (_) => KFaceIntroPage(
              wrytteId: widget.phoneNumber,
              userId: widget.userId,
              isEnrollment: true,
              attachToExistingUser: true,
              continueToProfileAfterEnrollment: !widget.isExistingUser,
              prewarm: _prewarm,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      bottomNavigationBar: AuthBottomAction(
        label: 'Get started',
        onPressed: _startKFace,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  height: 48,
                  child: TextButton(
                    onPressed: _skip,
                    child: const Text(
                      'Skip',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.face_retouching_natural,
                      color: Colors.white,
                      size: 84,
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Set up KFace?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'KFace lets you recover your account securely with your face. You can skip this and add it later.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
