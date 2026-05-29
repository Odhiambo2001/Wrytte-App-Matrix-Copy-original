import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

class StoredAuthProfile {
  final String userId;
  final String username;
  final String phone;
  final String secret;
  final String? token;
  final DateTime? expiresAt;

  const StoredAuthProfile({
    required this.userId,
    required this.username,
    required this.phone,
    this.secret = '',
    this.token,
    this.expiresAt,
  });

  bool get hasUsableName =>
      username.trim().length >= 2 &&
      !{'user', 'uder', 'unknown'}.contains(username.trim().toLowerCase()) &&
      !RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(
        username.trim().startsWith('@')
            ? username.trim().substring(1).split(':').first
            : username.trim().split(':').first,
      ) &&
      !RegExp(
        r'^\+?\d{6,}$',
      ).hasMatch(username.trim().replaceAll(RegExp(r'[\s\-()+]'), ''));
}

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;

  final Map<String, String> _pendingPhoneOtps = {};
  final Map<String, String> _pendingEmailOtps = {};
  int _matrixBootstrapGeneration = 0;
  Future<void>? _matrixLoginInFlight;
  String? _matrixLoginInFlightUserId;
  int? _matrixLoginInFlightGeneration;

  static const _tokenKey = 'auth_token';
  static const _expiryKey = 'auth_token_expiry';
  static const _userIdKey = 'user_id';
  static const _usernameKey = 'username';
  static const _secretKey = 'secret';
  static const _phoneKey = 'phone';
  static const _profileArchiveKey = 'auth_profile_archive_v1';

  static const _defaultHomeserver = MatrixConfig.homeserver;

  // ---------------------------------------------------------------------------
  // Firebase anonymous auth
  // ---------------------------------------------------------------------------
  Future<User?> ensureFirebaseAuth() async {
    try {
      if (_firebaseAuth.currentUser != null) return _firebaseAuth.currentUser;
      final credential = await _firebaseAuth.signInAnonymously();
      return credential.user;
    } catch (e) {
      debugPrint('[AuthService] Firebase anonymous sign-in failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Matrix login — always uses Simon's secret as the password.
  // Tries login first; if the account does not exist yet, registers it.
  // ---------------------------------------------------------------------------
  Future<void> loginToMatrix({
    required String userId,
    required String nickname,
    String homeserver = _defaultHomeserver,
    int? generation,
    bool preferRegisterFirst = false,
    bool forceFreshSession = false,
  }) {
    final cleanUserId = userId.trim();
    final inFlight = _matrixLoginInFlight;
    final inFlightIsCurrent =
        _matrixLoginInFlightGeneration == null ||
        _matrixLoginInFlightGeneration == _matrixBootstrapGeneration;
    if (!forceFreshSession &&
        inFlight != null &&
        _matrixLoginInFlightUserId == cleanUserId &&
        inFlightIsCurrent) {
      apkLog('Matrix.auth', 'join in-flight login user_id="$cleanUserId"');
      return inFlight;
    }

    final future = _loginToMatrixInternal(
      userId: cleanUserId,
      nickname: nickname,
      homeserver: homeserver,
      generation: generation,
      preferRegisterFirst: preferRegisterFirst,
      forceFreshSession: forceFreshSession,
    );
    _matrixLoginInFlight = future;
    _matrixLoginInFlightUserId = cleanUserId;
    _matrixLoginInFlightGeneration = generation;
    return future.whenComplete(() {
      if (identical(_matrixLoginInFlight, future)) {
        _matrixLoginInFlight = null;
        _matrixLoginInFlightUserId = null;
        _matrixLoginInFlightGeneration = null;
      }
    });
  }

  Future<void> _loginToMatrixInternal({
    required String userId,
    required String nickname,
    required String homeserver,
    int? generation,
    required bool preferRegisterFirst,
    required bool forceFreshSession,
  }) async {
    apkLog(
      'Matrix.auth',
      'login start user_id="$userId" homeserver="$homeserver"',
    );
    if (!await _isCurrentMatrixBootstrap(userId, generation)) {
      debugPrint('[AuthService] Matrix login skipped for stale user $userId.');
      apkLog('Matrix.auth', 'login skipped stale user_id="$userId"');
      return;
    }

    // Use Simon's secret as the one and only Matrix password.
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.trim().isEmpty) {
      debugPrint('[AuthService] No secret stored — Matrix login skipped.');
      apkLog('Matrix.auth', 'login skipped missing secret user_id="$userId"');
      return;
    }
    final password = secret.trim();

    if (preferRegisterFirst) {
      try {
        apkLog('Matrix.auth', 'register first request user_id="$userId"');
        await MatrixAuthService.instance.register(
          username: userId,
          password: password,
          homeserver: homeserver,
          forceFreshSession: forceFreshSession,
        );
        apkLog('Matrix.auth', 'register first success user_id="$userId"');
      } catch (e) {
        if (!await _isCurrentMatrixBootstrap(userId, generation)) {
          debugPrint(
            '[AuthService] Matrix login fallback skipped for stale user $userId.',
          );
          apkLog('Matrix.auth', 'login skipped stale user_id="$userId"');
          return;
        }
        apkLog(
          'Matrix.auth',
          'register first failed; login request user_id="$userId" error="$e"',
        );
        await MatrixAuthService.instance.login(
          username: userId,
          password: password,
          homeserver: homeserver,
          forceFreshSession: forceFreshSession,
        );
        apkLog('Matrix.auth', 'login fallback success user_id="$userId"');
      }
    } else {
      try {
        apkLog('Matrix.auth', 'login request user_id="$userId"');
        await MatrixAuthService.instance.login(
          username: userId,
          password: password,
          homeserver: homeserver,
          forceFreshSession: forceFreshSession,
        );
        apkLog('Matrix.auth', 'login success user_id="$userId"');
      } catch (_) {
        if (!await _isCurrentMatrixBootstrap(userId, generation)) {
          debugPrint(
            '[AuthService] Matrix register skipped for stale user $userId.',
          );
          apkLog('Matrix.auth', 'register skipped stale user_id="$userId"');
          return;
        }
        // Account may not exist yet on this server — register it.
        apkLog(
          'Matrix.auth',
          'login failed; register request user_id="$userId"',
        );
        await MatrixAuthService.instance.register(
          username: userId,
          password: password,
          homeserver: homeserver,
          forceFreshSession: forceFreshSession,
        );
        apkLog('Matrix.auth', 'register success user_id="$userId"');
      }
    }

    final client = MatrixClientService.instance.client;
    if (!await _isCurrentMatrixBootstrap(userId, generation)) {
      await _logoutMatrixUserIfMatches(userId);
      debugPrint('[AuthService] Ignored stale Matrix login for $userId.');
      apkLog('Matrix.auth', 'login ignored stale user_id="$userId"');
      return;
    }
    if (nickname.trim().isNotEmpty) {
      unawaited(_updateMatrixDisplayName(client, nickname.trim()));
    }
    apkLog(
      'Matrix.auth',
      'login ready user_id="$userId" mxid="${client.userID}"',
    );
  }

  Future<void> _updateMatrixDisplayName(mx.Client client, String name) async {
    try {
      final userId = client.userID;
      if (userId == null || userId.isEmpty) return;
      await client
          .setProfileField(userId, 'displayname', {'displayname': name})
          .timeout(const Duration(seconds: 3));
      apkLog('Matrix.auth', 'display name updated user_id="$userId"');
    } catch (e) {
      debugPrint('[AuthService] Matrix display-name update failed: $e');
      apkLog('Matrix.auth', 'display name skipped error="$e"');
    }
  }

  Future<void> logoutFromMatrix() => MatrixAuthService.instance.logout();

  // ---------------------------------------------------------------------------
  // Persist session after successful registration/login.
  // secret must be saved BEFORE Matrix login is attempted.
  // ---------------------------------------------------------------------------
  Future<void> persistPhoneSession({
    required String userId,
    required String username,
    required String phone,
    required String secret,
    String? token,
    DateTime? expiresAt,
    Duration matrixBootstrapTimeout = const Duration(seconds: 3),
    bool preferMatrixRegisterFirst = false,
  }) async {
    // Never carry a different account's name into this session, and never
    // overwrite this account's archived real name with a generated fallback.
    final currentUserId = await _storage.read(key: _userIdKey);
    final currentName = await _storage.read(key: _usernameKey);
    final currentToken = await _storage.read(key: _tokenKey);
    final normalizedPhone = _normalizePhone(phone);
    final archivedProfile = await findArchivedProfileByPhone(normalizedPhone);
    final nameToSave =
        _firstRealProfileName([
          if (currentUserId == userId) currentName,
          archivedProfile?.username,
          username,
        ]) ??
        username.trim();
    final tokenToSave =
        (token != null && token.trim().isNotEmpty)
            ? token.trim()
            : _looksLikeJwt(currentToken)
            ? currentToken!.trim()
            : userId;

    // Save secret first so loginToMatrix() can read it immediately.
    final writes = <Future<void>>[
      _storage.write(key: _tokenKey, value: tokenToSave),
      _storage.write(key: _userIdKey, value: userId),
      _storage.write(key: _usernameKey, value: nameToSave),
      _storage.write(key: _phoneKey, value: normalizedPhone),
    ];
    if (expiresAt != null) {
      writes.add(
        _storage.write(key: _expiryKey, value: expiresAt.toIso8601String()),
      );
    } else {
      writes.add(_storage.delete(key: _expiryKey));
    }
    if (secret.trim().isNotEmpty) {
      writes.add(_storage.write(key: _secretKey, value: secret.trim()));
    }
    await Future.wait(writes);
    await _archiveProfile(
      phone: normalizedPhone,
      userId: userId,
      username: nameToSave,
      secret: secret,
      token: tokenToSave,
      expiresAt: expiresAt,
    );

    // Do not block onboarding on Matrix. A slow/unreachable homeserver must not
    // trap the user on the OTP screen after Wrytte auth has succeeded.
    if (secret.trim().isNotEmpty) {
      final generation = ++_matrixBootstrapGeneration;
      await _tryLoginToMatrix(
        userId: userId,
        nickname: nameToSave,
        generation: generation,
        preferRegisterFirst: preferMatrixRegisterFirst,
      ).timeout(
        matrixBootstrapTimeout,
        onTimeout: () {
          debugPrint('[AuthService] Matrix bootstrap timed out; continuing.');
        },
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Send SMS / email codes (dev stubs)
  // ---------------------------------------------------------------------------
  Future<void> sendSmsCode(String phone) async {
    final normalizedPhone = _normalizePhone(phone);
    _pendingPhoneOtps[normalizedPhone] = '112233';
    debugPrint(
      '[AuthService] OTP ready for $normalizedPhone (dev: use 112233)',
    );
  }

  Future<void> sendEmailCode(String email) async {
    final normalizedEmail = email.trim().toLowerCase();
    _pendingEmailOtps[normalizedEmail] = '112233';
    debugPrint('[AuthService] Email OTP ready for $normalizedEmail');
  }

  // ---------------------------------------------------------------------------
  // Register with real phone number (fallback — used when Simon's API
  // is not available; normally real_number_service.dart calls Simon's API)
  // ---------------------------------------------------------------------------
  Future<AuthUser> registerRealPhone({
    required String phone,
    required String code,
    String? username,
    bool login = true,
  }) async {
    final normalizedPhone = _normalizePhone(phone);
    final expected = _pendingPhoneOtps[normalizedPhone];
    if (expected == null) {
      throw Exception('No OTP session found for $normalizedPhone.');
    }
    if (code.trim() != expected) throw Exception('Invalid verification code.');

    final userId = _phoneToUserId(normalizedPhone);
    final effectiveUsername = username ?? normalizedPhone;

    final user = AuthUser(
      userId: userId,
      username: effectiveUsername,
      secret: userId,
      token: userId,
      phone: normalizedPhone,
    );

    if (login) {
      // Use userId as a placeholder secret — real secret comes from Simon's API
      await persistPhoneSession(
        userId: userId,
        username: effectiveUsername,
        phone: normalizedPhone,
        secret: userId,
      );
    }

    _pendingPhoneOtps.remove(normalizedPhone);
    return user;
  }

  Future<AuthUser> authenticatePhone({
    required String phone,
    required String code,
    String? username,
  }) async {
    final savedUser = await getCurrentUser();
    if (savedUser != null && savedUser.isAuthenticated) {
      await MatrixAuthService.instance.restore();
      return savedUser;
    }
    return registerRealPhone(
      phone: phone,
      code: code,
      username: username,
      login: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Register with virtual phone number (fallback stub)
  // ---------------------------------------------------------------------------
  Future<AuthUser> registerVirtualPhone({
    required String email,
    required String code,
    required String phone,
    String? username,
    bool login = true,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    final expected = _pendingEmailOtps[normalizedEmail];
    if (expected == null) {
      throw Exception('No OTP session found for $normalizedEmail.');
    }
    if (code.trim() != expected) throw Exception('Invalid verification code.');

    final userId = phone.replaceAll(RegExp(r'[^\d]'), '');
    final effectiveUsername = username ?? normalizedEmail.split('@').first;

    final user = AuthUser(
      userId: userId,
      username: effectiveUsername,
      secret: userId,
      token: userId,
      phone: phone,
    );

    if (login) {
      await persistPhoneSession(
        userId: userId,
        username: effectiveUsername,
        phone: phone,
        secret: userId,
      );
    }

    _pendingEmailOtps.remove(normalizedEmail);
    return user;
  }

  // ---------------------------------------------------------------------------
  // Session reads
  // ---------------------------------------------------------------------------
  Future<AuthUser?> getCurrentUser() async {
    final token = await _storage.read(key: _tokenKey);
    final userId = await _storage.read(key: _userIdKey) ?? '';
    if ((token == null || token.isEmpty) && userId.isEmpty) return null;

    final expiryString = await _storage.read(key: _expiryKey);
    return AuthUser(
      userId: userId,
      username: await _storage.read(key: _usernameKey) ?? '',
      secret: await _storage.read(key: _secretKey) ?? '',
      token: token ?? '',
      phone: await _storage.read(key: _phoneKey),
      expiresAt: expiryString != null ? DateTime.tryParse(expiryString) : null,
    );
  }

  Future<String?> getSavedPhone() async => _storage.read(key: _phoneKey);
  Future<String?> getCurrentUserId() async => _storage.read(key: _userIdKey);
  Future<String?> getToken() async => _storage.read(key: _tokenKey);
  Future<DateTime?> getBackendTokenExpiry() async {
    final expiryString = await _storage.read(key: _expiryKey);
    final storedExpiry =
        expiryString != null ? DateTime.tryParse(expiryString) : null;
    if (storedExpiry != null) return storedExpiry;

    return _jwtExpiry(await getToken());
  }

  Future<String?> getValidBackendToken() async {
    final token = await getToken();
    if (_looksLikeJwt(token) && !await _isBackendTokenExpired()) {
      return token;
    }

    final refreshed = await _refreshBackendToken();
    if (refreshed != null && refreshed.trim().isNotEmpty) return refreshed;
    return token;
  }

  Future<bool> _isBackendTokenExpired() async {
    final expiresAt = await getBackendTokenExpiry();
    if (expiresAt == null) return false;
    return !expiresAt.isAfter(DateTime.now());
  }

  Future<String?> getStoredSecret() async => _storage.read(key: _secretKey);
  Future<String?> getCurrentUsername() async =>
      _storage.read(key: _usernameKey);
  Future<String?> getMatrixAccessToken() async =>
      _storage.read(key: MatrixAuthService.matrixAccessTokenKey);
  Future<String?> getChatToken() async => getMatrixAccessToken();

  Future<StoredAuthProfile?> findArchivedProfileByPhone(String phone) async {
    final archive = await _readProfileArchive();
    final normalizedPhone = _normalizePhone(phone);
    final raw = archive[normalizedPhone];
    if (raw is! Map) return null;

    final userId = raw['userId']?.toString().trim() ?? '';
    final username = raw['username']?.toString().trim() ?? '';
    final secret = raw['secret']?.toString().trim() ?? '';
    final token = raw['token']?.toString().trim();
    final expiresAt = DateTime.tryParse(
      raw['expiresAt']?.toString().trim() ?? '',
    );
    if (userId.isEmpty || username.isEmpty) {
      return null;
    }

    return StoredAuthProfile(
      userId: userId,
      username: username,
      phone: normalizedPhone,
      secret: secret,
      token: _looksLikeJwt(token) ? token : null,
      expiresAt: expiresAt,
    );
  }

  Future<String?> _refreshBackendToken() async {
    final phone = await getSavedPhone();
    final userId = await getCurrentUserId();
    if ((phone == null || phone.trim().isEmpty) &&
        (userId == null || userId.trim().isEmpty)) {
      return null;
    }

    final archivedProfile =
        phone == null || phone.trim().isEmpty
            ? null
            : await findArchivedProfileByPhone(phone);
    final storedSecret = (await getStoredSecret())?.trim() ?? '';
    final secret =
        storedSecret.isNotEmpty
            ? storedSecret
            : archivedProfile?.secret.trim() ?? '';
    if (secret.isEmpty) return null;

    try {
      final response = await ApiService.postMultipart('/auth/login', {
        'secret': secret,
        if (phone != null && phone.trim().isNotEmpty)
          'phone': phone.replaceAll(RegExp(r'[^\d]'), ''),
        if (userId != null && userId.trim().isNotEmpty) 'userid': userId.trim(),
      });
      if (response is! Map) return null;

      final refreshedToken = (response['token'] as String? ?? '').trim();
      if (!_looksLikeJwt(refreshedToken)) return null;

      final refreshedUserId =
          (response['userid'] as String? ?? userId ?? '').trim();
      final refreshedUsername = (response['username'] as String? ?? '').trim();
      final refreshedSecret = (response['secret'] as String? ?? '').trim();
      final expiresAt = DateTime.tryParse(
        (response['expires'] ?? '').toString(),
      );
      final profileNameToSave = _firstRealProfileName([
        refreshedUsername,
        archivedProfile?.username,
        await getCurrentUsername(),
      ]);

      final writes = <Future<void>>[
        _storage.write(key: _tokenKey, value: refreshedToken),
        if (refreshedUserId.isNotEmpty)
          _storage.write(key: _userIdKey, value: refreshedUserId),
        if (profileNameToSave != null)
          _storage.write(key: _usernameKey, value: profileNameToSave),
        if (refreshedSecret.isNotEmpty)
          _storage.write(key: _secretKey, value: refreshedSecret),
      ];
      if (expiresAt != null) {
        writes.add(
          _storage.write(key: _expiryKey, value: expiresAt.toIso8601String()),
        );
      }
      await Future.wait(writes);
      final archivePhone = phone ?? archivedProfile?.phone ?? '';
      final archiveUserId =
          refreshedUserId.isNotEmpty
              ? refreshedUserId
              : archivedProfile?.userId ?? '';
      final archiveUsername =
          profileNameToSave ?? archivedProfile?.username ?? '';
      if (archivePhone.isNotEmpty &&
          archiveUserId.isNotEmpty &&
          archiveUsername.isNotEmpty) {
        await _archiveProfile(
          phone: archivePhone,
          userId: archiveUserId,
          username: archiveUsername,
          secret: refreshedSecret.isNotEmpty ? refreshedSecret : secret,
          token: refreshedToken,
          expiresAt: expiresAt,
        );
      }
      return refreshedToken;
    } catch (e) {
      debugPrint('[AuthService] Backend token refresh failed: $e');
      return null;
    }
  }

  bool _looksLikeJwt(String? token) {
    if (token == null || token.trim().isEmpty) return false;
    return token.trim().split('.').length == 3;
  }

  DateTime? _jwtExpiry(String? token) {
    if (!_looksLikeJwt(token)) return null;
    try {
      final payload = token!.trim().split('.')[1];
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(payload))),
      );
      if (decoded is! Map) return null;
      final rawExp = decoded['exp'];
      final seconds =
          rawExp is num
              ? rawExp.toInt()
              : int.tryParse(rawExp?.toString() ?? '');
      if (seconds == null || seconds <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> _readProfileArchive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_profileArchiveKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return Map<String, Object?>.from(decoded);
      }
    } catch (e) {
      debugPrint('[AuthService] Profile archive read failed: $e');
    }
    return {};
  }

  Future<void> _archiveProfile({
    required String phone,
    required String userId,
    required String username,
    String? secret,
    String? token,
    DateTime? expiresAt,
  }) async {
    final normalizedPhone = _normalizePhone(phone);
    final cleanUserId = userId.trim();
    final cleanUsername = username.trim();
    if (normalizedPhone.isEmpty ||
        cleanUserId.isEmpty ||
        !_hasRealProfileName(cleanUsername)) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final archive = await _readProfileArchive();
      final existingRaw = archive[normalizedPhone];
      final existing =
          existingRaw is Map
              ? Map<String, Object?>.from(existingRaw)
              : <String, Object?>{};
      final next = <String, Object?>{
        ...existing,
        'userId': cleanUserId,
        'username': cleanUsername,
      };
      final cleanSecret = secret?.trim() ?? '';
      if (cleanSecret.isNotEmpty) next['secret'] = cleanSecret;
      final cleanToken = token?.trim() ?? '';
      if (_looksLikeJwt(cleanToken)) next['token'] = cleanToken;
      if (expiresAt != null) {
        next['expiresAt'] = expiresAt.toIso8601String();
      }
      archive[normalizedPhone] = next;
      await prefs.setString(_profileArchiveKey, jsonEncode(archive));
    } catch (e) {
      debugPrint('[AuthService] Profile archive write failed: $e');
    }
  }

  Future<StoredAuthProfile?> findUserProfileByPhone(String phone) async {
    final savedPhone = await getSavedPhone();
    final savedUserId = await getCurrentUserId();
    final savedName = await getCurrentUsername();
    if (savedPhone == null ||
        _normalizePhone(savedPhone) != _normalizePhone(phone) ||
        savedUserId == null ||
        savedUserId.isEmpty) {
      return null;
    }
    return StoredAuthProfile(
      userId: savedUserId,
      username: savedName ?? savedPhone,
      phone: _normalizePhone(savedPhone),
    );
  }

  Future<StoredAuthProfile?> hydrateStoredProfile(String userId) async {
    final savedUserId = await getCurrentUserId();
    if (savedUserId == userId) {
      final username = await getCurrentUsername() ?? '';
      final phone = _normalizePhone(await getSavedPhone() ?? '');
      if (_hasRealProfileName(username)) {
        return StoredAuthProfile(
          userId: userId,
          username: username.trim(),
          phone: phone,
        );
      }
    }

    return _findArchivedProfileByUserId(userId);
  }

  // ---------------------------------------------------------------------------
  // Update display name in storage and on Matrix
  // ---------------------------------------------------------------------------
  Future<void> updateStoredUsername(String username) async {
    if (username.trim().isEmpty) return;
    final trimmed = username.trim();
    await _storage.write(key: _usernameKey, value: trimmed);
    final phone = await getSavedPhone();
    final userId = await getCurrentUserId();
    if (phone != null &&
        phone.trim().isNotEmpty &&
        userId != null &&
        userId.trim().isNotEmpty &&
        !_looksLikePhone(trimmed)) {
      await _archiveProfile(phone: phone, userId: userId, username: trimmed);
    }
    final client =
        MatrixClientService.instance.isInitialized
            ? MatrixClientService.instance.client
            : null;
    if (client?.userID != null) {
      try {
        await client!.setProfileField(client.userID!, 'displayname', {
          'displayname': username.trim(),
        });
      } catch (e) {
        debugPrint('[AuthService] Matrix display-name update failed: $e');
      }
    }
  }

  Future<bool> isLoggedIn() async {
    final user = await getCurrentUser();
    return user != null && user.isAuthenticated;
  }

  User? get firebaseCurrentUser => _firebaseAuth.currentUser;

  // ---------------------------------------------------------------------------
  // Logout
  // ---------------------------------------------------------------------------
  Future<void> logout() async {
    _matrixBootstrapGeneration++;
    try {
      await ChatService().reset().timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('[AuthService] Chat reset timeout/error during logout: $e');
    }
    try {
      await MatrixAuthService.instance.clearStoredSession().timeout(
        const Duration(seconds: 3),
      );
    } catch (e) {
      debugPrint(
        '[AuthService] Matrix local session clear timeout/error; continuing: $e',
      );
    }
    try {
      await _firebaseAuth.signOut();
    } catch (e) {
      debugPrint('[AuthService] Firebase sign-out error: $e');
    }
    try {
      await _storage.deleteAll();
    } catch (e) {
      debugPrint('[AuthService] secure storage clear failed: $e');
    }
  }

  Future<void> signOutFirebase() async {
    try {
      await _firebaseAuth.signOut();
    } catch (e) {
      debugPrint('[AuthService] signOutFirebase error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------
  Future<void> _tryLoginToMatrix({
    required String userId,
    required String nickname,
    int? generation,
    bool preferRegisterFirst = false,
  }) async {
    try {
      await loginToMatrix(
        userId: userId,
        nickname: nickname,
        generation: generation,
        preferRegisterFirst: preferRegisterFirst,
      );
    } catch (e) {
      debugPrint('[AuthService] Matrix bootstrap skipped: $e');
    }
  }

  Future<bool> _isCurrentMatrixBootstrap(String userId, int? generation) async {
    if (generation != null && generation != _matrixBootstrapGeneration) {
      return false;
    }
    final currentUserId = await _storage.read(key: _userIdKey);
    return currentUserId == userId;
  }

  Future<void> _logoutMatrixUserIfMatches(String userId) async {
    if (!MatrixClientService.instance.isInitialized) return;
    final expectedMxid = '@$userId:${MatrixConfig.serverName}';
    final client = MatrixClientService.instance.client;
    if (client.userID != expectedMxid) return;
    try {
      await MatrixAuthService.instance.logout();
    } catch (e) {
      debugPrint('[AuthService] stale Matrix logout failed: $e');
    }
  }

  String _phoneToUserId(String normalizedPhone) =>
      normalizedPhone.replaceAll(RegExp(r'[^\d]'), '');

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00')) cleaned = '+${cleaned.substring(2)}';
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }

  bool _looksLikePhone(String value) {
    final s = value.replaceAll(RegExp(r'[\s\-()+]'), '');
    return RegExp(r'^\d{6,}$').hasMatch(s);
  }

  bool _hasRealProfileName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.length < 2) return false;
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return false;
    }
    if (_looksLikePhone(trimmed)) return false;
    final localpart =
        trimmed.startsWith('@')
            ? trimmed.substring(1).split(':').first
            : trimmed.split(':').first;
    if (RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart)) {
      return false;
    }
    return true;
  }

  String? _firstRealProfileName(Iterable<String?> names) {
    for (final name in names) {
      if (_hasRealProfileName(name)) return name!.trim();
    }
    return null;
  }

  Future<StoredAuthProfile?> _findArchivedProfileByUserId(String userId) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty) return null;

    final archive = await _readProfileArchive();
    for (final entry in archive.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final archivedUserId = raw['userId']?.toString().trim() ?? '';
      if (archivedUserId != cleanUserId) continue;

      final username = raw['username']?.toString().trim() ?? '';
      if (!_hasRealProfileName(username)) continue;

      final secret = raw['secret']?.toString().trim() ?? '';
      final token = raw['token']?.toString().trim();
      final expiresAt = DateTime.tryParse(
        raw['expiresAt']?.toString().trim() ?? '',
      );
      return StoredAuthProfile(
        userId: cleanUserId,
        username: username,
        phone: entry.key,
        secret: secret,
        token: _looksLikeJwt(token) ? token : null,
        expiresAt: expiresAt,
      );
    }

    return null;
  }
}
