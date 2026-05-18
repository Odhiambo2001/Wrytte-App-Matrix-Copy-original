import 'dart:math';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class VirtualNumberService {
  VirtualNumberService();

  /// Get a locally generated Wrytte ID candidate. Server-side uniqueness is
  /// enforced by the registration API/Matrix account creation.
  Future<String> getAvailableVpn() async {
    return _generateVirtualNumber();
  }

  /// 2️ Send/store email verification code through the Firebase auth service.
  Future<void> sendEmailCode(String email) async {
    await AuthService.instance.sendEmailCode(email);
  }

  /// Verify email + activate Wrytte ID.
  Future<AuthUser> registerVpn({
    required String email,
    required String code,
    required String phone,
  }) async {
    final user = await AuthService.instance.registerVirtualPhone(
      email: email,
      code: code,
      phone: phone,
      username: email.split('@').first,
      login: true,
    );

    return user;
  }

  String _generateVirtualNumber() {
    final random = Random.secure();
    final first = 10 + random.nextInt(90);
    final second = 100 + random.nextInt(900);
    final third = 100 + random.nextInt(900);
    final fourth = 100 + random.nextInt(900);
    return '$first$second$third$fourth';
  }
}
