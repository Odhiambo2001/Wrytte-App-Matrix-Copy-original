import 'package:flutter/foundation.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class UserProfileApiService {
  UserProfileApiService._();
  static final UserProfileApiService instance = UserProfileApiService._();

  Future<Map<String, String>> getProfile({List<String>? fields}) async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    final response = await ApiService.get(
      '/api/UserProfile/get',
      token: token,
      queryParameters:
          fields == null || fields.isEmpty
              ? null
              : {'fields': fields.join(',')},
    );

    return _stringMap(response);
  }

  Future<void> saveProfileFields(Map<String, String> fields) async {
    final clean = <String, String>{};
    fields.forEach((key, value) {
      final trimmedKey = key.trim();
      if (trimmedKey.isEmpty) return;
      clean[trimmedKey] = value.trim();
    });
    if (clean.isEmpty) return;

    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    await ApiService.postJson(
      '/api/UserProfile/save',
      token: token,
      body: clean,
    );
  }

  Future<void> removeFields(List<String> fields) async {
    final clean =
        fields
            .map((field) => field.trim())
            .where((field) => field.isNotEmpty)
            .toList();
    if (clean.isEmpty) return;

    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    await ApiService.postMultipart('/api/UserProfile/removefields', {
      'fields': clean.join(','),
    }, token: token);
  }

  Map<String, String> _stringMap(dynamic response) {
    final out = <String, String>{};
    final raw =
        response is Map
            ? response['profile'] ??
                response['fields'] ??
                response['data'] ??
                response
            : null;
    if (raw is! Map) return out;

    for (final entry in raw.entries) {
      final key = entry.key?.toString().trim();
      if (key == null || key.isEmpty) continue;
      final value = entry.value?.toString().trim() ?? '';
      out[key] = value;
    }
    debugPrint('[UserProfileApiService] profile fields: $out');
    return out;
  }
}
