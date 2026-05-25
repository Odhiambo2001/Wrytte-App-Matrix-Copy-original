import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/utils/countries.dart';

// =============================================================================
//  Result model
// =============================================================================
class RealNumberRegisterResult {
  final String username;
  final String userId;
  final String secret;

  /// True  → brand-new account (must set profile name on AddProfilePage)
  /// False → existing account   (go straight to HomeScreen)
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

  // ---------------------------------------------------------------------------
  //  RPN — STEP 1: Send SMS code
  //  POST /auth/register/sendsmscode   field: phone
  // ---------------------------------------------------------------------------
  Future<void> sendSmsCode(String fullPhone) async {
    final phone = _toFullInternational(fullPhone);
    debugPrint('[RealNumberService] sendSmsCode → $phone');

    await ApiService.postMultipart('/auth/register/sendsmscode', {
      'phone': phone,
    });
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
      return _handleRegisterResponse(
        response,
        fallbackPhone: phone,
        serverIndicatesNewUser: true,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        debugPrint(
          '[RealNumberService] 409 — user exists, attempting login with stored secret',
        );

        final archivedProfile = await AuthService.instance
            .findArchivedProfileByPhone(phone);
        final storedSecret = await AuthService.instance.getStoredSecret();
        final archivedSecret = archivedProfile?.secret.trim() ?? '';

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

        // No stored secret — user exists but this may be a fresh install or a
        // local-storage reset. Rehydrate from secure local profile storage
        // before falling back to the phone number.
        final remoteProfile = await AuthService.instance.findUserProfileByPhone(
          phone,
        );
        final localUserId = await AuthService.instance.getCurrentUserId();
        final localUsername = await AuthService.instance.getCurrentUsername();
        final existingUserId =
            remoteProfile?.userId ??
            archivedProfile?.userId ??
            localUserId ??
            '';
        final existingUsername =
            _firstRealName([
              remoteProfile?.username,
              archivedProfile?.username,
              localUsername,
            ]) ??
            phone;
        final displayName = _resolveDisplayName(existingUsername, phone);

        if (existingUserId.isNotEmpty) {
          await AuthService.instance.persistPhoneSession(
            userId: existingUserId,
            username: displayName,
            phone: phone,
            secret: '',
          );
        } else {
          throw Exception(
            'This phone already has an account, but the server did not return '
            'the saved profile. Please sign in with the existing account '
            'session or ask the backend to return userid, username, token, '
            'and secret after OTP verification.',
          );
        }

        debugPrint(
          '[RealNumberService] 409 no secret — display name: "$displayName"',
        );

        return RealNumberRegisterResult(
          username: displayName,
          userId: existingUserId,
          secret: '',
          isNewUser: false,
        );
      }
      rethrow; // 400, 401, 500, etc. bubble up normally
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
    final rawUsername =
        (map['username'] as String? ??
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

    return RealNumberRegisterResult(
      username: displayName,
      userId: userId,
      secret: secret.isNotEmpty ? secret : archivedProfile?.secret ?? '',
      isNewUser: isNewUser,
    );
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

  // ---------------------------------------------------------------------------
  //  Convert any phone input to full international format e.g. 254748630243.
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
      return '${bestMatch.areaCode}${bestMatch.localNumber}';
    }

    debugPrint(
      '[RealNumberService] no dial-code match, using raw digits: $digits',
    );
    return digits;
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
