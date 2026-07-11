import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

class ContactIdentity {
  final String matrixUserId;
  final String? phone;
  final String? profileName;
  final String? savedName;
  final String? avatarUrl;
  final String? bio;

  const ContactIdentity({
    required this.matrixUserId,
    this.phone,
    this.profileName,
    this.savedName,
    this.avatarUrl,
    this.bio,
  });

  ContactIdentity copyWith({
    String? matrixUserId,
    String? phone,
    String? profileName,
    String? savedName,
    String? avatarUrl,
    String? bio,
  }) {
    return ContactIdentity(
      matrixUserId: matrixUserId ?? this.matrixUserId,
      phone: phone ?? this.phone,
      profileName: profileName ?? this.profileName,
      savedName: savedName ?? this.savedName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
    );
  }

  Map<String, dynamic> toJson() => {
    'matrixUserId': matrixUserId,
    'phone': phone,
    'profileName': profileName,
    'savedName': savedName,
    'avatarUrl': avatarUrl,
    'bio': bio,
  };

  factory ContactIdentity.fromJson(Map<String, dynamic> json) {
    return ContactIdentity(
      matrixUserId: json['matrixUserId']?.toString() ?? '',
      phone: json['phone']?.toString(),
      profileName: json['profileName']?.toString(),
      savedName: json['savedName']?.toString(),
      avatarUrl: json['avatarUrl']?.toString(),
      bio: json['bio']?.toString(),
    );
  }
}

class ContactIdentityCache {
  ContactIdentityCache._();
  static final ContactIdentityCache instance = ContactIdentityCache._();

  static const _keyPrefix = 'contact_identity_cache';

  Future<void> upsert({
    required String ownerUserId,
    required String matrixUserId,
    String? phone,
    String? profileName,
    String? savedName,
    String? avatarUrl,
    String? bio,
  }) async {
    final owner = ownerUserId.trim();
    final mxid = _toMatrixUserId(matrixUserId);
    if (owner.isEmpty || mxid.isEmpty) return;

    final identities = await loadAll(ownerUserId: owner);
    final existing = identities[_identityKey(mxid)];
    identities[_identityKey(
      mxid,
    )] = (existing ?? ContactIdentity(matrixUserId: mxid)).copyWith(
      phone: _normalizedPhone(phone) ?? existing?.phone,
      profileName: _clean(profileName) ?? existing?.profileName,
      savedName: _clean(savedName) ?? existing?.savedName,
      avatarUrl: _clean(avatarUrl) ?? existing?.avatarUrl,
      bio: _cleanBio(bio) ?? existing?.bio,
    );
    await _saveAll(ownerUserId: owner, identities: identities);
  }

  Future<ContactIdentity?> findByMatrixId({
    required String ownerUserId,
    required String matrixUserId,
  }) async {
    final identities = await loadAll(ownerUserId: ownerUserId);
    return identities[_identityKey(_toMatrixUserId(matrixUserId))];
  }

  Future<void> clearSavedName({
    required String ownerUserId,
    required String matrixUserId,
  }) async {
    final owner = ownerUserId.trim();
    final mxid = _toMatrixUserId(matrixUserId);
    if (owner.isEmpty || mxid.isEmpty) return;

    final identities = await loadAll(ownerUserId: owner);
    final key = _identityKey(mxid);
    final existing = identities[key];
    if (existing == null || existing.savedName == null) return;
    identities[key] = ContactIdentity(
      matrixUserId: existing.matrixUserId,
      phone: existing.phone,
      profileName: existing.profileName,
      avatarUrl: existing.avatarUrl,
      bio: existing.bio,
    );
    await _saveAll(ownerUserId: owner, identities: identities);
  }

  Future<Map<String, ContactIdentity>> loadAll({
    required String ownerUserId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_keyForOwner(ownerUserId)) ?? const [];
    final output = <String, ContactIdentity>{};
    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is! Map<String, dynamic>) continue;
        final identity = ContactIdentity.fromJson(decoded);
        if (identity.matrixUserId.isEmpty) continue;
        output[_identityKey(identity.matrixUserId)] = identity;
      } catch (_) {
        // Ignore stale/corrupt entries.
      }
    }
    return output;
  }

  Future<void> _saveAll({
    required String ownerUserId,
    required Map<String, ContactIdentity> identities,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyForOwner(ownerUserId),
      identities.values
          .map((identity) => jsonEncode(identity.toJson()))
          .toList(),
    );
  }

  String _keyForOwner(String ownerUserId) {
    final owner = ownerUserId.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9._=-]'),
      '_',
    );
    return '${_keyPrefix}_${owner.isEmpty ? 'signed_out' : owner}';
  }

  String _identityKey(String matrixUserId) {
    // Matrix IDs are globally scoped by their homeserver. Collapsing this to
    // the localpart allows @alice:one.test to reuse @alice:two.test's profile.
    // Keep the complete MXID in the owner-scoped cache namespace.
    return _toMatrixUserId(matrixUserId).toLowerCase();
  }

  String _toMatrixUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    return '@${_matrixLocalpart(trimmed)}:${MatrixConfig.serverName}';
  }

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  String? _normalizedPhone(String? phone) {
    var cleaned = phone?.trim().replaceAll(RegExp(r'[^\d+]'), '') ?? '';
    if (cleaned.isEmpty) return null;
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    final digitsOnly = cleaned.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.length < 7 || digitsOnly.length > 15) return null;
    if (!cleaned.startsWith('+')) cleaned = '+$cleaned';
    cleaned = _stripInvalidNorthAmericaPrefix(cleaned);
    return cleaned;
  }

  String _stripInvalidNorthAmericaPrefix(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (!phone.startsWith('+1')) return phone;
    if (digits.length <= 11) return phone;
    return '+${digits.substring(1)}';
  }

  String? _clean(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return null;
    }
    if (RegExp(
      r'^\+?\d{6,}$',
    ).hasMatch(trimmed.replaceAll(RegExp(r'[\s\-()+]'), ''))) {
      return null;
    }
    final localpart =
        trimmed.startsWith('@')
            ? trimmed.substring(1).split(':').first
            : trimmed.split(':').first;
    if (RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart)) {
      return null;
    }
    return trimmed;
  }

  String? _cleanBio(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
