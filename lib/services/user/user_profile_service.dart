import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/user/user_profile_api_service.dart';

/// Production-grade local-only UserProfileService.
/// Source of truth is FlutterSecureStorage via AuthService.
class UserProfileService {
  UserProfileService._();
  static final UserProfileService instance = UserProfileService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _nameKey = 'username';
  static const _firstNameKey = 'profile_first_name';
  static const _lastNameKey = 'profile_last_name';
  static const _phoneKey = 'phone';
  static const _profileImageKey = 'profile_image';
  static const _bioKey = 'user_bio';

  // In-memory cache — survives the widget lifecycle, cleared on logout
  UserProfile? _cache;

  // ─────────────────────────────────────────────────────────────────────────
  // PUBLIC API
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns the current user's profile, using the in-memory cache when
  /// available. Pass [forceRefresh] = true to always re-read from storage.
  Future<UserProfile?> getCurrentUserProfile({
    bool forceRefresh = false,
  }) async {
    if (_cache != null && !forceRefresh) {
      final uid = await AuthService.instance.getCurrentUserId();
      if (uid != null && uid.isNotEmpty && _cache!.uid == uid) return _cache;
    }
    return _readFromStorage(forceRefresh: forceRefresh);
  }

  /// Persists an updated display name and invalidates the cache.
  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _storage.write(key: _nameKey, value: trimmed);
    final parts = _splitName(trimmed);
    await _storage.write(key: _firstNameKey, value: parts.$1);
    await _storage.write(key: _lastNameKey, value: parts.$2);
    // Also keep AuthService in sync (it owns the same key)
    await AuthService.instance.updateStoredUsername(trimmed);
    await _saveBackendProfileBestEffort({
      'FirstName': parts.$1,
      if (parts.$2.isNotEmpty) 'LastName': parts.$2,
    });
    _cache = null;
    debugPrint('[UserProfileService] Display name updated: "$trimmed"');
  }

  /// Persists a profile image URL and invalidates the cache.
  Future<void> updateProfileImage(String url) async {
    await _storage.write(key: _profileImageKey, value: url.trim());
    _cache = null;
  }

  /// Persists a bio and invalidates the cache.
  Future<void> updateBio(String bio) async {
    await _storage.write(key: _bioKey, value: bio.trim());
    await _saveBackendProfileBestEffort({'Bio': bio.trim()});
    _cache = null;
  }

  /// Convenience: update multiple fields in one write pass.
  Future<void> updateProfile({
    String? name,
    String? firstName,
    String? lastName,
    String? profileImage,
    String? bio,
    List<String>? links,
  }) async {
    final backendFields = <String, String>{};
    if (name != null && name.trim().isNotEmpty) {
      await _storage.write(key: _nameKey, value: name.trim());
      await AuthService.instance.updateStoredUsername(name.trim());
      final parts = _splitName(name.trim());
      await _storage.write(key: _firstNameKey, value: firstName ?? parts.$1);
      await _storage.write(key: _lastNameKey, value: lastName ?? parts.$2);
      backendFields['FirstName'] = firstName?.trim() ?? parts.$1;
      if ((lastName?.trim() ?? parts.$2).isNotEmpty) {
        backendFields['LastName'] = lastName?.trim() ?? parts.$2;
      }
    } else {
      if (firstName != null) {
        await _storage.write(key: _firstNameKey, value: firstName.trim());
        backendFields['FirstName'] = firstName.trim();
      }
      if (lastName != null) {
        await _storage.write(key: _lastNameKey, value: lastName.trim());
        backendFields['LastName'] = lastName.trim();
      }
    }
    if (profileImage != null) {
      await _storage.write(key: _profileImageKey, value: profileImage.trim());
    }
    if (bio != null) {
      await _storage.write(key: _bioKey, value: bio.trim());
      backendFields['Bio'] = bio.trim();
    }
    if (links != null) {
      await _storage.write(key: 'user_links', value: links.join('\n'));
    }
    if (backendFields.isNotEmpty) {
      await _saveBackendProfileBestEffort(backendFields);
    }
    _cache = null;
  }

  /// Stream that emits the current user's profile immediately from cache,
  /// then re-reads from storage. Use this in widgets that need live updates
  /// (e.g. after the user saves a new name or avatar).
  Stream<UserProfile?> getCurrentUserProfileStream() async* {
    // Emit cached value instantly so the UI has zero-latency first frame
    final uid = await AuthService.instance.getCurrentUserId();
    if (_cache != null && uid != null && uid.isNotEmpty && _cache!.uid == uid) {
      yield _cache;
    }

    // Then yield a fresh read from secure storage
    final fresh = await _readFromStorage();
    if (fresh != null) yield fresh;
  }

  /// Warm the cache on app start — call from main.dart after auth restore.
  Future<void> warmUp() async {
    _cache = await _readFromStorage();
  }

  /// Fetches another user's profile by their UID.
  /// For the current user, delegates to [getCurrentUserProfile].
  /// For other users, returns a minimal stub built from what we know locally
  /// (contacts, Matrix display name, etc.) — extend as your contact store grows.
  Future<UserProfile?> getProfileByUid(String uid) async {
    final currentUid = await AuthService.instance.getCurrentUserId();

    // If it's the current user, use the full local profile
    if (currentUid != null && currentUid == uid) {
      return getCurrentUserProfile();
    }

    // For other users we don't have a local store yet — return null so the
    // caller falls back to the widget.title / avatarUrl it already has.
    // Wire this up to your contacts DB when ready.
    return null;
  }

  /// Wipe cache on logout.
  void clearCache() {
    _cache = null;
  }

  // Expose cached value synchronously for widgets that need it immediately
  UserProfile? get cachedProfile => _cache;

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE
  // ─────────────────────────────────────────────────────────────────────────

  Future<UserProfile?> _readFromStorage({bool forceRefresh = false}) async {
    try {
      final uid = await AuthService.instance.getCurrentUserId();
      if (uid == null || uid.isEmpty) return null;

      final phone = _normalizePhone(await _storage.read(key: _phoneKey) ?? '');
      var name = await _storage.read(key: _nameKey) ?? '';
      var firstName = await _storage.read(key: _firstNameKey) ?? '';
      var lastName = await _storage.read(key: _lastNameKey) ?? '';
      var bio = await _storage.read(key: _bioKey) ?? '';

      if (forceRefresh || !_hasRealName(name)) {
        final remote = await _readBackendProfileBestEffort();
        if (remote.isNotEmpty) {
          firstName = _field(remote, 'FirstName') ?? firstName;
          lastName = _field(remote, 'LastName') ?? lastName;
          bio = _field(remote, 'Bio') ?? bio;
          final remoteName =
              [
                firstName,
                lastName,
              ].where((part) => part.trim().isNotEmpty).join(' ').trim();
          if (_hasRealName(remoteName)) {
            name = remoteName;
            await _storage.write(key: _nameKey, value: name);
            await _storage.write(key: _firstNameKey, value: firstName);
            await _storage.write(key: _lastNameKey, value: lastName);
            await AuthService.instance.updateStoredUsername(name);
          }
          await _storage.write(key: _bioKey, value: bio);
        }
      }
      if (!_hasRealName(name)) {
        await AuthService.instance.getValidBackendToken();
        name = await _storage.read(key: _nameKey) ?? name;
      }
      if (!_hasRealName(name)) {
        final restored = await AuthService.instance.hydrateStoredProfile(uid);
        if (restored != null && restored.hasUsableName) {
          name = restored.username;
          await _storage.write(key: _nameKey, value: name);
        }
      }
      final profileImage = await _storage.read(key: _profileImageKey) ?? '';
      final linksRaw = await _storage.read(key: 'user_links') ?? '';

      final profile = UserProfile(
        uid: uid,
        name: name,
        username: name, // username == display name in this app
        phone: phone,
        bio: bio,
        profileImage: profileImage,
        links:
            linksRaw
                .split('\n')
                .map((link) => link.trim())
                .where((link) => link.isNotEmpty)
                .toList(),
      );

      _cache = profile;
      return profile;
    } catch (e) {
      debugPrint('[UserProfileService] _readFromStorage error: $e');
      return null;
    }
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }

  bool _looksLikePhone(String value) {
    final s = value.trim().replaceAll(RegExp(r'[\s\-()+]'), '');
    return RegExp(r'^\d{6,}$').hasMatch(s);
  }

  bool _hasRealName(String value) {
    final trimmed = value.trim();
    if (trimmed.length < 2) return false;
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return false;
    }
    if (_looksLikePhone(trimmed)) return false;
    final localpart =
        trimmed.startsWith('@')
            ? trimmed.substring(1).split(':').first
            : trimmed.split(':').first;
    return !RegExp(
      r'^[a-f0-9]{24,}$',
      caseSensitive: false,
    ).hasMatch(localpart);
  }

  (String, String) _splitName(String value) {
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return ('', '');
    return (parts.first, parts.length > 1 ? parts.sublist(1).join(' ') : '');
  }

  String? _field(Map<String, String> fields, String wanted) {
    for (final entry in fields.entries) {
      if (entry.key.toLowerCase() == wanted.toLowerCase()) {
        return entry.value.trim();
      }
    }
    return null;
  }

  Future<Map<String, String>> _readBackendProfileBestEffort() async {
    try {
      return await UserProfileApiService.instance.getProfile();
    } catch (e) {
      debugPrint('[UserProfileService] Backend profile get skipped: $e');
      return const {};
    }
  }

  Future<void> _saveBackendProfileBestEffort(Map<String, String> fields) async {
    try {
      await UserProfileApiService.instance.saveProfileFields(fields);
    } catch (e) {
      debugPrint('[UserProfileService] Backend profile save skipped: $e');
    }
  }
}
