import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/face/biometric_prewarm_service.dart';
import 'package:wrytte/ui/auth/kface_view.dart';

/// Compatibility entry point retained for the existing authentication flows.
/// It now presents the shared Kface information page.
class KFaceIntroPage extends StatelessWidget {
  const KFaceIntroPage({
    super.key,
    required this.wrytteId,
    this.userId,
    this.recoveryData,
    this.isEnrollment = false,
    this.attachToExistingUser = false,
    this.continueToProfileAfterEnrollment = false,
    this.prewarm,
  });

  final String wrytteId;
  final String? userId;
  final KFaceRecoveryData? recoveryData;
  final bool isEnrollment;
  final bool attachToExistingUser;
  final bool continueToProfileAfterEnrollment;
  final BiometricPrewarmBundle? prewarm;

  @override
  Widget build(BuildContext context) => KfaceView(
    wrytteId: wrytteId,
    userId: userId,
    recoveryData: recoveryData,
    isEnrollment: isEnrollment,
    attachToExistingUser: attachToExistingUser,
    continueToProfileAfterEnrollment: continueToProfileAfterEnrollment,
    prewarm: prewarm,
  );
}
