import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:wrytte/models/user_models/wrytte_profile.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

/// Matrix profile API implementation for Wrytte profile fields.
/// Owner writes are authenticated by the Matrix access token. Other-user
/// filtering must be enforced by the Synapse module, not trusted to Flutter.
class MatrixProfileService {
  MatrixProfileService._();
  static final instance = MatrixProfileService._();

  Uri _profileUri(String userId, [String? field]) {
    final encodedUser = Uri.encodeComponent(userId);
    final suffix = field == null ? '' : '/${Uri.encodeComponent(field)}';
    return Uri.parse(
      '${MatrixConfig.homeserver}/_matrix/client/v3/profile/$encodedUser$suffix',
    );
  }

  Future<Map<String, String>> _authHeaders() async {
    final token = MatrixClientService.instance.accessToken ??
        await AuthService.instance.getMatrixAccessToken();
    if (token == null || token.trim().isEmpty) {
      throw StateError('Missing Matrix access token.');
    }
    return {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
  }

  Future<WrytteProfile> getProfile(String userId) async {
    final response = await http.get(_profileUri(userId), headers: await _authHeaders());
    _check(response);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw const FormatException('Invalid Matrix profile.');
    return WrytteProfile(userId: userId, fields: Map<String, dynamic>.from(decoded));
  }

  Future<void> setField(String userId, String field, dynamic value) async {
    final response = await http.put(
      _profileUri(userId, field),
      headers: await _authHeaders(),
      body: jsonEncode({field: value}),
    );
    _check(response);
  }

  Future<void> deleteField(String userId, String field) async {
    final response = await http.delete(_profileUri(userId, field), headers: await _authHeaders());
    _check(response);
  }

  Future<void> setVisibility(String userId, Map<String, String> settings) =>
      setField(userId, WrytteProfile.visibility, settings);

  void _check(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Matrix profile request failed (${response.statusCode}): ${response.body}');
    }
  }
}
