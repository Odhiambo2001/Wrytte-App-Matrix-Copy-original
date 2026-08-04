import 'dart:math';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/wrytte_library.dart';

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
  static const _wryttePrefix = '00';

  /// Get a locally generated Wrytte ID candidate. Server-side uniqueness is
  /// enforced by the registration API/Matrix account creation.
  Future<WrytteIdCandidate> getAvailableVpn({
    required String regionCode,
  }) async {
    final normalizedRegion = regionCode.trim().toUpperCase();
    final isoCode = _isoCodeForRegion(normalizedRegion);
    final rule = WrytteLibrary.forRegion(normalizedRegion);
    final bodyLength =
        rule?.maximumNationalLength ?? _fallbackMobileBodyLength(isoCode);
    final prefixes = WrytteLibrary.prefixesFor(normalizedRegion);
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
        savedNumber.startsWith(_wryttePrefix) &&
        savedNumber.length == _wryttePrefix.length + bodyLength &&
        preferences.getBool(_verifiedKey) == true &&
        savedExpiry != null &&
        (!autoDelete || savedExpiry.isAfter(now))) {
      return WrytteIdCandidate(number: savedNumber, expiresAt: savedExpiry);
    }

    await clearPendingWrytteId();
    String? availableNumber;
    for (var attempt = 0; attempt < 100; attempt++) {
      final selectedPrefix =
          prefixes.isEmpty
              ? ''
              : prefixes[Random.secure().nextInt(prefixes.length)];
      final randomLength = bodyLength - selectedPrefix.length;
      if (randomLength < 1) continue;
      final body =
          '$selectedPrefix${_generateIdentifierBody(randomLength, excludedNumber: savedNumber, prefix: '$_wryttePrefix$selectedPrefix')}';

      if (prefixes.isEmpty &&
          !PhoneNumber(
            isoCode: isoCode,
            nsn: body,
          ).isValid(type: PhoneNumberType.mobile)) {
        continue;
      }

      final number = '$_wryttePrefix$body';
      final suffix = number.substring(_wryttePrefix.length);
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

  /// Invalidates the cached candidate and guarantees the next generated
  /// candidate is different from it.
  Future<WrytteIdCandidate> refreshAvailableVpn({
    required String regionCode,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_verifiedKey, false);
    return getAvailableVpn(regionCode: regionCode);
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
    final resolvedIsoCode = _isoCodeForRegion(regionCode);
    return PhoneNumber(isoCode: resolvedIsoCode, nsn: '').countryCode;
  }

  /// Wrytte IDs use +00 and the detected region's national grouping. Any
  /// punctuation in that region's phone format is normalized to spaces.
  String formatWrytteId(String number, {required String regionCode}) {
    final digits = number.replaceAll(RegExp(r'[^\d]'), '');
    final body =
        digits.startsWith(_wryttePrefix)
            ? digits.substring(_wryttePrefix.length)
            : digits;
    if (body.isEmpty) return '+$_wryttePrefix';

    final rule = WrytteLibrary.forRegion(regionCode);
    final spacesOnly =
        rule == null
            ? PhoneNumber(
              isoCode: _isoCodeForRegion(regionCode),
              nsn: body,
            ).formatNsn().replaceAll(RegExp(r'[^\d]+'), ' ').trim()
            : _formatUsingWrytteRule(body, rule);
    return '+$_wryttePrefix $spacesOnly';
  }

  IsoCode _isoCodeForRegion(String regionCode) =>
      isoCodeConversionMap[regionCode.trim().toUpperCase()] ?? IsoCode.US;

  int _fallbackMobileBodyLength(IsoCode isoCode) =>
      PhoneNumber(isoCode: isoCode, nsn: '').countryCode == '1' ? 10 : 9;

  String _formatUsingWrytteRule(String body, WrytteRegionRule rule) {
    final groups = <String>[];
    var offset = 0;
    for (final token in rule.format.split(' ')) {
      final size = int.parse(token);
      final end = min(offset + size, body.length);
      if (end > offset) groups.add(body.substring(offset, end));
      offset = end;
    }
    if (offset < body.length) groups.add(body.substring(offset));
    return groups.join(' ');
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
