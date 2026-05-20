import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';

/// Production-grade local-only UserProfileService.
/// Source of truth is FlutterSecureStorage via AuthService.
class UserProfileService {
  UserProfileService._();
  static final UserProfileService instance = UserProfileService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _nameKey         = 'username';
  static const _phoneKey        = 'phone';
  static const _profileImageKey = 'profile_image';
  static const _bioKey          = 'user_bio';

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
    if (_cache != null && !forceRefresh) return _cache;
    return _readFromStorage();
  }

  /// Persists an updated display name and invalidates the cache.
  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _storage.write(key: _nameKey, value: trimmed);
    // Also keep AuthService in sync (it owns the same key)
    await AuthService.instance.updateStoredUsername(trimmed);
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
    _cache = null;
  }

  /// Convenience: update multiple fields in one write pass.
  Future<void> updateProfile({
    String? name,
    String? profileImage,
    String? bio,
    List<String>? links,
  }) async {
    if (name != null && name.trim().isNotEmpty) {
      await _storage.write(key: _nameKey, value: name.trim());
      await AuthService.instance.updateStoredUsername(name.trim());
    }
    if (profileImage != null) {
      await _storage.write(key: _profileImageKey, value: profileImage.trim());
    }
    if (bio != null) {
      await _storage.write(key: _bioKey, value: bio.trim());
    }
    if (links != null) {
      await _storage.write(key: 'user_links', value: links.join('\n'));
    }
    _cache = null;
  }

  /// Stream that emits the current user's profile immediately from cache,
  /// then re-reads from storage. Use this in widgets that need live updates
  /// (e.g. after the user saves a new name or avatar).
  Stream<UserProfile?> getCurrentUserProfileStream() async* {
    // Emit cached value instantly so the UI has zero-latency first frame
    if (_cache != null) yield _cache;

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

  Future<UserProfile?> _readFromStorage() async {
    try {
      final uid   = await AuthService.instance.getCurrentUserId();
      if (uid == null || uid.isEmpty) return null;

      final phone        = _normalizePhone(
        await _storage.read(key: _phoneKey) ?? '',
      );
      var name           = await _storage.read(key: _nameKey)         ?? '';
      if (_looksLikePhone(name) || name.trim().isEmpty) {
        final archived = await AuthService.instance.findArchivedProfileByPhone(
          phone,
        );
        if (archived != null && archived.hasUsableName) {
          name = archived.username;
          await _storage.write(key: _nameKey, value: name);
        }
      }
      final profileImage = await _storage.read(key: _profileImageKey) ?? '';
      final bio          = await _storage.read(key: _bioKey)          ?? '';
      final linksRaw     = await _storage.read(key: 'user_links')     ?? '';

      final profile = UserProfile(
        uid:          uid,
        name:         name,
        username:     name,   // username == display name in this app
        phone:        phone,
        bio:          bio,
        profileImage: profileImage,
        links:        linksRaw
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
}
