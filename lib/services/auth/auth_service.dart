import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;

  final Map<String, String> _pendingPhoneOtps = {};
  final Map<String, String> _pendingEmailOtps = {};

  static const _tokenKey = 'auth_token';
  static const _expiryKey = 'auth_token_expiry';
  static const _userIdKey = 'user_id';
  static const _usernameKey = 'username';
  static const _secretKey = 'secret';
  static const _phoneKey = 'phone';
  static const _matrixPasswordKey = 'matrix_password';

  static const _defaultHomeserver = MatrixConfig.homeserver;

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

  Future<void> loginToMatrix({
    required String userId,
    required String nickname,
    String homeserver = _defaultHomeserver,
  }) async {
    final password = await _matrixPasswordForUser(userId);
    try {
      await MatrixAuthService.instance.login(
        username: userId,
        password: password,
        homeserver: homeserver,
      );
    } catch (_) {
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
          'displayname',
          {'displayname': nickname.trim()},
        );
      } catch (e) {
        debugPrint('[AuthService] Matrix display-name update failed: $e');
      }
    }
    try {
      await _firestore.collection('users').doc(userId).set({
        'matrixUserId': client.userID,
        'matrixHomeserver': client.baseUri?.toString(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[AuthService] Matrix identity persistence failed: $e');
    }
  }

  Future<void> logoutFromMatrix() => MatrixAuthService.instance.logout();

  Future<void> persistPhoneSession({
    required String userId,
    required String username,
    required String phone,
    String imToken = '',
    String chatToken = '',
  }) async {
    await Future.wait([
      _storage.write(key: _tokenKey, value: userId),
      _storage.write(key: _userIdKey, value: userId),
      _storage.write(key: _usernameKey, value: username),
      _storage.write(key: _secretKey, value: userId),
      _storage.write(key: _phoneKey, value: phone),
      _storage.delete(key: _expiryKey),
    ]);

    await ensureFirebaseAuth();
    await _ensureUserDocument(uid: userId, phone: phone, username: username);
    await _tryLoginToMatrix(userId: userId, nickname: username);
  }

  Future<void> sendSmsCode(String phone) async {
    final normalizedPhone = _normalizePhone(phone);
    _pendingPhoneOtps[normalizedPhone] = '123456';
    debugPrint('[AuthService] OTP ready for $normalizedPhone (dev: use 123456)');
  }

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

    await ensureFirebaseAuth();
    await _ensureUserDocument(
      uid: userId,
      phone: normalizedPhone,
      username: effectiveUsername,
    );

    final user = AuthUser(
      userId: userId,
      username: effectiveUsername,
      secret: userId,
      token: userId,
      phone: normalizedPhone,
    );

    if (login) {
      await _persistAuth(user, phone: normalizedPhone);
      await _tryLoginToMatrix(userId: userId, nickname: effectiveUsername);
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

  Future<void> sendEmailCode(String email) async {
    final normalizedEmail = email.trim().toLowerCase();
    _pendingEmailOtps[normalizedEmail] = '123456';
    debugPrint('[AuthService] Email OTP ready for $normalizedEmail');
  }

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

    await ensureFirebaseAuth();
    await _ensureUserDocument(
      uid: userId,
      phone: phone,
      username: effectiveUsername,
    );

    final user = AuthUser(
      userId: userId,
      username: effectiveUsername,
      secret: userId,
      token: userId,
      phone: phone,
    );

    if (login) {
      await _persistAuth(user, phone: phone);
      await _tryLoginToMatrix(userId: userId, nickname: effectiveUsername);
    }

    _pendingEmailOtps.remove(normalizedEmail);
    return user;
  }

  Future<AuthUser?> getCurrentUser() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return null;

    final expiryString = await _storage.read(key: _expiryKey);
    return AuthUser(
      userId: await _storage.read(key: _userIdKey) ?? '',
      username: await _storage.read(key: _usernameKey) ?? '',
      secret: await _storage.read(key: _secretKey) ?? '',
      token: token,
      phone: await _storage.read(key: _phoneKey),
      expiresAt: expiryString != null ? DateTime.tryParse(expiryString) : null,
    );
  }

  Future<String?> getSavedPhone() async => _storage.read(key: _phoneKey);
  Future<String?> getCurrentUserId() async => _storage.read(key: _userIdKey);
  Future<String?> getToken() async => _storage.read(key: _tokenKey);
  Future<String?> getMatrixAccessToken() async =>
      _storage.read(key: MatrixAuthService.matrixAccessTokenKey);
  Future<String?> getChatToken() async => getMatrixAccessToken();

  Future<void> updateStoredUsername(String username) async {
    if (username.trim().isEmpty) return;
    await _storage.write(key: _usernameKey, value: username.trim());
    final client = MatrixClientService.instance.isInitialized
    ? MatrixClientService.instance.client
    : null;
    if (client?.userID != null) {
      await client!.setProfileField(
        client.userID!,
        'displayname',
        {'displayname': username.trim()},
      );
    }
  }

  Future<bool> isLoggedIn() async {
    final user = await getCurrentUser();
    return user != null && !user.isExpired && user.isAuthenticated;
  }

  User? get firebaseCurrentUser => _firebaseAuth.currentUser;

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

  Future<void> _ensureUserDocument({
    required String uid,
    String? phone,
    String? username,
  }) async {
    final userRef = _firestore.collection('users').doc(uid);
    final snapshot = await userRef.get();
    final existing = snapshot.data() ?? {};
    final now = FieldValue.serverTimestamp();
    final firebaseUid = _firebaseAuth.currentUser?.uid;

    await userRef.set({
      'uid': uid,
      'matrixUserId': MatrixClientService.instance.userId,
      'updatedAt': now,
      if (!snapshot.exists) 'createdAt': now,
      if (phone != null && phone.isNotEmpty) 'phone': _normalizePhone(phone),
      if (username != null && username.isNotEmpty) ...{
        'username': username,
        if ((existing['name'] == null ||
                (existing['name'] as String).isEmpty) &&
            !_looksLikePhone(username))
          'name': username,
      },
      if (firebaseUid != null) 'firebaseUid': firebaseUid,
      'isOnline': true,
      'lastSeen': now,
    }, SetOptions(merge: true));
  }

  Future<void> _persistAuth(AuthUser user, {String? phone}) async {
    await Future.wait([
      _storage.write(key: _tokenKey, value: user.token),
      _storage.write(key: _userIdKey, value: user.userId),
      _storage.write(key: _usernameKey, value: user.username),
      _storage.write(key: _secretKey, value: user.secret),
      if (phone != null && phone.isNotEmpty) _storage.write(key: _phoneKey, value: phone),
      _storage.delete(key: _expiryKey),
    ]);
  }

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

  Future<String> _matrixPasswordForUser(String userId) async {
    final key = '$_matrixPasswordKey:$userId';
    final saved = await _storage.read(key: key);
    if (saved != null && saved.length >= 32) return saved;

    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final password = base64UrlEncode(bytes);
    await _storage.write(key: key, value: password);
    return password;
  }

  String _phoneToUserId(String normalizedPhone) =>
      normalizedPhone.replaceAll(RegExp(r'[^\d]'), '');

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00')) cleaned = '+${cleaned.substring(2)}';
    if (!cleaned.startsWith('+')) cleaned = '+$cleaned';
    return cleaned;
  }

  bool _looksLikePhone(String value) {
    final s = value.replaceAll(RegExp(r'[\s\-()+]'), '');
    return RegExp(r'^\d{6,}$').hasMatch(s);
  }
}
