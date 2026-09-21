import 'package:flutter/material.dart';
import 'package:wrytte/services/face/biometric_prewarm_service.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
import 'package:wrytte/ui/auth/kface_intro_page.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
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
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      () => Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder:
                              (_) => KFaceIntroPage(
                                wrytteId: widget.phoneNumber,
                                userId: widget.userId,
                                isEnrollment: true,
                                attachToExistingUser: true,
                                prewarm: _prewarm,
                              ),
                        ),
                      ),
                  child: const Text('Get started'),
                ),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed:
                    () => Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute<void>(
                        builder:
                            (_) =>
                                widget.isExistingUser
                                    ? HomeScreen(
                                      currentUserId: widget.userId,
                                      initialProfileName: widget.username,
                                      initialPhone: widget.phoneNumber,
                                    )
                                    : const AddProfilePage(isNewUser: true),
                      ),
                      (_) => false,
                    ),
                child: const Text('Skip'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
