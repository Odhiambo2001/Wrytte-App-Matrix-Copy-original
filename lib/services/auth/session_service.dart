import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';

class SessionService {
  SessionService._();
  static final SessionService instance = SessionService._();

  static const _storage = FlutterSecureStorage();

  static const _tokenKey = 'auth_token';
  static const _userIdKey = 'user_id';

  Future<void> saveSession({
    required String token,
    String? userId,
    required String secret,
    required String username,
  }) async {
    await _storage.write(key: _tokenKey, value: token);
    if (userId != null) await _storage.write(key: _userIdKey, value: userId);
  }

  Future<void> initMatrixSession() async {
    await MatrixAuthService.instance.restore();
  }

  Future<String?> getToken() async => _storage.read(key: _tokenKey);

  Future<String?> getUserId() async => _storage.read(key: _userIdKey);

  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  Future<void> logout() async {
    await MatrixAuthService.instance.clearStoredSession();
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userIdKey);
  }

  Future<void> clearAll() async {
    await MatrixAuthService.instance.clearStoredSession();
    await _storage.deleteAll();
  }
}
