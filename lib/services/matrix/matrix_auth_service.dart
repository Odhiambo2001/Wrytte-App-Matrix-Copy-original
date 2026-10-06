import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

import 'matrix_client.dart';
import 'matrix_config.dart';
import 'server_discovery_service.dart';

class MatrixAuthService {
  MatrixAuthService._();
  static final MatrixAuthService instance = MatrixAuthService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final ServerDiscoveryService _discovery = ServerDiscoveryService();
  Future<Client>? _restoreInFlight;

  static const matrixUserIdKey = 'matrix_user_id';
  static const matrixAccessTokenKey = 'matrix_access_token';
  static const matrixHomeserverKey = 'matrix_homeserver';
  static const matrixDeviceIdKey = 'matrix_device_id';

  Future<Client> restore() {
    final pending = _restoreInFlight;
    if (pending != null) return pending;
    final future = _restore();
    _restoreInFlight = future;
    return future.whenComplete(() {
      if (identical(_restoreInFlight, future)) {
        _restoreInFlight = null;
      }
    });
  }

  Future<Client> _restore() async {
    apkLog('Matrix.auth', 'restore start');
    final storedUserId = await _storage.read(key: matrixUserIdKey);
    final client = await MatrixClientService.instance.ensureInitialized(
      storeNamespace: storedUserId,
    );
    if (client.isLogged()) {
      apkLog(
        'Matrix.auth',
        'restore already logged user_id="${client.userID}"',
      );
      _logTemporaryAccessToken(
        userId: client.userID,
        token: client.accessToken,
        source: 'warm_restore',
      );
      // ADDED: even on a warm restore, make sure the sync loop is running and
      // a first sync has actually landed before callers read client.rooms.
      await _primeSync(client);
      return client;
    }

    final token = await _storage.read(key: matrixAccessTokenKey);
    final homeserver = await _storage.read(key: matrixHomeserverKey);
    final deviceId = await _storage.read(key: matrixDeviceIdKey);
    if (storedUserId == null || token == null || homeserver == null) {
      apkLog('Matrix.auth', 'restore no stored Matrix session');
      return client;
    }

    apkLog(
      'Matrix.auth',
      'restore credentials user_id="$storedUserId" homeserver="$homeserver"',
    );
    if (client.isLogged()) {
      apkLog(
        'Matrix.auth',
        'restore skipped credentials; already logged user_id="${client.userID}"',
      );
      await _primeSync(client); // ADDED
      return client;
    }
    await MatrixClientService.instance.initWithCredentials(
      homeserver: Uri.parse(homeserver),
      userId: storedUserId,
      accessToken: token,
      deviceId: deviceId,
    );
    final restored = MatrixClientService.instance.client;
    apkLog(
      'Matrix.auth',
      'restore ready logged=${restored.isLogged()} user_id="${restored.userID}"',
    );
    _logTemporaryAccessToken(
      userId: restored.userID,
      token: restored.accessToken,
      source: 'credential_restore',
    );
    // ADDED: drive + await the first sync so rooms populate deterministically.
    await _primeSync(restored);
    return restored;
  }

  // ADDED: turns on the background sync loop and waits for exactly one /sync
  // to complete, with a generous window for the slow dev homeserver. With the
  // reduced sync timeline limit this returns in well under a second normally,
  // but we never block the app for more than 30s even if the server stalls.
  Future<void> _primeSync(Client client) async {
    if (!client.isLogged()) return;
    try {
      client.backgroundSync = true;
      // If a first sync already completed in a prior session, this is cheap.
      final firstSync = client.firstSyncReceived;
      if (firstSync != null) {
        await firstSync.timeout(const Duration(seconds: 30), onTimeout: () {});
      } else {
        await client.oneShotSync().timeout(
          const Duration(seconds: 30),
          onTimeout: () => '',
        );
      }
      apkLog(
        'Matrix.auth',
        'first sync primed rooms=${client.rooms.length} user_id="${client.userID}"',
      );
    } catch (e) {
      // Background sync keeps running; callers inspect whatever loaded.
      apkLog('Matrix.auth', 'first sync prime slow/failed error="$e"');
    }
  }

  Future<LoginResponse> login({
    required String username,
    required String password,
    String? homeserver,
    String? deviceName,
    bool forceFreshSession = false,
  }) async {
    apkLog(
      'Matrix.auth',
      'resolve homeserver input="${homeserver ?? username}"',
    );
    var client = await MatrixClientService.instance.ensureInitialized(
      storeNamespace: username,
    );
    if (forceFreshSession && client.isLogged()) {
      apkLog(
        'Matrix.auth',
        'forcing fresh password login; clearing in-memory session user_id="${client.userID}"',
      );
      await MatrixClientService.instance.clearLocalSession();
      client = await MatrixClientService.instance.ensureInitialized(
        storeNamespace: username,
      );
    }
    final baseUri = await _discovery
        .resolveHomeserver(userIdOrDomain: homeserver ?? username)
        .timeout(const Duration(seconds: 5));
    apkLog('Matrix.auth', 'resolved homeserver="$baseUri"');
    _prepareHomeserver(client, baseUri);
    apkLog('Matrix.auth', 'password login call user_id="$username"');
    final response = await client
        .login(
          LoginType.mLoginPassword,
          identifier: AuthenticationUserIdentifier(user: username),
          password: password,
          initialDeviceDisplayName: deviceName ?? 'Wrytte',
        )
        .timeout(MatrixConfig.authRequestTimeout);
    apkLog(
      'Matrix.auth',
      'password login response user_id="${client.userID}" device_id="${client.deviceID}"',
    );
    await _persistLoginResponse(
      homeserver: _stripTrailingSlash(baseUri),
      response: response,
    );
    apkLog(
      'Matrix.auth',
      'password login persisted user_id="${MatrixClientService.instance.client.userID ?? response.userId}"',
    );
    _logTemporaryAccessToken(
      userId: response.userId,
      token: response.accessToken,
      source: 'password_login',
    );
    return response;
  }

  Future<RegisterResponse> register({
    required String username,
    required String password,
    String? homeserver,
    String? deviceName,
    bool forceFreshSession = false,
  }) async {
    apkLog(
      'Matrix.auth',
      'resolve homeserver for register input="${homeserver ?? username}"',
    );
    var client = await MatrixClientService.instance.ensureInitialized(
      storeNamespace: username,
    );
    if (forceFreshSession && client.isLogged()) {
      apkLog(
        'Matrix.auth',
        'forcing fresh register; clearing in-memory session user_id="${client.userID}"',
      );
      await MatrixClientService.instance.clearLocalSession();
      client = await MatrixClientService.instance.ensureInitialized(
        storeNamespace: username,
      );
    }
    final baseUri = await _discovery
        .resolveHomeserver(userIdOrDomain: homeserver ?? username)
        .timeout(const Duration(seconds: 5));
    apkLog('Matrix.auth', 'resolved register homeserver="$baseUri"');
    _prepareHomeserver(client, baseUri);
    apkLog('Matrix.auth', 'register call user_id="$username"');
    // Synapse commonly answers the first registration request with a UIA
    // challenge (401, m.login.dummy). Complete that challenge and resubmit
    // the same registration request. Without this retry the caller falls
    // back to password login, even though the account was never created.
    RegisterResponse response;
    try {
      response = await client
          .register(
            username: username,
            password: password,
            initialDeviceDisplayName: deviceName ?? 'Wrytte',
            inhibitLogin: false,
          )
          .timeout(MatrixConfig.authRequestTimeout);
    } on MatrixException catch (e) {
      final hasDummyStage =
          e.authenticationFlows?.any(
            (flow) => flow.stages.contains(AuthenticationTypes.dummy),
          ) ??
          false;
      if (!e.requireAdditionalAuthentication ||
          e.session == null ||
          !hasDummyStage) {
        rethrow;
      }
      apkLog(
        'Matrix.auth',
        'registration UIA challenge received; completing m.login.dummy',
      );
      response = await client
          .register(
            username: username,
            password: password,
            initialDeviceDisplayName: deviceName ?? 'Wrytte',
            inhibitLogin: false,
            auth: AuthenticationData(
              type: AuthenticationTypes.dummy,
              session: e.session,
            ),
          )
          .timeout(MatrixConfig.authRequestTimeout);
    }
    apkLog(
      'Matrix.auth',
      'register response user_id="${client.userID}" device_id="${client.deviceID}"',
    );
    if (!client.isLogged() && response.accessToken != null) {
      await MatrixClientService.instance.initWithCredentials(
        homeserver: _stripTrailingSlash(baseUri),
        userId: response.userId,
        accessToken: response.accessToken!,
        deviceId: response.deviceId,
      );
    }
    await _persistRegisterResponse(
      homeserver: _stripTrailingSlash(baseUri),
      response: response,
    );
    apkLog('Matrix.auth', 'register persisted user_id="${client.userID}"');
    _logTemporaryAccessToken(
      userId: response.userId,
      token: response.accessToken ?? client.accessToken,
      source: 'register',
    );
    return response;
  }

  Future<void> logout() async {
    try {
      await MatrixClientService.instance.logout();
    } catch (e) {
      debugPrint('[MatrixAuth] logout error: $e');
    } finally {
      await Future.wait([
        _storage.delete(key: matrixUserIdKey),
        _storage.delete(key: matrixAccessTokenKey),
        _storage.delete(key: matrixHomeserverKey),
        _storage.delete(key: matrixDeviceIdKey),
      ]);
    }
  }

  Future<void> clearLocalSession() async {
    try {
      await MatrixClientService.instance.clearLocalSession();
    } catch (e) {
      debugPrint('[MatrixAuth] clear local session error: $e');
    }
  }

  Future<void> clearStoredSession() async {
    await clearLocalSession();
    await Future.wait([
      _storage.delete(key: matrixUserIdKey),
      _storage.delete(key: matrixAccessTokenKey),
      _storage.delete(key: matrixHomeserverKey),
      _storage.delete(key: matrixDeviceIdKey),
    ]);
  }

  Future<bool> validateCurrentSession({String? expectedUserId}) async {
    final client =
        MatrixClientService.instance.isInitialized &&
                MatrixClientService.instance.client.isLogged()
            ? MatrixClientService.instance.client
            : await restore();
    if (!client.isLogged()) return false;
    try {
      final owner = await client.getTokenOwner().timeout(
        const Duration(seconds: 5),
      );
      final currentUserId = owner.userId;
      final expected = expectedUserId?.trim();
      final valid =
          expected == null || expected.isEmpty || currentUserId == expected;
      apkLog(
        'Matrix.auth',
        'token validation valid=$valid user_id="$currentUserId" expected="$expected"',
      );
      return valid;
    } catch (e) {
      apkLog('Matrix.auth', 'token validation failed error="$e"');
      if (isUnknownToken(e)) {
        await clearLocalSession();
      }
      return false;
    }
  }

  static bool isUnknownToken(Object error) =>
      error.toString().toUpperCase().contains('M_UNKNOWN_TOKEN') ||
      error.toString().toUpperCase().contains('UNKNOWN TOKEN');

  Future<void> persistExternalSession({
    required String userId,
    required String accessToken,
    required Uri homeserver,
    String? deviceId,
  }) async {
    await Future.wait([
      _storage.write(key: matrixUserIdKey, value: userId),
      _storage.write(key: matrixAccessTokenKey, value: accessToken),
      _storage.write(key: matrixHomeserverKey, value: homeserver.toString()),
      if (deviceId != null)
        _storage.write(key: matrixDeviceIdKey, value: deviceId),
    ]);
    await MatrixClientService.instance.initWithCredentials(
      homeserver: homeserver,
      userId: userId,
      accessToken: accessToken,
      deviceId: deviceId,
    );
  }

  Future<void> persistCurrentSession() async {
    await _persist(MatrixClientService.instance.client);
  }

  Future<void> _persist(Client client) async {
    final userId = client.userID;
    final token = client.accessToken;
    final homeserver = client.baseUri;
    if (userId == null || token == null || homeserver == null) return;
    await Future.wait([
      _storage.write(key: matrixUserIdKey, value: userId),
      _storage.write(key: matrixAccessTokenKey, value: token),
      _storage.write(key: matrixHomeserverKey, value: homeserver.toString()),
      if (client.deviceID != null)
        _storage.write(key: matrixDeviceIdKey, value: client.deviceID),
    ]);
  }

  Future<void> _persistLoginResponse({
    required Uri homeserver,
    required LoginResponse response,
  }) async {
    await Future.wait([
      _storage.write(key: matrixUserIdKey, value: response.userId),
      _storage.write(key: matrixAccessTokenKey, value: response.accessToken),
      _storage.write(key: matrixHomeserverKey, value: homeserver.toString()),
      _storage.write(key: matrixDeviceIdKey, value: response.deviceId),
    ]);
  }

  Future<void> _persistRegisterResponse({
    required Uri homeserver,
    required RegisterResponse response,
  }) async {
    final token = response.accessToken;
    if (token == null) {
      await _persist(MatrixClientService.instance.client);
      return;
    }
    await Future.wait([
      _storage.write(key: matrixUserIdKey, value: response.userId),
      _storage.write(key: matrixAccessTokenKey, value: token),
      _storage.write(key: matrixHomeserverKey, value: homeserver.toString()),
      if (response.deviceId != null)
        _storage.write(key: matrixDeviceIdKey, value: response.deviceId),
    ]);
  }

  void _prepareHomeserver(Client client, Uri homeserver) {
    client.homeserver = _stripTrailingSlash(homeserver);
    apkLog('Matrix.auth', 'homeserver prepared "${client.homeserver}"');
  }

  /// Temporary debug aid for copying the current session into API clients.
  /// Never emits the access token in profile/release builds.
  void _logTemporaryAccessToken({
    required String? userId,
    required String? token,
    required String source,
  }) {
    if (!kDebugMode) return;
    final value = token?.trim();
    apkLog(
      'Matrix.auth',
      'TEMP_ACCESS_TOKEN source=$source user_id="$userId" token="${value == null || value.isEmpty ? '<unavailable>' : value}"',
    );
  }

  Uri _stripTrailingSlash(Uri uri) {
    if (!uri.path.endsWith('/') || uri.path == '/') return uri;
    return uri.replace(path: uri.path.substring(0, uri.path.length - 1));
  }
}
