import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as mx;
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

  Uri _matrixProfileFieldUri(String userId, String field) {
    final trimmed = userId.trim();
    final matrixUserId =
        trimmed.startsWith('@') && trimmed.contains(':')
            ? trimmed
            : '@${trimmed.replaceFirst(RegExp(r'^@'), '')}:${MatrixConfig.serverName}';
    return Uri.parse(
      '${MatrixConfig.homeserver}/_matrix/client/v3/profile/'
      '${Uri.encodeComponent(matrixUserId)}/${Uri.encodeComponent(field)}',
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
      final roomCounts = decoded['room_counts'];
      if (roomCounts is Map) {
        for (final entry
            in <String, String>{
              'channel': WrytteProfile.channelMemberCount,
              'group': WrytteProfile.groupMemberCount,
            }.entries) {
          final countRecord = roomCounts[entry.key];
          final roomField =
              entry.key == 'channel'
                  ? WrytteProfile.channelAlias
                  : WrytteProfile.groupAlias;
          final expectedRoomId = fields[roomField]?.toString().trim();
          if (countRecord is Map &&
              countRecord['joined'] is num &&
              expectedRoomId != null &&
              countRecord['room_id']?.toString() == expectedRoomId) {
            fields[entry.value] = countRecord['joined'];
          }
        }
      }
      if (decoded['visibility'] is Map) {
        fields[WrytteProfile.visibility] = Map<String, dynamic>.from(
          decoded['visibility'] as Map,
        );
      }
      if (decoded['presence'] != null) fields['presence'] = decoded['presence'];
      // Name is the Matrix-standard displayname, not the legacy split-name
      // fields returned by the Wrytte Module.
      fields.remove('displayname');
      try {
        final matrixResponse = await http.get(
          _matrixProfileFieldUri(userId, 'displayname'),
        );
        if (matrixResponse.statusCode == 200) {
          final matrixProfile = jsonDecode(matrixResponse.body);
          if (matrixProfile is Map) {
            fields['displayname'] =
                matrixProfile['displayname']?.toString() ?? '';
          }
        } else if (matrixResponse.statusCode == 404) {
          fields['displayname'] = '';
        } else {
          debugPrint(
            '[MatrixProfile.displayname] GET user_id="$userId" '
            'status=${matrixResponse.statusCode}',
          );
        }
      } catch (error) {
        debugPrint(
          '[MatrixProfile.displayname] GET failed user_id="$userId" error=$error',
        );
      }
      debugPrint(
        '[ModuleProfile.GET] parsed user_id="$userId" '
        'field_keys=${fields.keys.toList()} '
        'avatar_version=${fields[WrytteProfile.avatarVersion] ?? "missing"} '
        'has_display_name=${fields['displayname']?.toString().trim().isNotEmpty == true} '
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
  }) => _post(userId, {
    if (fields.isNotEmpty) 'fields': fields,
    if (visibility.isNotEmpty) 'visibility': visibility,
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
    String? phoneNumber,
    String? bio,
    String? link,
    String? channelAlias,
    String? groupAlias,
    Map<String, String>? visibilitySettings,
  }) async {
    if (displayName != null) {
      await setDisplayName(userId, displayName);
    }

    await _saveProfileRoomFields(
      userId,
      fields: {
        if (channelAlias != null) WrytteProfile.channelAlias: channelAlias,
        if (groupAlias != null) WrytteProfile.groupAlias: groupAlias,
      },
    );

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

    // Matrix stores a single displayname; do not write split names to Module.
    add(WrytteProfile.phoneNumber, phoneNumber);
    add(WrytteProfile.bio, bio);
    add(WrytteProfile.link, link);

    if (avatarUrl != null) {
      if (avatarUrl.trim().isEmpty) {
        removeFields.add(WrytteProfile.avatarImageUrl);
      } else {
        fields[WrytteProfile.avatarImageUrl] = avatarUrl.trim();
      }
    }
    if (fields.isEmpty && removeFields.isEmpty && visibilitySettings == null) {
      return;
    }
    await _patch(userId, {
      if (fields.isNotEmpty) 'fields': fields,
      if (removeFields.isNotEmpty) 'remove_fields': removeFields,
      if (visibilitySettings != null) 'visibility': visibilitySettings,
    });
  }

  Future<void> setAvatar(String userId, String? mxcUrl) async {
    return setAvatarImageUrl(userId, mxcUrl);
  }

  Future<void> setAvatarImageUrl(String userId, String? url) async {
    final clean = url?.trim() ?? '';
    if (clean.isEmpty) {
      await deleteAvatar(userId);
      return;
    }
    final current = await getProfile(userId);
    await setAvatarImageAndVersion(
      userId,
      mxcUrl: clean,
      create: current.avatarUrl?.trim().isNotEmpty != true,
    );
  }

  /// Saves the custom Wrytte avatar field. The Module owns the version and
  /// returns the versioned URL in its response; Matrix avatar_url is untouched.
  Future<int> setAvatarImageAndVersion(
    String userId, {
    required String mxcUrl,
    required bool create,
  }) async {
    final avatarUrl = mxcUrl.trim();
    if (avatarUrl.isEmpty) {
      throw ArgumentError.value(avatarUrl, 'mxcUrl', 'Avatar URL is empty.');
    }
    final body = {
      'fields': {WrytteProfile.avatarImageUrl: avatarUrl},
    };
    final response =
        create
            ? await http.post(
              _profileUri(userId),
              headers: await _authHeaders(),
              body: jsonEncode(body),
            )
            : await http.patch(
              _profileUri(userId),
              headers: await _authHeaders(),
              body: jsonEncode(body),
            );
    _check(response);
    final fields = _fieldsFromResponse(response);
    final savedVersion = int.tryParse(
      fields[WrytteProfile.avatarVersion]?.toString().trim() ?? '',
    );
    if (savedVersion == null || savedVersion < 1) {
      throw StateError('Module API did not return the saved avatar version.');
    }
    debugPrint(
      '[ModuleProfile.avatar] saved user_id="$userId" '
      'version=$savedVersion custom_avatar=true method=${create ? "POST" : "PATCH"}',
    );
    return savedVersion;
  }

  Future<void> replaceOwnerProfile(
    String userId, {
    required Map<String, dynamic> fields,
    Map<String, String> visibility = const {},
  }) => _put(userId, {'fields': fields, 'visibility': visibility});

  Future<void> deleteAvatar(String userId) =>
      deleteField(userId, WrytteProfile.avatarImageUrl);

  Future<void> setOnlineVisibility(String userId, String value) =>
      setVisibility(userId, {WrytteProfile.onlineStatus: value});

  /// Matrix owns online presence because it changes with the live session.
  /// The Module GET reads this state and applies Wrytte's visibility rules.
  Future<void> setOnlineStatus(String userId, bool online) async {
    final client = MatrixClientService.instance.client;
    final matrixUserId = client.userID;
    if (matrixUserId == null || matrixUserId.trim().isEmpty) {
      throw StateError(
        'Cannot update presence without a logged-in Matrix user.',
      );
    }
    String localpart(String value) =>
        value
            .trim()
            .replaceFirst(RegExp(r'^@'), '')
            .split(':')
            .first
            .toLowerCase();
    if (localpart(userId) != localpart(matrixUserId)) {
      throw ArgumentError.value(
        userId,
        'userId',
        'A client can only update its own Matrix presence.',
      );
    }
    final status = online ? 'online' : 'offline';
    final stopwatch = Stopwatch()..start();
    debugPrint(
      '[Matrix.presence] set_request user_id="$matrixUserId" status="$status"',
    );
    try {
      await client.setPresence(
        matrixUserId,
        online ? mx.PresenceType.online : mx.PresenceType.offline,
      );
      debugPrint(
        '[Matrix.presence] set_success user_id="$matrixUserId" '
        'status="$status" duration_ms=${stopwatch.elapsedMilliseconds}',
      );
    } catch (error) {
      debugPrint(
        '[Matrix.presence] set_failed user_id="$matrixUserId" '
        'status="$status" duration_ms=${stopwatch.elapsedMilliseconds} '
        'error="$error"',
      );
      rethrow;
    }
  }

  Future<void> setDisplayName(String userId, String? value) async {
    final uri = _matrixProfileFieldUri(userId, 'displayname');
    final clean = value?.trim() ?? '';
    final headers = await _authHeaders();
    final response =
        clean.isEmpty
            ? await http.delete(uri, headers: headers)
            : await http.put(
              uri,
              headers: headers,
              body: jsonEncode({'displayname': clean}),
            );
    _check(response);
    debugPrint(
      '[MatrixProfile.displayname] saved user_id="$userId" '
      'present=${clean.isNotEmpty}',
    );

    // Remove obsolete split-name profile fields after Matrix accepts the
    // standard name. This does not alter the user's saved contact labels.
    for (final legacyField in [
      WrytteProfile.firstName,
      WrytteProfile.lastName,
    ]) {
      try {
        await deleteField(userId, legacyField);
      } catch (error) {
        debugPrint(
          '[ModuleProfile.legacyName] delete skipped user_id="$userId" '
          'field="$legacyField" error=$error',
        );
      }
    }
  }

  Future<void> setPhoneNumber(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.phoneNumber, value);

  Future<void> setBio(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.bio, value);

  Future<void> setLink(String userId, String? value) =>
      _setOrDelete(userId, WrytteProfile.link, value);

  Future<void> setChannelAlias(String userId, String? value) =>
      _saveProfileRoomFields(
        userId,
        fields: {WrytteProfile.channelAlias: value},
      );

  Future<void> setGroupAlias(String userId, String? value) =>
      _saveProfileRoomFields(userId, fields: {WrytteProfile.groupAlias: value});

  /// Uses the Module API lifecycle for the profile's channel/group references:
  /// POST a missing custom field, PATCH an existing value, and DELETE a cleared
  /// field. Both references are checked together so one GET can serve a Save.
  Future<void> _saveProfileRoomFields(
    String userId, {
    required Map<String, String?> fields,
  }) async {
    if (fields.isEmpty) return;
    final current = await getProfile(userId);
    final postFields = <String, dynamic>{};
    final patchFields = <String, dynamic>{};
    final deleteFields = <String>[];

    for (final entry in fields.entries) {
      final desired = entry.value?.trim() ?? '';
      final existing = current.fields[entry.key]?.toString().trim() ?? '';
      if (desired == existing) continue;
      if (desired.isEmpty) {
        if (existing.isNotEmpty) deleteFields.add(entry.key);
      } else if (existing.isEmpty) {
        postFields[entry.key] = desired;
      } else {
        patchFields[entry.key] = desired;
      }
    }

    if (postFields.isNotEmpty) {
      debugPrint(
        '[ModuleProfile.fields] method=POST user_id="$userId" '
        'fields=${postFields.keys.toList()}',
      );
      await addFields(userId, fields: postFields);
    }
    if (patchFields.isNotEmpty) {
      debugPrint(
        '[ModuleProfile.fields] method=PATCH user_id="$userId" '
        'fields=${patchFields.keys.toList()}',
      );
      await _patch(userId, {'fields': patchFields});
    }
    for (final field in deleteFields) {
      debugPrint(
        '[ModuleProfile.fields] method=DELETE user_id="$userId" field="$field"',
      );
      await deleteField(userId, field);
    }
  }

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

  Future<void> _put(String userId, Map<String, dynamic> body) async {
    final response = await http.put(
      _profileUri(userId),
      headers: await _authHeaders(),
      body: jsonEncode(body),
    );
    _check(response);
  }

  Map<String, dynamic> _fieldsFromResponse(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['fields'] is! Map) {
      throw const FormatException('Module response omitted profile fields.');
    }
    return Map<String, dynamic>.from(decoded['fields'] as Map);
  }

  void _check(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Matrix profile request failed (${response.statusCode}): ${response.body}',
      );
    }
  }
}
