import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

class StoredAuthProfile {
  final String userId;
  final String username;
  final String phone;

  const StoredAuthProfile({
    required this.userId,
    required this.username,
    required this.phone,
  });

  bool get hasUsableName =>
      username.trim().length >= 2 &&
      !RegExp(r'^\+?\d{6,}$')
          .hasMatch(username.trim().replaceAll(RegExp(r'[\s\-()+]'), ''));
}

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;

  final Map<String, String> _pendingPhoneOtps = {};
  final Map<String, String> _pendingEmailOtps = {};

  static const _tokenKey   = 'auth_token';
  static const _expiryKey  = 'auth_token_expiry';
  static const _userIdKey  = 'user_id';
  static const _usernameKey = 'username';
  static const _secretKey  = 'secret';
  static const _phoneKey   = 'phone';

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
  }) async {
    // Use Simon's secret as the one and only Matrix password.
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.trim().isEmpty) {
      debugPrint('[AuthService] No secret stored — Matrix login skipped.');
      return;
    }
    final password = secret.trim();

    try {
      await MatrixAuthService.instance.login(
        username: userId,
        password: password,
        homeserver: homeserver,
      );
    } catch (_) {
      // Account may not exist yet on this server — register it.
      await MatrixAuthService.instance.register(
        username: userId,
        password: password,
        homeserver: homeserver,
      );
    }

    final client = MatrixClientService.instance.client;
    if (nickname.trim().isNotEmpty) {
      try {
        await client.setProfileField(
          client.userID!,
          'm.displayname',
          {'displayname': nickname.trim()},
        );
      } catch (e) {
        debugPrint('[AuthService] Matrix display-name update failed: $e');
      }
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
  }) async {
    // Never overwrite a real stored name with a phone-number fallback.
    final currentName = await _storage.read(key: _usernameKey);
    final normalizedPhone = _normalizePhone(phone);
    final nameToSave = (currentName != null && !_looksLikePhone(currentName))
        ? currentName.trim()
        : username.trim();

    // Save secret first so loginToMatrix() can read it immediately.
    final writes = <Future<void>>[
      _storage.write(key: _tokenKey, value: userId),
      _storage.write(key: _userIdKey, value: userId),
      _storage.write(key: _usernameKey, value: nameToSave),
      _storage.write(key: _phoneKey, value: normalizedPhone),
      _storage.delete(key: _expiryKey),
    ];
    if (secret.trim().isNotEmpty) {
      writes.add(_storage.write(key: _secretKey, value: secret.trim()));
    }
    await Future.wait(writes);

    // Matrix login runs in background — does not block UI navigation.
    unawaited(_tryLoginToMatrix(userId: userId, nickname: nameToSave));
  }
  // ---------------------------------------------------------------------------
  // Send SMS / email codes (dev stubs)
  // ---------------------------------------------------------------------------
  Future<void> sendSmsCode(String phone) async {
    final normalizedPhone = _normalizePhone(phone);
    _pendingPhoneOtps[normalizedPhone] = '112233';
    debugPrint('[AuthService] OTP ready for $normalizedPhone (dev: use 112233)');
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
      userId:   userId,
      username: effectiveUsername,
      secret:   userId,
      token:    userId,
      phone:    normalizedPhone,
    );

    if (login) {
      // Use userId as a placeholder secret — real secret comes from Simon's API
      await persistPhoneSession(
        userId:   userId,
        username: effectiveUsername,
        phone:    normalizedPhone,
        secret:   userId,
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
      userId:   userId,
      username: effectiveUsername,
      secret:   userId,
      token:    userId,
      phone:    phone,
    );

    if (login) {
      await persistPhoneSession(
        userId:   userId,
        username: effectiveUsername,
        phone:    phone,
        secret:   userId,
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
    if (token == null) return null;

    final expiryString = await _storage.read(key: _expiryKey);
    return AuthUser(
      userId:    await _storage.read(key: _userIdKey)   ?? '',
      username:  await _storage.read(key: _usernameKey) ?? '',
      secret:    await _storage.read(key: _secretKey)   ?? '',
      token:     token,
      phone:     await _storage.read(key: _phoneKey),
      expiresAt: expiryString != null ? DateTime.tryParse(expiryString) : null,
    );
  }

  Future<String?> getSavedPhone() async => _storage.read(key: _phoneKey);
  Future<String?> getCurrentUserId() async => _storage.read(key: _userIdKey);
  Future<String?> getToken() async => _storage.read(key: _tokenKey);
  Future<String?> getStoredSecret() async => _storage.read(key: _secretKey);
  Future<String?> getCurrentUsername() async => _storage.read(key: _usernameKey);
  Future<String?> getMatrixAccessToken() async =>
      _storage.read(key: MatrixAuthService.matrixAccessTokenKey);
  Future<String?> getChatToken()         async => getMatrixAccessToken();

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

  Future<StoredAuthProfile?> hydrateStoredProfile(
    String userId,
  ) async {
    final savedUserId = await getCurrentUserId();
    if (savedUserId != userId) return null;
    final username = await getCurrentUsername() ?? '';
    final phone = _normalizePhone(await getSavedPhone() ?? '');
    return StoredAuthProfile(userId: userId, username: username, phone: phone);
  }

  // ---------------------------------------------------------------------------
  // Update display name in storage and on Matrix
  // ---------------------------------------------------------------------------
  Future<void> updateStoredUsername(String username) async {
    if (username.trim().isEmpty) return;
    await _storage.write(key: _usernameKey, value: username.trim());
    final client = MatrixClientService.instance.isInitialized
        ? MatrixClientService.instance.client
        : null;
    if (client?.userID != null) {
      try {
        await client!.setProfileField(
          client.userID!,
          'm.displayname',
          {'displayname': username.trim()},
        );
      } catch (e) {
        debugPrint('[AuthService] Matrix display-name update failed: $e');
      }
    }
  }

  Future<bool> isLoggedIn() async {
    final user = await getCurrentUser();
    return user != null && !user.isExpired && user.isAuthenticated;
  }

  User? get firebaseCurrentUser => _firebaseAuth.currentUser;

  // ---------------------------------------------------------------------------
  // Logout
  // ---------------------------------------------------------------------------
  Future<void> logout() async {
    await ChatService().reset();
    await logoutFromMatrix();
    try {
      await _firebaseAuth.signOut();
    } catch (e) {
      debugPrint('[AuthService] Firebase sign-out error: $e');
    }
    await _storage.deleteAll();
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
  }) async {
    try {
      await loginToMatrix(userId: userId, nickname: nickname);
    } catch (e) {
      debugPrint('[AuthService] Matrix bootstrap skipped: $e');
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

}
