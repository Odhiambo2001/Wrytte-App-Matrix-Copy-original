import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/device_metadata_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/utils/countries.dart';

// =============================================================================
//  Result model
// =============================================================================
class RealNumberRegisterResult {
  final String username;
  final String userId;
  final String secret;

  /// True  → brand-new account (must set profile name on AddProfilePage)
  /// False → existing account   (may be offered KFace before HomeScreen)
  final bool isNewUser;

  const RealNumberRegisterResult({
    required this.username,
    required this.userId,
    required this.secret,
    required this.isNewUser,
  });
}

// =============================================================================
//  RealNumberService
// =============================================================================
class RealNumberService {
  RealNumberService();

  /// Checks whether the number belongs to an existing account before choosing
  /// the registration or sign-in SMS flow.
  Future<bool> searchPhoneExists(String fullPhone) async {
    final phone = _toFullInternational(fullPhone);
    for (final path in const [
      '/auth/register/phone/search',
      '/api/auth/register/phone/search',
    ]) {
      try {
        final response = await ApiService.postMultipart(
          path,
          await _withDeviceMetadata({'phone': phone}),
        );
        final exists = _parseExists(response);
        if (exists != null) return exists;
      } catch (error) {
        debugPrint('[RealNumberService] phone search $path failed: $error');
      }
    }
    throw Exception('Unable to check this phone number.');
  }

  Future<Map<String, String>> _withDeviceMetadata(
    Map<String, String> fields,
  ) async {
    try {
      final metadata = await DeviceMetadataService.instance.collect();
      return {...fields, ...metadata.toJson()};
    } catch (error) {
      // Account lookup remains available if a platform cannot expose optional
      // device metadata. The authenticated device-registration step retries it.
      debugPrint('[RealNumberService] device metadata unavailable: $error');
      return fields;
    }
  }

  // ---------------------------------------------------------------------------
  //  RPN — STEP 1: Send SMS code
  //  POST /auth/register/sendsmscode   field: phone
  // ---------------------------------------------------------------------------
  Future<void> sendSmsCode(String fullPhone) async {
    final phone = _toFullInternational(fullPhone);
    debugPrint('[RealNumberService] requesting signup SMS verification');

    await ApiService.postMultipart('/auth/register/sendsmscode', {
      'phone': phone,
    });
  }

  // ---------------------------------------------------------------------------
  //  Phone sign-in — STEP 1: Send SMS code
  //  POST /auth/login/sendsmscode   field: phone
  // ---------------------------------------------------------------------------
  Future<void> sendLoginSmsCode(String fullPhone) async {
    final phone = _toFullInternational(fullPhone);
    debugPrint('[RealNumberService] requesting sign-in SMS verification');

    await ApiService.postMultipart('/auth/login/sendsmscode', {'phone': phone});
  }

  // ---------------------------------------------------------------------------
  //  RPN — STEP 2: Register with real phone number
  //  POST /auth/register/rpn   fields: phone, code, login
  //
  //  409 = user already exists.
  //    1. Try to log in using the stored secret (normal reinstall / re-login).
  //    2. If no secret is stored, return isNewUser=false so the caller routes
  //       to HomeScreen rather than AddProfilePage.
  // ---------------------------------------------------------------------------
  Future<RealNumberRegisterResult> registerRealPhone({
    required String fullPhone,
    required String code,
    String nickname = '',
    bool login = true,
  }) async {
    final phone = _toFullInternational(fullPhone);
    debugPrint('[RealNumberService] registerRealPhone → "$phone"');
    final existingBeforeRegister = await _checkRealPhoneExists(
      phone: phone,
      code: code,
    );

    final fields = <String, String>{
      'phone': phone,
      'code': code,
      if (nickname.isNotEmpty) 'username': nickname,
      'login': login.toString(),
    };

    try {
      final response = await ApiService.postMultipart(
        '/auth/register/rpn',
        fields,
      );
      final restoreResponse =
          existingBeforeRegister == true
              ? await _loginRestorePayloadFromRegisterResponse(response, phone)
              : response;
      return _handleRegisterResponse(
        restoreResponse,
        fallbackPhone: phone,
        serverIndicatesNewUser: existingBeforeRegister != true,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        debugPrint(
          '[RealNumberService] 409 — user exists, attempting local/archived recovery',
        );

        final existing = await _findExistingRegistration(phone);
        final archivedProfile = await AuthService.instance
            .findArchivedProfileByPhone(phone);
        final storedSecret = await AuthService.instance.getStoredSecret();
        final archivedSecret = archivedProfile?.secret.trim() ?? '';
        final existingSecret = existing?.secret?.trim() ?? '';

        if (existingSecret.isNotEmpty) {
          return login_(
            secret: existingSecret,
            phone: phone,
            userId: existing?.userId,
          );
        }

        if (storedSecret != null && storedSecret.isNotEmpty) {
          // Login with stored secret — _handleRegisterResponse will
          // resolve the display name from local storage and persist session
          final loginResult = await login_(secret: storedSecret, phone: phone);
          return loginResult;
        }

        if (archivedSecret.isNotEmpty) {
          debugPrint(
            '[RealNumberService] 409 — logging in with archived secret',
          );
          return login_(secret: archivedSecret, phone: phone);
        }

        throw Exception(
          'This phone already has an account, but /auth/register/rpn returned '
          '409 instead of returning the existing userid, token, secret, and '
          'expires after OTP verification. Update the backend register/login '
          'response for existing phone numbers.',
        );
      }
      rethrow; // 400, 401, 500, etc. bubble up normally
    }
  }

  Future<bool?> _checkRealPhoneExists({
    required String phone,
    required String code,
  }) async {
    final fields = <String, String>{'phone': phone, 'code': code};
    for (final path in const [
      '/auth/register/checkrpn',
      '/api/auth/register/checkrpn',
    ]) {
      try {
        final response = await ApiService.postMultipart(path, fields);
        final exists = _parseExists(response);
        if (exists != null) {
          debugPrint('[RealNumberService] checkrpn exists=$exists');
          return exists;
        }
      } catch (e) {
        debugPrint('[RealNumberService] checkrpn $path failed: $e');
      }
    }
    return null;
  }

  bool? _parseExists(dynamic response) {
    if (response is bool) return response;
    if (response is Map) {
      for (final key in const [
        'exists',
        'value',
        'isExists',
        'isExisting',
        'registered',
      ]) {
        final raw = response[key];
        if (raw is bool) return raw;
        final text = raw?.toString().trim().toLowerCase();
        if (text == 'true') return true;
        if (text == 'false') return false;
      }
    }
    return null;
  }

  Future<_ExistingRegistration?> _findExistingRegistration(String phone) async {
    try {
      final response = await ApiService.postMultipart('/api/Users/Search', {
        'phoneNumbersC': _backendPhoneCandidates(phone).join('|'),
      });
      return _parseExistingRegistration(response, phone);
    } catch (e) {
      debugPrint('[RealNumberService] pre-register search skipped: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  //  VPN — STEP 1: Send email code
  //  POST /auth/register/sendemailcode   field: email
  // ---------------------------------------------------------------------------
  Future<void> sendEmailCode(String email) async {
    debugPrint('[RealNumberService] sendEmailCode → $email');

    await ApiService.postMultipart('/auth/register/sendemailcode', {
      'email': email.trim().toLowerCase(),
    });
  }

  // ---------------------------------------------------------------------------
  //  VPN — STEP 2: Register with virtual phone number
  //  POST /auth/register/vpn   fields: email, phone, code, login
  // ---------------------------------------------------------------------------
  Future<RealNumberRegisterResult> registerVirtualPhone({
    required String email,
    required String phone,
    required String code,
    String nickname = '',
    bool login = true,
  }) async {
    debugPrint(
      '[RealNumberService] registerVirtualPhone → "$email" / "$phone"',
    );

    final fields = <String, String>{
      'email': email.trim().toLowerCase(),
      'phone': phone,
      'code': code,
      if (nickname.isNotEmpty) 'username': nickname,
      'login': login.toString(),
    };

    final response = await ApiService.postMultipart(
      '/auth/register/vpn',
      fields,
    );
    return _handleRegisterResponse(
      response,
      fallbackPhone: phone,
      serverIndicatesNewUser: true,
    );
  }

  // ---------------------------------------------------------------------------
  //  Login
  //  POST /auth/login   fields: secret, phone(optional), userid(optional)
  // ---------------------------------------------------------------------------
  Future<RealNumberRegisterResult> login_({
    required String secret,
    String? phone,
    String? userId,
  }) async {
    debugPrint('[RealNumberService] login → secret=***');

    final fields = <String, String>{
      'secret': secret,
      if (phone != null) 'phone': phone,
      if (userId != null) 'userid': userId,
    };

    final response = await ApiService.postMultipart('/auth/login', fields);
    return _handleRegisterResponse(
      response,
      fallbackPhone: phone ?? '',
      serverIndicatesNewUser: false,
    );
  }

  // ---------------------------------------------------------------------------
  //  Phone sign-in with a backend/Twilio-verified code
  //  POST /auth/login/phone   fields: phone, code
  // ---------------------------------------------------------------------------
  Future<RealNumberRegisterResult> loginWithPhoneOtp({
    required String fullPhone,
    required String code,
  }) async {
    final phone = _toFullInternational(fullPhone);
    final response = await ApiService.postMultipart('/auth/login/phone', {
      'phone': phone,
      'code': code.trim(),
    });
    return _handleRegisterResponse(
      response,
      fallbackPhone: phone,
      serverIndicatesNewUser: false,
    );
  }

  Future<dynamic> _loginRestorePayloadFromRegisterResponse(
    dynamic registerResponse,
    String phone,
  ) async {
    if (registerResponse is! Map) return registerResponse;
    final map = Map<String, dynamic>.from(registerResponse);
    final secret = (map['secret'] ?? '').toString().trim();
    if (secret.isEmpty) return registerResponse;

    final userId =
        (map['userid'] ?? map['userId'] ?? map['uid'] ?? '').toString().trim();
    try {
      final loginResponse = await ApiService.postMultipart('/auth/login', {
        'secret': secret,
        'phone': phone,
        if (userId.isNotEmpty) 'userid': userId,
      });
      if (loginResponse is! Map) return registerResponse;
      final merged = <String, dynamic>{
        ...map,
        ...Map<String, dynamic>.from(loginResponse),
      };
      debugPrint(
        '[RealNumberService] existing account restore payload fetched '
        'contacts=${_listLength(merged['contacts'] ?? merged['Contacts'])} '
        'chats=${_listLength(merged['chats'] ?? merged['Chats'] ?? merged['conversations'] ?? merged['Conversations'])}',
      );
      return merged;
    } catch (e) {
      debugPrint('[RealNumberService] restore login payload skipped: $e');
      return registerResponse;
    }
  }

  int _listLength(Object? value) => value is List ? value.length : 0;

  // ---------------------------------------------------------------------------
  //  Parse register/login response, resolve the real display name from
  //  local storage, and persist the session.
  //
  //  [serverIndicatesNewUser] is the caller's intent:
  //    true  = registration path  (might be a new user)
  //    false = login path         (always an existing user)
  // ---------------------------------------------------------------------------
  Future<RealNumberRegisterResult> _handleRegisterResponse(
    dynamic response, {
    required String fallbackPhone,
    required bool serverIndicatesNewUser,
  }) async {
    if (response == null) {
      throw Exception('Empty response from server.');
    }

    final map = response as Map<String, dynamic>;

    if (map.containsKey('error')) {
      throw Exception(map['error'] as String);
    }

    final remoteProfile = await AuthService.instance.findUserProfileByPhone(
      fallbackPhone,
    );
    final archivedProfile = await AuthService.instance
        .findArchivedProfileByPhone(fallbackPhone);
    final storedUserId = await AuthService.instance.getCurrentUserId();
    final storedName = await AuthService.instance.getCurrentUsername();

    final userId =
        (map['userid'] as String? ??
                map['userId'] as String? ??
                archivedProfile?.userId ??
                remoteProfile?.userId ??
                storedUserId ??
                '')
            .trim();
    final responseFirstName =
        (map['FirstName'] ??
                map['firstName'] ??
                map['firstname'] ??
                map['first_name'] ??
                '')
            .toString()
            .trim();
    final responseLastName =
        (map['LastName'] ??
                map['lastName'] ??
                map['lastname'] ??
                map['last_name'] ??
                '')
            .toString()
            .trim();
    final responseFullName =
        [
          responseFirstName,
          responseLastName,
        ].where((part) => part.trim().isNotEmpty).join(' ').trim();
    final rawUsername =
        (responseFullName.isNotEmpty
                ? responseFullName
                : map['username'] as String? ??
                    archivedProfile?.username ??
                    fallbackPhone)
            .trim();
    final secret = (map['secret'] as String? ?? '').trim();
    final token = (map['token'] as String? ?? '').trim();
    final expiresAt = DateTime.tryParse((map['expires'] ?? '').toString());

    if (userId.isEmpty) {
      throw Exception('Invalid server response: missing userid.');
    }

    final storedNameForUser = storedUserId == userId ? storedName : null;
    final displayName = _resolveDisplayName(
      _firstRealName([
            archivedProfile?.username,
            storedNameForUser,
            remoteProfile?.username,
            rawUsername,
          ]) ??
          rawUsername,
      fallbackPhone,
    );

    // isNewUser: true only when registering AND no real name is stored yet
    bool isNewUser = false;
    if (serverIndicatesNewUser) {
      isNewUser =
          !_hasRealName(storedNameForUser) &&
          !_hasRealName(archivedProfile?.username);
      debugPrint(
        '[RealNumberService] isNewUser=$isNewUser (storedName="$storedName")',
      );
    }

    await AuthService.instance.persistPhoneSession(
      userId: userId,
      username: displayName,
      phone: fallbackPhone,
      secret: secret.isNotEmpty ? secret : archivedProfile?.secret ?? '',
      token: token,
      expiresAt: expiresAt,
      preferMatrixRegisterFirst: serverIndicatesNewUser,
    );
    await AuthService.instance.persistLoginPayloadCache(
      payload: map,
      ownerUserId: userId,
      displayName: displayName,
    );
    await _restoreProfileInBackground().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        debugPrint('[RealNumberService] profile restore timed out');
      },
    );

    return RealNumberRegisterResult(
      username: displayName,
      userId: userId,
      secret: secret.isNotEmpty ? secret : archivedProfile?.secret ?? '',
      isNewUser: isNewUser,
    );
  }

  Future<void> _restoreProfileInBackground() async {
    try {
      await UserProfileService.instance.getCurrentUserProfile(
        forceRefresh: true,
      );
    } catch (e) {
      debugPrint('[RealNumberService] profile restore skipped: $e');
    }
  }

  // ---------------------------------------------------------------------------
  //  Resolve display name from local storage only.
  //  Returns [candidate] if it looks like a real name, otherwise [fallback].
  // ---------------------------------------------------------------------------
  String _resolveDisplayName(String candidate, String fallback) {
    if (_hasRealName(candidate)) {
      debugPrint('[RealNumberService] resolved display name: "$candidate"');
      return candidate.trim();
    }
    debugPrint('[RealNumberService] using fallback name: "$fallback"');
    return fallback;
  }

  // ---------------------------------------------------------------------------
  //  Returns true if [name] looks like a real human name (not a phone number).
  // ---------------------------------------------------------------------------
  bool _hasRealName(String? name) {
    if (name == null || name.trim().length < 2) return false;
    final trimmed = name.trim();
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return false;
    }
    final stripped = trimmed.replaceAll(RegExp(r'[\s\-]'), '');
    final localpart =
        trimmed.startsWith('@')
            ? trimmed.substring(1).split(':').first
            : trimmed.split(':').first;
    if (RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart)) {
      return false;
    }
    return !RegExp(r'^\+?\d{6,}$').hasMatch(stripped);
  }

  String? _firstRealName(Iterable<String?> names) {
    for (final name in names) {
      if (_hasRealName(name)) return name!.trim();
    }
    return null;
  }

  _ExistingRegistration? _parseExistingRegistration(
    dynamic response,
    String phone,
  ) {
    final targetDigits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (response is! Map) return null;
    final raw = response['contacts'] ?? response['results'] ?? response;

    if (raw is List) {
      for (final item in raw.whereType<Map>()) {
        final parsed = _existingFromMap(item, fallbackPhone: phone);
        if (parsed != null && _samePhone(parsed.phone, targetDigits)) {
          return parsed;
        }
      }
    }

    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is Map) {
          final parsed = _existingFromMap(
            value,
            fallbackPhone: entry.key.toString(),
          );
          if (parsed != null && _samePhone(parsed.phone, targetDigits)) {
            return parsed;
          }
        }
      }
      final parsed = _existingFromMap(raw, fallbackPhone: phone);
      if (parsed != null && _samePhone(parsed.phone, targetDigits)) {
        return parsed;
      }
    }
    return null;
  }

  _ExistingRegistration? _existingFromMap(
    Map raw, {
    required String fallbackPhone,
  }) {
    final userId = _stringValue(
      raw['userid'] ?? raw['userId'] ?? raw['uid'] ?? raw['id'],
    );
    final matrixUserId = _stringValue(
      raw['matrixUserId'] ?? raw['matrix_user_id'] ?? raw['mxid'],
    );
    final isRegistered =
        raw['registered'] == true ||
        raw['exists'] == true ||
        raw['isOnWrytte'] == true ||
        userId != null ||
        matrixUserId != null;
    if (!isRegistered) return null;

    final resolvedUserId =
        userId ?? _matrixLocalpart(matrixUserId ?? '').trim();
    if (resolvedUserId.isEmpty) return null;

    return _ExistingRegistration(
      phone: _normalizePhone(
        _stringValue(
              raw['phone'] ??
                  raw['phoneNumber'] ??
                  raw['msisdn'] ??
                  raw['identifier'],
            ) ??
            fallbackPhone,
      ),
      userId: resolvedUserId,
      username: _stringValue(
        raw['username'] ?? raw['name'] ?? raw['displayName'],
      ),
      secret: _stringValue(raw['secret']),
      token: _stringValue(
        raw['token'] ?? raw['auth_token'] ?? raw['authToken'],
      ),
      expiresAt: DateTime.tryParse(
        _stringValue(raw['expires'] ?? raw['expiresAt'] ?? raw['expiry']) ?? '',
      ),
    );
  }

  bool _samePhone(String candidate, String targetDigits) {
    final digits = candidate.replaceAll(RegExp(r'[^\d]'), '');
    return digits == targetDigits ||
        digits.endsWith(targetDigits) ||
        targetDigits.endsWith(digits);
  }

  Iterable<String> _backendPhoneCandidates(String phone) sync* {
    final normalized = _normalizePhone(phone);
    final digits = normalized.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return;
    yield digits;
    yield normalized;
    if (digits.startsWith('254') && digits.length == 12) {
      yield '0${digits.substring(3)}';
    }
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  String? _stringValue(Object? value) {
    final string = value?.toString().trim();
    return string == null || string.isEmpty ? null : string;
  }

  // ---------------------------------------------------------------------------
  //  Convert any phone input to E.164 international format e.g. +254748630243.
  //  Preserves country code using the countries list for dial-code detection.
  // ---------------------------------------------------------------------------
  String _toFullInternational(String fullPhone) {
    final digits = fullPhone.replaceAll(RegExp(r'[^\d]'), '');

    _PhoneParts? bestMatch;
    int bestLen = 0;

    for (int len = 1; len <= 4; len++) {
      if (digits.length <= len) break;
      final candidate = digits.substring(0, len);
      final country = countries.firstWhere(
        (c) => c.dialCode == candidate,
        orElse:
            () => const Country(
              name: '',
              isoCode: '',
              dialCode: '__none__',
              flag: '',
            ),
      );
      if (country.dialCode != '__none__' && len > bestLen) {
        bestLen = len;
        bestMatch = _PhoneParts(
          areaCode: candidate,
          localNumber: digits.substring(len),
        );
      }
    }

    if (bestMatch != null) {
      debugPrint(
        '[RealNumberService] parsed → '
        'areaCode=${bestMatch.areaCode}  '
        'localNumber=${bestMatch.localNumber}',
      );
      return '+${bestMatch.areaCode}${bestMatch.localNumber}';
    }

    debugPrint(
      '[RealNumberService] no dial-code match, using raw digits: $digits',
    );
    return digits.isEmpty ? '' : '+$digits';
  }
}

// =============================================================================
//  Internal helper
// =============================================================================
class _PhoneParts {
  final String areaCode;
  final String localNumber;

  const _PhoneParts({required this.areaCode, required this.localNumber});
}

class _ExistingRegistration {
  final String phone;
  final String userId;
  final String? username;
  final String? secret;
  final String? token;
  final DateTime? expiresAt;

  const _ExistingRegistration({
    required this.phone,
    required this.userId,
    this.username,
    this.secret,
    this.token,
    this.expiresAt,
  });
}
