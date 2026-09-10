import 'package:flutter/material.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
import 'package:wrytte/ui/auth/kface_intro_page.dart';

/// Gives a newly registered phone account an explicit KFace opt-in.  Skipping
/// leaves the account usable with its phone OTP; choosing KFace starts the
/// same five-candidate liveness flow used by Wrytte-ID enrollment.
class KFaceChoicePage extends StatelessWidget {
  const KFaceChoicePage({
    super.key,
    required this.phoneNumber,
    required this.userId,
  });

  final String phoneNumber;
  final String userId;

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
                                wrytteId: phoneNumber,
                                userId: userId,
                                isEnrollment: true,
                                attachToExistingUser: true,
                              ),
                        ),
                      ),
                  child: const Text('Get started'),
                ),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed:
                    () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AddProfilePage(isNewUser: true),
                      ),
                    ),
                child: const Text('Skip for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
