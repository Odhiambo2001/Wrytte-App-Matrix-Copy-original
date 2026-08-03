import 'dart:math';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class WrytteIdCandidate {
  final String number;
  final DateTime expiresAt;

  const WrytteIdCandidate({required this.number, required this.expiresAt});
}

class VirtualNumberService {
  VirtualNumberService({Future<bool> Function(String)? candidateExists})
    : _candidateExistsOverride = candidateExists;

  final Future<bool> Function(String)? _candidateExistsOverride;

  static const candidateLifetime = Duration(minutes: 15);
  static const _numberKey = 'pending_wrytte_id_number';
  static const _regionKey = 'pending_wrytte_id_region';
  static const _expiryKey = 'pending_wrytte_id_expiry';
  static const _verifiedKey = 'pending_wrytte_id_verified';
  static const _autoDeleteKey = 'pending_wrytte_id_auto_delete';

  /// Get a locally generated Wrytte ID candidate. Server-side uniqueness is
  /// enforced by the registration API/Matrix account creation.
  Future<WrytteIdCandidate> getAvailableVpn({
    required String regionCode,
  }) async {
    final normalizedRegion = regionCode.trim().toUpperCase();
    final prefix = callingCodeForRegion(regionCode);
    final preferences = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final savedNumber = preferences.getString(_numberKey) ?? '';
    final savedRegion = preferences.getString(_regionKey) ?? '';
    final expiryMillis = preferences.getInt(_expiryKey);
    final savedExpiry =
        expiryMillis == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(expiryMillis);
    final autoDelete = preferences.getBool(_autoDeleteKey) ?? true;

    if (savedNumber.isNotEmpty &&
        savedRegion == normalizedRegion &&
        savedNumber.startsWith(prefix) &&
        savedNumber.length == prefix.length + 9 &&
        preferences.getBool(_verifiedKey) == true &&
        savedExpiry != null &&
        (!autoDelete || savedExpiry.isAfter(now))) {
      return WrytteIdCandidate(number: savedNumber, expiresAt: savedExpiry);
    }

    await clearPendingWrytteId();
    const bodyLength = 9;
    String? availableNumber;
    for (var attempt = 0; attempt < 100; attempt++) {
      final number =
          '$prefix${_generateIdentifierBody(bodyLength, excludedNumber: savedNumber, prefix: prefix)}';
      final suffix = number.substring(prefix.length);
      final exists = await _candidateExists('W$suffix');
      if (!exists) {
        availableNumber = number;
        break;
      }
    }
    if (availableNumber == null) {
      throw StateError('Could not find an available Wrytte ID.');
    }
    final number = availableNumber;
    final expiresAt = now.add(candidateLifetime);
    await preferences.setString(_numberKey, number);
    await preferences.setString(_regionKey, normalizedRegion);
    await preferences.setInt(_expiryKey, expiresAt.millisecondsSinceEpoch);
    await preferences.setBool(_verifiedKey, true);
    await preferences.setBool(_autoDeleteKey, true);
    return WrytteIdCandidate(number: number, expiresAt: expiresAt);
  }

  Future<bool> _candidateExists(String backendId) async {
    final override = _candidateExistsOverride;
    if (override != null) return override(backendId);
    // Backend availability checking is intentionally disabled until an
    // unauthenticated signup endpoint is available. /api/Users/Search cannot
    // be called here because a signup user has no backend token yet.
    return false;
  }

  Future<void> clearPendingWrytteId() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_numberKey);
    await preferences.remove(_regionKey);
    await preferences.remove(_expiryKey);
    await preferences.remove(_verifiedKey);
    await preferences.remove(_autoDeleteKey);
  }

  Future<void> expireCandidate(String number) async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getString(_numberKey) == number &&
        preferences.getBool(_autoDeleteKey) != false) {
      await clearPendingWrytteId();
    }
  }

  Future<void> disableAutoDelete(String number) async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getString(_numberKey) == number) {
      await preferences.setBool(_autoDeleteKey, false);
    }
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

  String _generateIdentifierBody(
    int length, {
    required String excludedNumber,
    required String prefix,
  }) {
    final random = Random.secure();
    String candidate;
    do {
      candidate = List.generate(length, (_) => random.nextInt(10)).join();
    } while (_allDigitsAreTheSame(candidate) ||
        '$prefix$candidate' == excludedNumber);
    return candidate;
  }

  bool _allDigitsAreTheSame(String value) =>
      value.split('').toSet().length == 1;
}
