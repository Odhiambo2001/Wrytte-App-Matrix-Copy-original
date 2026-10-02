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

  Uri _profileUri(String userId) {
    final encodedUser = Uri.encodeComponent(userId);
    return Uri.parse(
      '${MatrixConfig.homeserver}/_synapse/client/wrytte/profile/$encodedUser',
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
    final fields = <String, dynamic>{
      ...((decoded['fields'] is Map)
          ? Map<String, dynamic>.from(decoded['fields'] as Map)
          : <String, dynamic>{}),
    };
    for (final key in const ['displayname', 'avatar_url', 'presence']) {
      if (decoded[key] != null) fields[key] = decoded[key];
    }
    return WrytteProfile(userId: userId, fields: fields);
  }

  Future<void> setField(String userId, String field, dynamic value) async {
    final response = await http.patch(
      _profileUri(userId),
      headers: await _authHeaders(),
      body: jsonEncode({'fields': {field: value}}),
    );
    _check(response);
  }

  Future<void> deleteField(String userId, String field) async {
    final uri = _profileUri(userId).replace(queryParameters: {'field': field});
    final response = await http.delete(uri, headers: await _authHeaders());
    _check(response);
  }

  Future<void> setVisibility(String userId, Map<String, String> settings) =>
      setField(userId, WrytteProfile.visibility, settings);

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
    final operations = <Future<void>>[];
    if (avatarUrl != null) operations.add(setAvatar(userId, avatarUrl));
    if (displayName != null) operations.add(setDisplayName(userId, displayName));
    if (firstName != null) operations.add(setFirstName(userId, firstName));
    if (lastName != null) operations.add(setLastName(userId, lastName));
    if (phoneNumber != null) operations.add(setPhoneNumber(userId, phoneNumber));
    if (bio != null) operations.add(setBio(userId, bio));
    if (link != null) operations.add(setLink(userId, link));
    if (channelAlias != null) operations.add(setChannelAlias(userId, channelAlias));
    if (groupAlias != null) operations.add(setGroupAlias(userId, groupAlias));
    if (visibilitySettings != null) operations.add(setVisibility(userId, visibilitySettings));
    await Future.wait(operations);
  }

  Future<void> setAvatar(String userId, String? mxcUrl) async {
    final value = mxcUrl?.trim() ?? '';
    if (value.isEmpty) return deleteField(userId, 'avatar_url');
    return setField(userId, 'avatar_url', value);
  }

  Future<void> setDisplayName(String userId, String? value) =>
      _setOrDelete(userId, 'displayname', value);

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
    return clean.isEmpty ? deleteField(userId, field) : setField(userId, field, clean);
  }

  void _check(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Matrix profile request failed (${response.statusCode}): ${response.body}');
    }
  }
}
