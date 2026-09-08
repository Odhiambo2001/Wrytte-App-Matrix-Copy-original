import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/attachment_local_store.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'package:wrytte/utils/wrytte_id.dart';

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

class WrytteIdSignInSearchResult {
  const WrytteIdSignInSearchResult({
    required this.exists,
    required this.userId,
  });

  final bool exists;
  final String userId;
}

class KFaceRecoveryData {
  const KFaceRecoveryData({
    required this.userId,
    required this.wrytteId,
    required this.kmap,
    required this.challenge,
  });

  final String userId;
  final String wrytteId;
  final Map<String, dynamic> kmap;
  final String challenge;
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
  Future<String?>? _pendingTokenRefresh;
  String? _cachedBackendToken;

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
    if (inFlight != null &&
        _matrixLoginInFlightUserId == cleanUserId &&
        inFlightIsCurrent) {
      apkLog(
        'Matrix.auth',
        'join in-flight login user_id="$cleanUserId" force_fresh=$forceFreshSession',
      );
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
    final expectedMatrixUserId = '@$userId:${MatrixConfig.serverName}';
    final current =
        MatrixClientService.instance.isInitialized
            ? MatrixClientService.instance.client
            : null;
    if (!forceFreshSession &&
        current?.isLogged() == true &&
        current?.userID == expectedMatrixUserId) {
      await MatrixAuthService.instance.persistCurrentSession();
      apkLog(
        'Matrix.auth',
        'login skipped; active session already matches user_id="$userId"',
      );
      if (nickname.trim().isNotEmpty) {
        unawaited(_updateMatrixDisplayName(current!, nickname.trim()));
      }
      return;
    }

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
      } catch (e) {
        final current =
            MatrixClientService.instance.isInitialized
                ? MatrixClientService.instance.client
                : null;
        if (current?.isLogged() == true &&
            current?.userID == expectedMatrixUserId) {
          await MatrixAuthService.instance.persistCurrentSession();
          apkLog(
            'Matrix.auth',
            'login response usable despite post-login error user_id="$userId" error="$e"',
          );
        } else {
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
            'login failed; register request user_id="$userId" error="$e"',
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

  Future<void> _updateMatrixDisplayName(mx.Client _, String __) async {
    // Individual Wrytte profiles are backend-authoritative. Writing the same
    // name to Matrix during login is redundant and can race token restoration.
    apkLog('Matrix.auth', 'display name sync skipped; backend authoritative');
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
    bool preferMatrixRegisterFirst = false,
    bool deferNonEssentialInitialization = false,
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
    if (_looksLikeJwt(tokenToSave)) _cachedBackendToken = tokenToSave;

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

    final initialization = _finishSessionInitialization(
      userId: userId,
      username: nameToSave,
      phone: normalizedPhone,
      secret: secret,
      token: tokenToSave,
      expiresAt: expiresAt,
      preferMatrixRegisterFirst: preferMatrixRegisterFirst,
    );
    if (deferNonEssentialInitialization) {
      // Profile Setup needs an authenticated local session, not a completed
      // Matrix sync. Keep expensive network/cache work off its critical path.
      unawaited(
        initialization.catchError((Object error, StackTrace stackTrace) {
          apkLog(
            'Auth.deferredInitialization',
            'failed type="${error.runtimeType}"',
          );
          debugPrintStack(stackTrace: stackTrace);
        }),
      );
      return;
    }
    await initialization;
  }

  Future<void> _finishSessionInitialization({
    required String userId,
    required String username,
    required String phone,
    required String secret,
    required String token,
    required DateTime? expiresAt,
    required bool preferMatrixRegisterFirst,
  }) async {
    // Avoid applying late background initialization to an account that logged
    // out or was replaced while Profile Setup was already visible.
    if (await _storage.read(key: _userIdKey) != userId) return;
    try {
      await ChatLocalDb.instance.bindOwner(userId);
      // Populate the owner-scoped in-memory timeline before any Matrix network
      // bootstrap. A disposable cache failure must not invalidate an already
      // successful backend login.
      await ChatService().hydrateLocalConversations(syncReadMarkers: false);
    } catch (error, stackTrace) {
      apkLog('Auth.login', 'local chat cache hydration skipped error="$error"');
      debugPrintStack(stackTrace: stackTrace);
    }
    await _archiveProfile(
      phone: phone,
      userId: userId,
      username: username,
      secret: secret,
      token: token,
      expiresAt: expiresAt,
    );

    if (secret.trim().isNotEmpty) {
      final generation = ++_matrixBootstrapGeneration;
      await _tryLoginToMatrix(
        userId: userId,
        nickname: username,
        generation: generation,
        preferRegisterFirst: preferMatrixRegisterFirst,
      );
      // Login completion must not wait for room-by-room Matrix history.
      // Incremental sync/backfill updates the already-visible local snapshot.
      unawaited(
        ChatService().prepareAllHistoryForLogin().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          apkLog(
            'Matrix.loginHydration',
            'background preparation failed error="$error"',
          );
        }),
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

  Future<AuthUser> registerWrytteId({
    required String wrytteId,
    String? username,
    bool login = true,
  }) async {
    final backendWrytteId = WrytteId.forBackend(wrytteId);
    final response = await ApiService.postMultipart('/auth/register/wrytteid', {
      'wrytteId': backendWrytteId,
      if (username != null && username.trim().isNotEmpty)
        'username': username.trim(),
      'login': login.toString(),
    });
    if (response is! Map) {
      throw Exception('Invalid Wrytte ID registration response.');
    }

    final user = AuthUser.fromJson(Map<String, dynamic>.from(response));
    if (user.userId.isEmpty) {
      throw Exception(
        'Invalid Wrytte ID registration response: missing userid.',
      );
    }

    if (login) {
      await persistPhoneSession(
        userId: user.userId,
        username:
            user.username.trim().isNotEmpty ? user.username.trim() : wrytteId,
        phone: user.phone ?? wrytteId,
        secret: user.secret,
        token: user.token,
        expiresAt: user.expiresAt,
        preferMatrixRegisterFirst: true,
      );
    }
    return user;
  }

  Future<void> saveKFaceRecoveryData({
    required String userId,
    required String wrytteId,
    required Map<String, dynamic> kmap,
    required String publicKey,
    String? token,
  }) async {
    final backendWrytteId = WrytteId.forBackend(wrytteId);
    _validateClientKFaceRecoveryData(kmap, publicKey);
    await ApiService.postJson(
      '/auth/register/wrytteid/kface',
      token: token,
      body: {
        'userId': userId,
        'wrytteId': backendWrytteId,
        'kmap': kmap,
        'publicKey': publicKey,
      },
    );
  }

  /// Finalizes a Wrytte-ID account only after this device has constructed its
  /// LDPC recovery commitment and Ed25519 public key. The opaque ticket comes
  /// from an accepted five-frame biometric capture and expires server-side.
  Future<AuthUser> completeClientBiometricEnrollment({
    required String wrytteId,
    required String biometricEnrollmentTicket,
    required Map<String, dynamic> kmap,
    required String publicKey,
  }) async {
    final backendWrytteId = WrytteId.forBackend(wrytteId);
    _validateClientKFaceRecoveryData(kmap, publicKey);
    final response = await ApiService.postJson(
      '/auth/register/wrytteid/kface',
      body: {
        'wrytteId': backendWrytteId,
        'kmap': kmap,
        'publicKey': publicKey,
        'biometricEnrollmentTicket': biometricEnrollmentTicket,
      },
    );
    if (response is! Map) {
      throw Exception('Invalid biometric enrollment response.');
    }
    final user = AuthUser.fromJson(Map<String, dynamic>.from(response));
    if (user.userId.isEmpty || user.token.isEmpty) {
      throw Exception('Biometric enrollment was not accepted.');
    }
    await persistPhoneSession(
      userId: user.userId,
      username: user.username.trim().isNotEmpty ? user.username : wrytteId,
      phone: user.phone ?? wrytteId,
      secret: user.secret,
      token: user.token,
      expiresAt: user.expiresAt,
      preferMatrixRegisterFirst: true,
      deferNonEssentialInitialization: true,
    );
    return user;
  }

  void _validateClientKFaceRecoveryData(
    Map<String, dynamic> kmap,
    String publicKey,
  ) {
    final commitment = FuzzyCommitment.fromJson(kmap);
    final normalizedPublicKey = publicKey.trim();
    if (commitment.signingPublicKey == null ||
        commitment.signingPublicKey != normalizedPublicKey) {
      throw const FormatException('Invalid biometric signing key.');
    }
  }

  Future<WrytteIdSignInSearchResult> searchWrytteIdForSignIn(
    String wrytteId,
  ) async {
    final backendWrytteId = WrytteId.forBackend(wrytteId);
    final response = await ApiService.postMultipart(
      '/auth/signin/wrytteid/search',
      {'wrytteId': backendWrytteId},
    );
    if (response is! Map) {
      throw Exception('Invalid Wrytte ID search response.');
    }
    final existsRaw = response['exists'];
    final exists =
        existsRaw is bool
            ? existsRaw
            : existsRaw?.toString().toLowerCase() == 'true';
    final userId =
        (response['userid'] ?? response['userId'] ?? '').toString().trim();
    if (exists && userId.isEmpty) {
      throw Exception('Invalid Wrytte ID search response: missing userid.');
    }
    return WrytteIdSignInSearchResult(exists: exists, userId: userId);
  }

  Future<KFaceRecoveryData> getKFaceRecoveryData({
    String? userId,
    String? wrytteId,
  }) async {
    final backendWrytteId =
        wrytteId == null || wrytteId.trim().isEmpty
            ? null
            : WrytteId.forBackend(wrytteId);
    final response = await ApiService.postMultipart(
      '/auth/signin/wrytteid/recovery',
      {
        if (userId != null && userId.trim().isNotEmpty) 'userid': userId.trim(),
        if (backendWrytteId != null) 'wrytteId': backendWrytteId,
      },
    );
    if (response is! Map) {
      throw Exception('Invalid K-Face recovery response.');
    }
    final rawKmap = response['kmap'];
    final kmap =
        rawKmap is Map
            ? Map<String, dynamic>.from(rawKmap)
            : jsonDecode(rawKmap?.toString() ?? '{}') as Map<String, dynamic>;
    return KFaceRecoveryData(
      userId:
          (response['userid'] ?? response['userId'] ?? userId ?? '')
              .toString()
              .trim(),
      wrytteId: (response['wrytteId'] ?? wrytteId ?? '').toString().trim(),
      kmap: kmap,
      challenge: (response['challenge'] ?? '').toString().trim(),
    );
  }

  Future<AuthUser> completeWrytteIdSignIn({
    required String userId,
    required String wrytteId,
    required String challenge,
    required String signature,
  }) async {
    final backendWrytteId = WrytteId.forBackend(wrytteId);
    final response = await ApiService.postJson(
      '/auth/signin/wrytteid/complete',
      body: {
        'userid': userId,
        'wrytteId': backendWrytteId,
        'challenge': challenge,
        'signature': signature,
      },
    );
    if (response is! Map) {
      throw Exception('Invalid Wrytte ID sign-in response.');
    }
    final user = AuthUser.fromJson(Map<String, dynamic>.from(response));
    if (user.userId.isEmpty) {
      throw Exception('Invalid Wrytte ID sign-in response: missing userid.');
    }
    await persistPhoneSession(
      userId: user.userId,
      username: user.username.trim().isNotEmpty ? user.username : wrytteId,
      phone: user.phone ?? wrytteId,
      secret: user.secret,
      token: user.token,
      expiresAt: user.expiresAt,
      preferMatrixRegisterFirst: false,
    );
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
  String? get cachedBackendToken => _cachedBackendToken;

  Future<String?> getToken() async {
    final token = await _storage.read(key: _tokenKey);
    if (_looksLikeJwt(token)) _cachedBackendToken = token!.trim();
    return token;
  }

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

    // ── Single-flight guard: all concurrent callers wait on ONE refresh ──
    _pendingTokenRefresh ??= _refreshBackendToken().whenComplete(
      () => _pendingTokenRefresh = null,
    );
    return _pendingTokenRefresh;
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

  Future<void> persistLoginPayloadCache({
    required Map<String, dynamic> payload,
    required String ownerUserId,
    String? displayName,
  }) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return;

    final avatar = _extractString(payload, const [
      'AvatarImg',
      'avatarImg',
      'avatar',
      'avatarUrl',
      'image',
      'profileImage',
      'profile_image',
      'ProfileImage',
    ]);
    final writes = <Future<void>>[];
    if (avatar.isNotEmpty) {
      writes.add(
        _storage.write(
          key: 'profile_image',
          value: _resolveBackendAssetUrl(avatar),
        ),
      );
    }

    final contacts = _extractContacts(payload);
    if (contacts.isNotEmpty) {
      writes.add(ContactLocalDb.saveContacts(contacts, ownerUserId: owner));
      ContactService.invalidateMatrixContactsCache();
    }

    final restoredMessages = _extractChatMessages(payload, owner);
    if (restoredMessages.isNotEmpty) {
      writes.add(ChatLocalDb.instance.saveMessages(restoredMessages));
    }

    final restoredConversations = _extractChatConversations(payload, owner);
    if (restoredConversations.isNotEmpty) {
      writes.add(ChatLocalDb.instance.saveConversations(restoredConversations));
    }

    final name = displayName?.trim() ?? '';
    if (_hasRealProfileName(name)) {
      final parts = name.split(RegExp(r'\s+'));
      writes.add(_storage.write(key: 'profile_first_name', value: parts.first));
      writes.add(
        _storage.write(
          key: 'profile_last_name',
          value: parts.length > 1 ? parts.sublist(1).join(' ') : '',
        ),
      );
    }

    if (writes.isEmpty) return;
    await Future.wait(writes);
    if (contacts.isNotEmpty) {
      final materialized = await ChatLocalDb.instance
          .materializeContactConversations(
            ownerUserId: owner,
            contacts: contacts,
          );
      if (materialized > 0) {
        debugPrint(
          '[AuthService] materialized $materialized contact-backed conversations',
        );
      }
    }
    debugPrint(
      '[AuthService] hydrated login payload cache contacts=${contacts.length} messages=${restoredMessages.length} conversations=${restoredConversations.length} avatar=${avatar.isNotEmpty}',
    );
  }

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
      final response = await ApiService.postMultipart('/auth/login/refresh', {
        'secret': secret,
        if (phone != null && phone.trim().isNotEmpty)
          'phone': phone.replaceAll(RegExp(r'[^\d]'), ''),
        if (userId != null && userId.trim().isNotEmpty) 'userid': userId.trim(),
      });
      if (response is! Map) return null;

      final refreshedToken = (response['token'] as String? ?? '').trim();
      if (!_looksLikeJwt(refreshedToken)) return null;
      _cachedBackendToken = refreshedToken;

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
    apkLog(
      'Auth.logout',
      'START secure logout; all local account data will be deleted',
    );
    _matrixBootstrapGeneration++;
    _pendingTokenRefresh = null;
    var localPurgeComplete = false;
    UserProfileService.instance.beginLogout();
    //ADD THIS — clear contact cache before any user switch
    ContactService.clearAllCachesForLogout();
    ContactService()
        .invalidateCache(); // clears _phoneUserMapCache and _cacheTime
    UserProfileService.instance.clearCache();
    UserAvatar.clearMemoryCache();
    AvatarPreloadService.clearMemoryCache();
    apkLog('Auth.logout', 'contact service memory caches cleared');
    try {
      await NotificationService.instance.stop().timeout(
        const Duration(seconds: 3),
      );
      apkLog('Auth.logout', 'notification service stopped');
    } catch (e) {
      apkLog('Auth.logout', 'notification service stop FAILED: $e');
      debugPrint('[AuthService] notification stop failed: $e');
    }
    try {
      await ChatService().reset().timeout(const Duration(seconds: 5));
      apkLog('Auth.logout', 'chat service reset complete');
    } catch (e) {
      apkLog('Auth.logout', 'chat service reset FAILED: $e');
      debugPrint('[AuthService] Chat reset timeout/error during logout: $e');
    }
    try {
      await MatrixAuthService.instance.clearStoredSession().timeout(
        const Duration(seconds: 3),
      );
      apkLog('Auth.logout', 'Matrix stored session cleared');
    } catch (e) {
      apkLog('Auth.logout', 'Matrix stored session clear FAILED: $e');
      debugPrint(
        '[AuthService] Matrix local session clear timeout/error; continuing: $e',
      );
    }
    try {
      await _purgeLocalLogoutData();
      localPurgeComplete = true;
      apkLog('Auth.logout', 'session-only local cleanup complete');
    } catch (e) {
      apkLog('Auth.logout', 'session-only local cleanup FAILED: $e');
      debugPrint('[AuthService] session-only logout cleanup failed: $e');
    }
    try {
      await _firebaseAuth.signOut();
      apkLog('Auth.logout', 'Firebase session signed out');
    } catch (e) {
      apkLog('Auth.logout', 'Firebase sign-out FAILED: $e');
      debugPrint('[AuthService] Firebase sign-out error: $e');
    }
    try {
      final secureValues = await _storage.readAll();
      final kfaceCommitments = Map<String, String>.fromEntries(
        secureValues.entries.where(
          (entry) => entry.key.startsWith('kface_ldpc_'),
        ),
      );
      await _storage.deleteAll();
      for (final entry in kfaceCommitments.entries) {
        await _storage.write(key: entry.key, value: entry.value);
      }
      apkLog(
        'Auth.logout',
        'secure session storage deleted; preserved '
            '${kfaceCommitments.length} KFace commitment(s)',
      );
    } catch (e) {
      apkLog('Auth.logout', 'secure storage delete FAILED: $e');
      debugPrint('[AuthService] secure storage clear failed: $e');
    }
    // Requests started by the outgoing widget tree can complete while the
    // disk purge is running. Clear process-wide caches again at the terminal
    // boundary so those late completions cannot leak into the next signup.
    ContactService.clearAllCachesForLogout();
    ContactService().invalidateCache();
    UserProfileService.instance.clearCache();
    UserAvatar.clearMemoryCache();
    AvatarPreloadService.clearMemoryCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    apkLog('Auth.logout', 'terminal memory cache purge complete');
    apkLog(
      'Auth.logout',
      localPurgeComplete
          ? 'DONE secure logout; local account data deleted'
          : 'DONE logout with PURGE FAILURE; inspect prior errors',
    );
  }

  Future<void> _purgeLocalLogoutData() async {
    _cachedBackendToken = null;
    apkLog('Auth.logout', 'backend token memory cache cleared');

    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    apkLog('Auth.logout', 'Flutter in-memory image cache cleared');

    final failures = <String>[];

    Future<void> purge(String label, Future<void> Function() action) async {
      try {
        await action();
        apkLog('Auth.logout', 'purged $label');
      } catch (error) {
        failures.add('$label: $error');
        apkLog('Auth.logout', 'purge FAILED $label error="$error"');
      }
    }

    await purge('chat databases', ChatLocalDb.instance.deleteAllLocalDatabases);
    await purge(
      'downloaded attachments',
      AttachmentLocalStore.instance.clearAll,
    );
    await purge(
      'Matrix stores and media',
      MatrixClientService.instance.deleteLocalStore,
    );

    final documents = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();

    Future<void> deleteDirectory(Directory directory) async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }

    await purge(
      'room avatars',
      () => deleteDirectory(Directory('${documents.path}/Wrytte Room Avatars')),
    );
    await purge(
      'profile avatars',
      () => deleteDirectory(Directory('${support.path}/profile_avatars')),
    );
    await purge('application disk cache', () async {
      if (!await cache.exists()) return;
      await for (final entity in cache.list()) {
        await entity.delete(recursive: true);
      }
    });
    await purge('shared preferences', () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.clear();
    });

    final attachmentDirectory = Directory(
      '${documents.path}/Wrytte Attachments',
    );
    final roomAvatarDirectory = Directory(
      '${documents.path}/Wrytte Room Avatars',
    );
    final profileAvatarDirectory = Directory('${support.path}/profile_avatars');
    final residualDirectories = <String>[
      if (await attachmentDirectory.exists()) attachmentDirectory.path,
      if (await roomAvatarDirectory.exists()) roomAvatarDirectory.path,
      if (await profileAvatarDirectory.exists()) profileAvatarDirectory.path,
    ];
    apkLog(
      'Auth.logout',
      'purge verification residual_directories=${residualDirectories.length} '
          'failures=${failures.length}',
    );
    if (failures.isNotEmpty || residualDirectories.isNotEmpty) {
      throw StateError(
        'Logout purge incomplete: ${[...failures, ...residualDirectories].join('; ')}',
      );
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

  String _resolveBackendAssetUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) return trimmed;
    if (trimmed.startsWith('/')) return '${ApiService.baseUrl}$trimmed';
    return '${ApiService.baseUrl}/$trimmed';
  }

  String _extractString(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      if (!source.containsKey(key)) continue;
      final value = source[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
    }
    return '';
  }

  List<Contact> _extractContacts(Map<String, dynamic> payload) {
    final raw =
        payload['contacts'] ??
        payload['Contacts'] ??
        payload['savedContacts'] ??
        payload['SavedContacts'];
    if (raw is! List) return const [];

    final contacts = <Contact>[];
    for (final entry in raw) {
      final contact = _contactFromLoginPayload(entry);
      if (contact != null) contacts.add(contact);
    }
    return contacts;
  }

  List<ChatConversation> _extractChatConversations(
    Map<String, dynamic> payload,
    String ownerUserId,
  ) {
    final raw =
        payload['chats'] ??
        payload['Chats'] ??
        payload['conversations'] ??
        payload['Conversations'];
    if (raw is! List) return const [];

    final conversations = <ChatConversation>[];
    for (final entry in raw) {
      final conversation = _conversationFromLoginPayload(entry, ownerUserId);
      if (conversation != null) conversations.add(conversation);
    }
    return conversations;
  }

  ChatConversation? _conversationFromLoginPayload(
    Object? entry,
    String ownerUserId,
  ) {
    if (entry is! Map) return null;
    final map = entry.map((key, value) => MapEntry(key.toString(), value));
    final id = _extractString(map, const [
      'conversationId',
      'conversationID',
      'roomId',
      'RoomId',
      'id',
      'Id',
    ]);
    final otherUserId = _extractString(map, const [
      'otherUserId',
      'OtherUserId',
      'receiverId',
      'ReceiverId',
      'wrytteUserId',
      'WrytteUserId',
      'matrixUserId',
      'MatrixUserId',
    ]);
    final lastMessage = _extractString(map, const [
      'lastMessage',
      'LastMessage',
      'message',
      'Message',
      'body',
      'Body',
    ]);
    if (id.isEmpty || otherUserId.isEmpty) return null;

    final lastSender = _extractString(map, const [
      'lastMessageSenderId',
      'lastMessageSender',
      'senderId',
      'SenderId',
    ]);
    final lastTime = _extractDateTime(map, const [
      'lastMessageTime',
      'LastMessageTime',
      'timestamp',
      'Timestamp',
      'createdAt',
      'CreatedAt',
    ]);
    final otherName = _extractString(map, const [
      'otherUserName',
      'OtherUserName',
      'displayName',
      'name',
      'Name',
    ]);
    final otherAvatar = _extractString(map, const [
      'otherUserAvatar',
      'OtherUserAvatar',
      'avatarUrl',
      'AvatarUrl',
      'avatar',
      'AvatarImg',
    ]);

    return ChatConversation(
      id: id,
      participants: [ownerUserId, otherUserId],
      otherUserId: otherUserId,
      lastMessage: lastMessage,
      lastMessageSenderId: lastSender,
      lastMessageTime: lastTime ?? DateTime.now(),
      unreadCount: int.tryParse(map['unreadCount']?.toString() ?? '') ?? 0,
      lastMessageType:
          _extractString(map, const [
                'lastMessageType',
                'messageType',
              ]).isNotEmpty
              ? _extractString(map, const ['lastMessageType', 'messageType'])
              : 'text',
      otherUserName: otherName.isEmpty ? null : otherName,
      otherUserAvatar:
          otherAvatar.isEmpty ? null : _resolveBackendAssetUrl(otherAvatar),
    );
  }

  List<ChatMessage> _extractChatMessages(
    Map<String, dynamic> payload,
    String ownerUserId,
  ) {
    final buckets = <Object?>[
      payload['messages'],
      payload['Messages'],
      payload['chatMessages'],
      payload['ChatMessages'],
    ];
    final chats =
        payload['chats'] ??
        payload['Chats'] ??
        payload['conversations'] ??
        payload['Conversations'];
    if (chats is List) {
      for (final chat in chats) {
        if (chat is! Map) continue;
        buckets
          ..add(chat['messages'])
          ..add(chat['Messages']);
      }
    }

    final messages = <ChatMessage>[];
    for (final bucket in buckets) {
      if (bucket is! List) continue;
      for (final entry in bucket) {
        final message = _messageFromLoginPayload(entry, ownerUserId);
        if (message != null) messages.add(message);
      }
    }
    return messages;
  }

  ChatMessage? _messageFromLoginPayload(Object? entry, String ownerUserId) {
    if (entry is! Map) return null;
    final map = entry.map((key, value) => MapEntry(key.toString(), value));
    final conversationId = _extractString(map, const [
      'conversationId',
      'conversationID',
      'roomId',
      'RoomId',
      'chatId',
      'ChatId',
    ]);
    final senderId = _extractString(map, const [
      'senderId',
      'SenderId',
      'from',
      'From',
    ]);
    final receiverId = _extractString(map, const [
      'receiverId',
      'ReceiverId',
      'to',
      'To',
    ]);
    final content = _extractString(map, const [
      'content',
      'Content',
      'message',
      'Message',
      'body',
      'Body',
      'text',
      'Text',
    ]);
    if (conversationId.isEmpty || senderId.isEmpty || receiverId.isEmpty) {
      return null;
    }

    final id = _extractString(map, const [
      'id',
      'Id',
      'messageId',
      'MessageId',
      'eventId',
      'EventId',
    ]);
    return ChatMessage(
      id:
          id.isNotEmpty
              ? id
              : 'restore_${conversationId}_${senderId}_${map['timestamp'] ?? DateTime.now().millisecondsSinceEpoch}',
      conversationId: conversationId,
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      timestamp:
          _extractDateTime(map, const [
            'timestamp',
            'Timestamp',
            'createdAt',
            'CreatedAt',
            'sentAt',
            'SentAt',
          ]) ??
          DateTime.now(),
      status: senderId == ownerUserId ? MessageStatus.sent : MessageStatus.read,
      attachmentUrl: _nullableExtractString(map, const [
        'attachmentUrl',
        'AttachmentUrl',
        'mediaUrl',
        'MediaUrl',
      ]),
      attachmentType: _nullableExtractString(map, const [
        'attachmentType',
        'AttachmentType',
        'messageType',
        'MessageType',
      ]),
      senderPhone: _nullableExtractString(map, const [
        'senderPhone',
        'SenderPhone',
        'phone',
        'Phone',
      ]),
      senderName: _nullableExtractString(map, const [
        'senderName',
        'SenderName',
        'displayName',
      ]),
    );
  }

  DateTime? _extractDateTime(Map<String, dynamic> source, List<String> keys) {
    final raw = _extractString(source, keys);
    if (raw.isEmpty) return null;
    final asInt = int.tryParse(raw);
    if (asInt != null && asInt > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
        asInt < 10000000000 ? asInt * 1000 : asInt,
      );
    }
    return DateTime.tryParse(raw);
  }

  String? _nullableExtractString(
    Map<String, dynamic> source,
    List<String> keys,
  ) {
    final value = _extractString(source, keys);
    return value.isEmpty ? null : value;
  }

  Contact? _contactFromLoginPayload(Object? entry) {
    if (entry is! Map) return null;
    final map = entry.map((key, value) => MapEntry(key.toString(), value));
    final displayName = _extractString(map, const [
      'displayName',
      'name',
      'Name',
      'username',
      'Username',
      'profileName',
      'ProfileName',
    ]);
    final phone = _extractString(map, const [
      'phone',
      'Phone',
      'primaryPhone',
      'PrimaryPhone',
      'number',
      'Number',
    ]);
    final phones =
        <String>[
          if (phone.isNotEmpty) _normalizePhone(phone),
          ..._extractPhoneList(map['phones'] ?? map['Phones']),
        ].where((value) => value.isNotEmpty).toSet().toList();
    final wrytteUserId = _extractString(map, const [
      'wrytteUserId',
      'WrytteUserId',
      'userid',
      'userId',
      'UserId',
      'matrixUserId',
      'MatrixUserId',
    ]);
    final avatar = _extractString(map, const [
      'avatarUrl',
      'AvatarUrl',
      'avatar',
      'AvatarImg',
      'image',
      'profileImage',
    ]);

    if (displayName.isEmpty && phones.isEmpty && wrytteUserId.isEmpty) {
      return null;
    }
    return Contact(
      displayName:
          displayName.isNotEmpty
              ? displayName
              : phones.isNotEmpty
              ? phones.first
              : wrytteUserId,
      phones: phones,
      avatarUrl: avatar.isEmpty ? null : _resolveBackendAssetUrl(avatar),
      wrytteUserId: wrytteUserId.isEmpty ? null : wrytteUserId,
      isOnWrytte: true,
      isSaved: true,
    );
  }

  List<String> _extractPhoneList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((value) => _normalizePhone(value?.toString() ?? ''))
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
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
