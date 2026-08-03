import 'dart:math';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class VirtualNumberService {
  VirtualNumberService();

  /// Get a locally generated Wrytte ID candidate. Server-side uniqueness is
  /// enforced by the registration API/Matrix account creation.
  Future<String> getAvailableVpn({required String regionCode}) async {
    final prefix = callingCodeForRegion(regionCode);
    return '$prefix${_generateIdentifierBody()}';
  }

  /// Uses phone_numbers_parser metadata to resolve an ISO alpha-2 region to
  /// its international calling prefix.
  String callingCodeForRegion(String regionCode) {
    final isoCode = isoCodeConversionMap[regionCode.trim().toUpperCase()];
    final resolvedIsoCode = isoCode ?? IsoCode.US;
    return PhoneNumber(isoCode: resolvedIsoCode, nsn: '').countryCode;
  }

  /// Wrytte IDs use the regional prefix followed by space-only groups.
  String formatWrytteId(String number, {required String regionCode}) {
    final digits = number.replaceAll(RegExp(r'[^\d]'), '');
    final prefix = callingCodeForRegion(regionCode);
    final body =
        digits.startsWith(prefix) ? digits.substring(prefix.length) : digits;
    final groups = <String>[];
    for (var index = 0; index < body.length; index += 3) {
      final end = (index + 3).clamp(0, body.length);
      groups.add(body.substring(index, end));
    }
    return '+$prefix${groups.isEmpty ? '' : ' ${groups.join(' ')}'}';
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

  String _generateIdentifierBody() {
    final random = Random.secure();
    final first = 100 + random.nextInt(900);
    final second = 100 + random.nextInt(900);
    final third = 100 + random.nextInt(900);
    return '$first$second$third';
  }
}
