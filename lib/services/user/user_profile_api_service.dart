import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/file_upload_limits.dart';

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

  Future<Map<String, String>> getPublicProfile({
    String? userId,
    String? matrixUserId,
    String? phone,
  }) async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    final localpart = _matrixLocalpart(userId ?? matrixUserId ?? '');
    final cleanPhone = _normalizePhone(phone ?? '');
    final candidates = <Map<String, String>>[
      if (localpart.isNotEmpty) {'userid': localpart},
      if (localpart.isNotEmpty) {'userId': localpart},
      if ((matrixUserId ?? '').trim().isNotEmpty)
        {'matrixUserId': matrixUserId!.trim()},
      if (cleanPhone.isNotEmpty) {'phone': cleanPhone},
    ];

    for (final query in candidates) {
      try {
        final response = await ApiService.get(
          '/api/UserProfile/get',
          token: token,
          queryParameters: query,
        );
        final fields = _stringMap(response);
        if (_matchesRequestedProfile(
          fields,
          localpart: localpart,
          phone: cleanPhone,
        )) {
          return fields;
        }
        if (fields.isNotEmpty) {
          debugPrint(
            '[UserProfileApiService] ignored unmatched public profile for $query',
          );
        }
      } catch (e) {
        debugPrint(
          '[UserProfileApiService] public profile query skipped $query: $e',
        );
      }
    }
    return const {};
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

  Future<String> uploadAvatarImage(File file) async {
    await FileUploadLimits.validateAvatarImagePath(file.path);

    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    final response = await ApiService.postMultipart(
      '/api/UserProfile/UploadAvatarImage',
      const {},
      files: [await http.MultipartFile.fromPath('file', file.path)],
      token: token,
    );

    final avatar = _avatarFromResponse(response);
    if (avatar.isEmpty) {
      final profile = await getProfile(fields: const ['AvatarImg']);
      return profile['AvatarImg'] ?? profile['avatarImg'] ?? '';
    }
    return avatar;
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

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }

  bool _matchesRequestedProfile(
    Map<String, String> fields, {
    required String localpart,
    required String phone,
  }) {
    if (fields.isEmpty) return false;

    for (final key in const [
      'UserId',
      'userid',
      'userId',
      'Uid',
      'uid',
      'Id',
      'id',
      'MatrixUserId',
      'matrixUserId',
      'maxtrixUserId',
    ]) {
      final raw = _field(fields, key);
      if (raw == null || raw.isEmpty) continue;
      if (_matrixLocalpart(raw) == localpart) return true;
    }

    final returnedPhone = _normalizePhone(
      _field(fields, 'Phone') ?? _field(fields, 'phone') ?? '',
    );
    return phone.isNotEmpty &&
        returnedPhone.isNotEmpty &&
        phone == returnedPhone;
  }

  String? _field(Map<String, String> fields, String wanted) {
    for (final entry in fields.entries) {
      if (entry.key.toLowerCase() == wanted.toLowerCase()) {
        return entry.value.trim();
      }
    }
    return null;
  }

  String _avatarFromResponse(dynamic response) {
    if (response is String) return response.trim();
    if (response is! Map) return '';

    final raw =
        response['AvatarImg'] ??
        response['avatarImg'] ??
        response['avatar'] ??
        response['image'] ??
        response['imagePath'] ??
        response['path'] ??
        response['url'] ??
        response['value'];
    if (raw != null && raw.toString().trim().isNotEmpty) {
      return raw.toString().trim();
    }

    for (final nestedKey in const ['profile', 'fields', 'data']) {
      final nested = response[nestedKey];
      if (nested is Map) {
        final nestedRaw =
            nested['AvatarImg'] ??
            nested['avatarImg'] ??
            nested['imagePath'] ??
            nested['path'] ??
            nested['url'];
        if (nestedRaw != null && nestedRaw.toString().trim().isNotEmpty) {
          return nestedRaw.toString().trim();
        }
      }
    }
    return '';
  }
}
