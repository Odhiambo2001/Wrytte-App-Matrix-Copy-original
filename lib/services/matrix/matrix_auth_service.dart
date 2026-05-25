import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

import 'matrix_client.dart';
import 'matrix_contact_service.dart';
import 'server_discovery_service.dart';

class MatrixAuthService {
  MatrixAuthService._();
  static final MatrixAuthService instance = MatrixAuthService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final ServerDiscoveryService _discovery = ServerDiscoveryService();

  static const matrixUserIdKey = 'matrix_user_id';
  static const matrixAccessTokenKey = 'matrix_access_token';
  static const matrixHomeserverKey = 'matrix_homeserver';
  static const matrixDeviceIdKey = 'matrix_device_id';

  Future<Client> restore() async {
    apkLog('Matrix.auth', 'restore start');
    final client = await MatrixClientService.instance.ensureInitialized();
    if (client.isLogged()) {
      apkLog(
        'Matrix.auth',
        'restore already logged user_id="${client.userID}"',
      );
      return client;
    }

    final userId = await _storage.read(key: matrixUserIdKey);
    final token = await _storage.read(key: matrixAccessTokenKey);
    final homeserver = await _storage.read(key: matrixHomeserverKey);
    final deviceId = await _storage.read(key: matrixDeviceIdKey);
    if (userId == null || token == null || homeserver == null) {
      apkLog('Matrix.auth', 'restore no stored Matrix session');
      return client;
    }

    apkLog(
      'Matrix.auth',
      'restore credentials user_id="$userId" homeserver="$homeserver"',
    );
    await MatrixClientService.instance.initWithCredentials(
      homeserver: Uri.parse(homeserver),
      userId: userId,
      accessToken: token,
      deviceId: deviceId,
    );
    apkLog(
      'Matrix.auth',
      'restore ready logged=${MatrixClientService.instance.client.isLogged()} user_id="${MatrixClientService.instance.client.userID}"',
    );
    return MatrixClientService.instance.client;
  }

  Future<LoginResponse> login({
    required String username,
    required String password,
    String? homeserver,
    String? deviceName,
  }) async {
    apkLog(
      'Matrix.auth',
      'resolve homeserver input="${homeserver ?? username}"',
    );
    final client = await MatrixClientService.instance.ensureInitialized();
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
        .timeout(const Duration(seconds: 25));
    apkLog(
      'Matrix.auth',
      'password login response user_id="${client.userID}" device_id="${client.deviceID}"',
    );
    await _persist(client);
    apkLog(
      'Matrix.auth',
      'password login persisted user_id="${client.userID}"',
    );
    return response;
  }

  Future<RegisterResponse> register({
    required String username,
    required String password,
    String? homeserver,
    String? deviceName,
  }) async {
    apkLog(
      'Matrix.auth',
      'resolve homeserver for register input="${homeserver ?? username}"',
    );
    final client = await MatrixClientService.instance.ensureInitialized();
    final baseUri = await _discovery
        .resolveHomeserver(userIdOrDomain: homeserver ?? username)
        .timeout(const Duration(seconds: 5));
    apkLog('Matrix.auth', 'resolved register homeserver="$baseUri"');
    _prepareHomeserver(client, baseUri);
    apkLog('Matrix.auth', 'register call user_id="$username"');
    final response = await client
        .register(
          username: username,
          password: password,
          initialDeviceDisplayName: deviceName ?? 'Wrytte',
          inhibitLogin: false,
        )
        .timeout(const Duration(seconds: 25));
    apkLog(
      'Matrix.auth',
      'register response user_id="${client.userID}" device_id="${client.deviceID}"',
    );
    await _persist(client);
    apkLog('Matrix.auth', 'register persisted user_id="${client.userID}"');
    return response;
  }

  Future<void> logout() async {
    try {
      await MatrixClientService.instance.logout();
    } catch (e) {
      debugPrint('[MatrixAuth] logout error: $e');
    } finally {
      MatrixContactService.instance.clearCache();
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
    } finally {
      MatrixContactService.instance.clearCache();
      await Future.wait([
        _storage.delete(key: matrixUserIdKey),
        _storage.delete(key: matrixAccessTokenKey),
        _storage.delete(key: matrixHomeserverKey),
        _storage.delete(key: matrixDeviceIdKey),
      ]);
    }
  }

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

  void _prepareHomeserver(Client client, Uri homeserver) {
    client.homeserver = _stripTrailingSlash(homeserver);
    apkLog('Matrix.auth', 'homeserver prepared "${client.homeserver}"');
  }

  Uri _stripTrailingSlash(Uri uri) {
    if (!uri.path.endsWith('/') || uri.path == '/') return uri;
    return uri.replace(path: uri.path.substring(0, uri.path.length - 1));
  }
}
