import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';

import 'matrix_client.dart';
import 'server_discovery_service.dart';

class MatrixAuthService {
  MatrixAuthService._();
  static final MatrixAuthService instance = MatrixAuthService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final ServerDiscoveryService _discovery = ServerDiscoveryService();

  static const matrixUserIdKey = 'matrix_user_id';
  static const matrixAccessTokenKey = 'matrix_access_token';
  static const matrixHomeserverKey = 'matrix_homeserver';
  static const matrixDeviceIdKey = 'matrix_device_id';

  Future<Client> restore() async {
    final client = await MatrixClientService.instance.ensureInitialized();
    if (client.isLogged()) return client;

    final userId = await _storage.read(key: matrixUserIdKey);
    final token = await _storage.read(key: matrixAccessTokenKey);
    final homeserver = await _storage.read(key: matrixHomeserverKey);
    final deviceId = await _storage.read(key: matrixDeviceIdKey);
    if (userId == null || token == null || homeserver == null) return client;

    await MatrixClientService.instance.initWithCredentials(
      homeserver: Uri.parse(homeserver),
      userId: userId,
      accessToken: token,
      deviceId: deviceId,
    );
    return MatrixClientService.instance.client;
  }

  Future<LoginResponse> login({
    required String username,
    required String password,
    String? homeserver,
    String? deviceName,
  }) async {
    final client = await MatrixClientService.instance.ensureInitialized();
    final baseUri = await _discovery.resolveHomeserver(
      userIdOrDomain: homeserver ?? username,
    );
    await client.checkHomeserver(baseUri);
    final response = await client.login(
      LoginType.mLoginPassword,
      identifier: AuthenticationUserIdentifier(user: username),
      user: username,
      password: password,
      initialDeviceDisplayName: deviceName ?? 'Wrytte',
    );
    await _persist(client);
    return response;
  }

  Future<RegisterResponse> register({
    required String username,
    required String password,
    String? homeserver,
    String? deviceName,
  }) async {
    final client = await MatrixClientService.instance.ensureInitialized();
    final baseUri = await _discovery.resolveHomeserver(
      userIdOrDomain: homeserver ?? username,
    );
    await client.checkHomeserver(baseUri);
    final response = await client.register(
      username: username,
      password: password,
      initialDeviceDisplayName: deviceName ?? 'Wrytte',
      inhibitLogin: false,
    );
    await _persist(client);
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
      if (deviceId != null) _storage.write(key: matrixDeviceIdKey, value: deviceId),
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
    ]);
  }
}
