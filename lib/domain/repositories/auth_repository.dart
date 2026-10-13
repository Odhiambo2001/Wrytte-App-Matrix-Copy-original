import 'package:wrytte/domain/models/auth_flow.dart';

abstract interface class AuthRepository {
  Future<String> generatePreviewWrytteId({bool refresh = false});

  Future<bool> verifyPreviewCode(String code);

  Future<bool> verifyPhoneOtp({
    required AuthFlow flow,
    required String phone,
    required String code,
  });
}
