import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:wrytte/models/user_models/wrytte_profile.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:flutter/foundation.dart';

/// Matrix profile API implementation for Wrytte profile fields.
/// Owner writes are authenticated by the Matrix access token. Other-user
/// filtering must be enforced by the Synapse module, not trusted to Flutter.
class MatrixProfileService {
  MatrixProfileService._();
  static final instance = MatrixProfileService._();

  Uri _profileUri(String userId) {
    final trimmed = userId.trim();
    final matrixUserId =
        trimmed.startsWith('@') && trimmed.contains(':')
            ? trimmed
            : '@${trimmed.replaceFirst(RegExp(r'^@'), '')}:${MatrixConfig.serverName}';
    final encodedUser = Uri.encodeComponent(matrixUserId);
    return Uri.parse(
      '${MatrixConfig.homeserver}/_synapse/client/wrytte/profile/$encodedUser',
    );
  }

  Future<Map<String, String>> _authHeaders() async {
    final token =
        MatrixClientService.instance.accessToken ??
        await AuthService.instance.getMatrixAccessToken();
    if (token == null || token.trim().isEmpty) {
      throw StateError('Missing Matrix access token.');
    }
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  Future<WrytteProfile> getProfile(String userId) async {
    final uri = _profileUri(userId);
    debugPrint('[ModuleProfile.GET] start user_id="$userId" url="$uri"');
    try {
      final response = await http.get(uri, headers: await _authHeaders());
      debugPrint(
        '[ModuleProfile.GET] response user_id="$userId" status=${response.statusCode}',
      );
      _check(response);
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('Invalid Matrix profile.');
      }
      final fields = <String, dynamic>{
        ...((decoded['fields'] is Map)
            ? Map<String, dynamic>.from(decoded['fields'] as Map)
            : <String, dynamic>{}),
      };
      if (decoded['visibility'] is Map) {
        fields[WrytteProfile.visibility] = Map<String, dynamic>.from(
          decoded['visibility'] as Map,
        );
      }
      for (final key in const ['displayname', 'avatar_url', 'presence']) {
        if (decoded[key] != null) fields[key] = decoded[key];
      }
      debugPrint(
        '[ModuleProfile.GET] parsed user_id="$userId" '
        'field_keys=${fields.keys.toList()} '
        'avatar_version=${fields[WrytteProfile.avatarVersion] ?? "missing"} '
        'has_display_name=${fields['displayname']?.toString().trim().isNotEmpty == true} '
        'has_matrix_avatar=${fields['avatar_url']?.toString().trim().isNotEmpty == true} '
        'has_custom_avatar=${fields[WrytteProfile.avatarImageUrl]?.toString().trim().isNotEmpty == true} '
        'has_bio=${fields[WrytteProfile.bio]?.toString().trim().isNotEmpty == true}',
      );
      return WrytteProfile(userId: userId, fields: fields);
    } catch (error, stackTrace) {
      debugPrint(
        '[ModuleProfile.GET] failed user_id="$userId" url="$uri" error=$error',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> setField(String userId, String field, dynamic value) async {
    final response = await http.patch(
      _profileUri(userId),
      headers: await _authHeaders(),
      body: jsonEncode({
        'fields': {field: value},
      }),
    );
    _check(response);
  }

  Future<void> addFields(
    String userId, {
    Map<String, dynamic> fields = const {},
    Map<String, String> visibility = const {},
    String? displayName,
  }) => _post(userId, {
    if (fields.isNotEmpty) 'fields': fields,
    if (visibility.isNotEmpty) 'visibility': visibility,
    if (displayName != null) 'displayname': displayName,
  });

  Future<void> deleteField(String userId, String field) async {
    final uri = _profileUri(userId).replace(queryParameters: {'field': field});
    final response = await http.delete(uri, headers: await _authHeaders());
    _check(response);
  }

  Future<void> setVisibility(String userId, Map<String, String> settings) =>
      _patch(userId, {'visibility': settings});

  Future<void> clearVisibility(String userId, String field) async {
    final uri = _profileUri(
      userId,
    ).replace(queryParameters: {'field': 'visibility:$field'});
    final response = await http.delete(uri, headers: await _authHeaders());
    _check(response);
  }

  Future<String?> getPresence(String userId) async {
    final profile = await getProfile(userId);
    return profile.presence;
  }

  Future<void> updateOwnerProfile({
    required String userId,
    String? avatarUrl,
    String? displayName,
    String? firstName,
    String? lastName,
    String? phoneNumber,
    String? bio,
    String? link,
    String? channelAlias,
    String? groupAlias,
    Map<String, String>? visibilitySettings,
  }) async {
    final fields = <String, dynamic>{};
    final removeFields = <String>[];
    void add(String field, String? value) {
      if (value == null) return;
      final clean = value.trim();
      if (clean.isEmpty) {
        removeFields.add(field);
      } else {
        fields[field] = clean;
      }
    }

    add(WrytteProfile.firstName, firstName);
    add(WrytteProfile.lastName, lastName);
    add(WrytteProfile.phoneNumber, phoneNumber);
    add(WrytteProfile.bio, bio);
    add(WrytteProfile.link, link);
    add(WrytteProfile.channelAlias, channelAlias);
    add(WrytteProfile.groupAlias, groupAlias);

    await _patch(userId, {
      if (fields.isNotEmpty) 'fields': fields,
      if (removeFields.isNotEmpty) 'remove_fields': removeFields,
      if (displayName != null) 'displayname': displayName.trim(),
      if (avatarUrl != null) 'avatar_url': avatarUrl.trim(),
      if (visibilitySettings != null) 'visibility': visibilitySettings,
    });
  }

  Future<void> setAvatar(String userId, String? mxcUrl) async {
    return setAvatarImageUrl(userId, mxcUrl);
  }

  Future<void> setAvatarImageUrl(String userId, String? url) =>
      _patch(userId, {'avatar_url': url?.trim() ?? ''});

  /// Saves Matrix's standard avatar_url and Wrytte's cache version. Synapse
  /// automatically propagates standard avatar changes into joined rooms.
  Future<void> setAvatarImageAndVersion(
    String userId, {
    required String mxcUrl,
    required int version,
  }) async {
    final normalizedUserId =
        userId.startsWith('@')
            ? userId
            : '@${userId.replaceFirst(RegExp(r'^@'), '')}:${MatrixConfig.serverName}';
    if (!mxcUrl.startsWith('mxc://')) {
      throw ArgumentError.value(
        mxcUrl,
        'mxcUrl',
        'Expected a Matrix mxc:// URI.',
      );
    }

    final response = await http.patch(
      _profileUri(userId),
      headers: await _authHeaders(),
      body: jsonEncode({
        'avatar_url': mxcUrl,
        'fields': {WrytteProfile.avatarVersion: version.toString()},
      }),
    );
    _check(response);
    final decoded = jsonDecode(response.body);
    final fields =
        decoded is Map && decoded['fields'] is Map
            ? Map<String, dynamic>.from(decoded['fields'] as Map)
            : <String, dynamic>{};
    final savedVersion = int.tryParse(
      fields[WrytteProfile.avatarVersion]?.toString().trim() ?? '',
    );
    if (savedVersion == null) {
      throw StateError('Module API did not return the saved avatar version.');
    }
    // Synapse returns only the standard profile fields from this GET. The
    // Module response includes that same avatar_url when the write succeeds.
    final actualAvatar =
        decoded is Map ? decoded['avatar_url']?.toString() : null;
    // Some Module deployments return only custom fields; verify via the
    // standard Matrix endpoint in that case.
    final confirmedAvatar =
        actualAvatar ??
        (await MatrixClientService.instance.client.getProfileField(
          normalizedUserId,
          'avatar_url',
        ))['avatar_url']?.toString();
    if (confirmedAvatar != mxcUrl) {
      throw StateError('Matrix did not save the requested avatar_url.');
    }
    debugPrint(
      '[ModuleProfile.avatar] saved user_id="$userId" '
      'version=$savedVersion matrix_avatar=true',
    );
  }

  Future<void> setAvatarVersion(String userId, int version) =>
      setField(userId, WrytteProfile.avatarVersion, version.toString());

  Future<void> setOnlineVisibility(String userId, String value) =>
      setVisibility(userId, {WrytteProfile.onlineStatus: value});

  Future<void> setOnlineStatus(String userId, bool online) =>
      _patch(userId, {'presence': online ? 'online' : 'offline'});

  Future<void> setDisplayName(String userId, String? value) async {
    final response = await http.patch(
      _profileUri(userId),
      headers: await _authHeaders(),
      body: jsonEncode({'displayname': value?.trim() ?? ''}),
    );
    _check(response);
  }

  Future<void> setFirstName(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.firstName, value);

  Future<void> setLastName(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.lastName, value);

  Future<void> setPhoneNumber(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.phoneNumber, value);

  Future<void> setBio(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.bio, value);

  Future<void> setLink(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.link, value);

  Future<void> setChannelAlias(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.channelAlias, value);

  Future<void> setGroupAlias(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.groupAlias, value);

  Future<void> _setOrDelete(String userId, String field, String? value) {
    final clean = value?.trim() ?? '';
    return clean.isEmpty
        ? deleteField(userId, field)
        : setField(userId, field, clean);
  }

  Future<void> _patch(String userId, Map<String, dynamic> body) async {
    final response = await http.patch(
      _profileUri(userId),
      headers: await _authHeaders(),
      body: jsonEncode(body),
    );
    _check(response);
  }

  Future<void> _post(String userId, Map<String, dynamic> body) async {
    final response = await http.post(
      _profileUri(userId),
      headers: await _authHeaders(),
      body: jsonEncode(body),
    );
    _check(response);
  }

  void _check(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Matrix profile request failed (${response.statusCode}): ${response.body}',
      );
    }
  }
}
