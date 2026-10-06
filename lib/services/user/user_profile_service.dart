import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart' show MatrixFile;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/models/user_models/wrytte_profile.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_profile_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/file_upload_limits.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/utils/wrytte_id.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

/// Production-grade local-only UserProfileService.
/// Source of truth is FlutterSecureStorage via AuthService.
class UserProfileService {
  UserProfileService._() {
    MatrixClientService.instance.profileUpdateStream.listen(
      _handlePublicProfileUpdated,
    );
    for (final userId
        in MatrixClientService.instance.takePendingProfileUpdates()) {
      _handlePublicProfileUpdated(userId);
    }
  }
  static final UserProfileService instance = UserProfileService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static const _nameKey = 'username';
  static const _firstNameKey = 'profile_first_name';
  static const _lastNameKey = 'profile_last_name';
  static const _phoneKey = 'phone';
  static const _profileImageKey = 'profile_image';
  static const _bioKey = 'user_bio';
  static const _localProfileImagePrefix = 'profile_image_local_path_';
  static const _pendingProfileImagePrefix = 'profile_image_pending_upload_';
  static const _avatarVersionPrefix = 'profile_avatar_version_';

  // In-memory cache — survives the widget lifecycle, cleared on logout
  UserProfile? _cache;
  DateTime? _lastPendingAvatarAttemptAt;
  final Map<String, UserProfile> _publicProfileCache = {};
  final Map<String, Future<UserProfile?>> _publicProfileInFlight = {};
  final Map<String, String> _publicProfilePreviousAvatarUrls = {};
  final Map<String, int> _publicProfileRevisions = {};
  final Set<String> _publicProfileMisses = {};
  Future<UserProfile?>? _loginProfileInFlight;
  DateTime? _currentProfileBackendFetchedAt;
  int _sessionGeneration = 0;
  int _profileReadRevision = 0;
  int _avatarMutationRevision = 0;
  String? _activeAccountUid;
  bool _logoutInProgress = false;
  static const _currentProfileFreshness = Duration(minutes: 5);
  bool _suppressBackendProfileReads = false;
  final StreamController<UserProfile?> _profileController =
      StreamController<UserProfile?>.broadcast();
  final StreamController<String> _publicProfileUpdateController =
      StreamController<String>.broadcast();

  Stream<String> get publicProfileUpdateStream =>
      _publicProfileUpdateController.stream;

  void _handlePublicProfileUpdated(String userId) {
    final localpart = _matrixLocalpart(userId).toLowerCase();
    if (localpart.isEmpty) return;
    final cachedProfile = cachedPublicProfileByUid(userId);
    if (cachedProfile?.profileImage.isNotEmpty == true) {
      _publicProfilePreviousAvatarUrls[localpart] =
          cachedProfile!.profileImage;
    }
    _publicProfileRevisions.update(
      localpart,
      (revision) => revision + 1,
      ifAbsent: () => 1,
    );
    _publicProfileCache.removeWhere(
      (key, _) => _profileCacheLocalpart(key) == localpart,
    );
    _publicProfileMisses.removeWhere(
      (key) => _profileCacheLocalpart(key) == localpart,
    );
    _publicProfileUpdateController.add(userId);
    unawaited(_refreshOwnerProfileIfChanged(userId));
    debugPrint(
      '[UserProfileService] invalidated public profile user_id="$userId"',
    );
  }

  Future<void> _refreshOwnerProfileIfChanged(String userId) async {
    final currentUserId = await AuthService.instance.getCurrentUserId();
    if (currentUserId == null ||
        _matrixLocalpart(currentUserId).toLowerCase() !=
            _matrixLocalpart(userId).toLowerCase()) {
      return;
    }
    _cache = null;
    _currentProfileBackendFetchedAt = null;
    await _refreshAndNotify(forceRefresh: true);
  }

  String _profileCacheLocalpart(String cacheKey) =>
      cacheKey.split('|').first.toLowerCase();

  // ─────────────────────────────────────────────────────────────────────────
  // PUBLIC API
  // ─────────────────────────────────────────────────────────────────────────

  void setFirstSignupMode(bool enabled) {
    _suppressBackendProfileReads = enabled;
    _logoutInProgress = false;
    if (enabled) {
      // A signup starts a different account. Do not let a prior account's
      // in-flight profile read or in-memory identity reach the new account.
      clearCache();
    }
  }

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

  /// First-signup bootstrap. No backend profile/avatar read is performed
  /// because the account has not created an avatar yet.
  Future<UserProfile?> getCurrentUserProfileLocalOnly() {
    return _readFromStorage(allowBackendRefresh: false);
  }

  /// Returning-login bootstrap. The avatar is intentionally not read from
  /// local storage: logout removes it and the authenticated backend profile is
  /// the only source allowed to repopulate it for this session.
  Future<UserProfile?> getCurrentUserProfileForLogin() {
    _suppressBackendProfileReads = false;
    _logoutInProgress = false;
    final pending = _loginProfileInFlight;
    if (pending != null) return pending;
    _cache = null;
    final future = _readFromStorage(
      forceRefresh: true,
      allowBackendRefresh: true,
      ignoreStoredAvatar: true,
      ignoreStoredProfile: true,
    );
    _loginProfileInFlight = future;
    return future
        .then((profile) {
          if (profile != null) {
            _currentProfileBackendFetchedAt = DateTime.now();
            apkLog(
              'Profile.bootstrap',
              'backend profile ready user_id="${profile.uid}" '
                  'avatar=${profile.hasProfileImage} '
                  'avatar_version=${profile.avatarVersion}',
            );
          }
          return profile;
        })
        .whenComplete(() {
          if (identical(_loginProfileInFlight, future)) {
            _loginProfileInFlight = null;
          }
        });
  }

  /// Persists an updated display name and invalidates the cache.
  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    final uid = await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.trim().isEmpty) {
      throw StateError('Cannot update Matrix displayname without a user ID.');
    }
    await MatrixProfileService.instance.setDisplayName(uid, trimmed);
    if (trimmed.isEmpty) {
      await _storage.delete(key: _nameKey);
    } else {
      await _storage.write(key: _nameKey, value: trimmed);
      await AuthService.instance.updateStoredUsername(trimmed);
    }
    await _storage.delete(key: _firstNameKey);
    await _storage.delete(key: _lastNameKey);
    _cache = null;
    await _refreshAndNotify(forceRefresh: true);
    debugPrint(
      '[UserProfileService] Matrix displayname updated user_id="$uid" '
      'present=${trimmed.isNotEmpty}',
    );
  }

  /// Persists a profile image URL and invalidates the cache.
  Future<void> updateProfileImage(String url) async {
    final previousAvatarUrl = await _storage.read(key: _profileImageKey);
    _avatarMutationRevision++;
    await _storage.write(
      key: _profileImageKey,
      value: _resolveAvatarUrl(url.trim()),
    );
    await _saveBackendProfileBestEffort({'AvatarImg': url.trim()});
    _cache = null;
    await _refreshAndNotify(forceRefresh: true);
    if (previousAvatarUrl?.trim() != _resolveAvatarUrl(url.trim())) {
      await UserAvatar.evictCachedUrl(previousAvatarUrl);
    }
  }

  Future<void> deleteProfileImage() async {
    final uid = await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.trim().isEmpty) {
      throw StateError('Not authenticated.');
    }
    final previousAvatarUrl = await _storage.read(key: _profileImageKey);
    _avatarMutationRevision++;
    await MatrixProfileService.instance.deleteAvatar(uid);
    await _storage.delete(key: _profileImageKey);
    await _writeAvatarVersion(uid, 0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingProfileImageKey(uid));
    _cache = null;
    await _clearLocalAvatarCache(uid);
    await _refreshAndNotify(forceRefresh: true);
    await UserAvatar.evictCachedUrl(previousAvatarUrl);
  }

  /// Saves a newly selected avatar locally so profile surfaces can display it
  /// immediately, then retries its upload in the background.
  Future<void> saveProfileImageLocally(File file) async {
    final uid = await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.isEmpty) {
      throw Exception('Not authenticated.');
    }

    _avatarMutationRevision++;
    final localPath = await _cacheProfileImageFile(uid, file);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localProfileImageKey(uid), localPath);
    await prefs.setString(_pendingProfileImageKey(uid), localPath);
    _cache = null;

    await _readFromStorage(allowBackendRefresh: false);

    unawaited(_syncPendingAvatarAndRefresh());
  }

  Future<String> uploadProfileImage(File file) async {
    final uid = await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.isEmpty) {
      throw Exception('Not authenticated.');
    }

    final previousAvatarUrl = await _storage.read(key: _profileImageKey);
    final previousLocalPath = await _readLocalProfileImagePath(uid);
    _avatarMutationRevision++;
    final localPath = await _cacheProfileImageFile(uid, file);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localProfileImageKey(uid), localPath);
    await prefs.setString(_pendingProfileImageKey(uid), localPath);
    _cache = null;
    await _refreshAndNotify();

    try {
      final uploadedPath = await _uploadAvatarToMatrix(File(localPath));
      final requestedAvatarUrl = uploadedPath;
      if (requestedAvatarUrl.isEmpty) {
        throw Exception('Avatar upload returned an empty URL.');
      }
      final currentAvatar = await MatrixProfileService.instance.getProfile(uid);
      final avatarVersion = await MatrixProfileService.instance
          .setAvatarImageAndVersion(
            uid,
            mxcUrl: requestedAvatarUrl,
            create: currentAvatar.avatarUrl?.trim().isNotEmpty != true,
          );
      final savedAvatar = await MatrixProfileService.instance.getProfile(uid);
      final avatarUrl = _withAvatarFetchVersion(
        savedAvatar[WrytteProfile.avatarImageUrl]?.trim().isNotEmpty == true
            ? savedAvatar[WrytteProfile.avatarImageUrl]!
            : requestedAvatarUrl,
        uid,
        avatarVersion,
      );
      // Invalidate reads that started while the upload was in progress before
      // committing the new canonical URL.
      _avatarMutationRevision++;
      await _storage.write(key: _profileImageKey, value: avatarUrl);
      await _writeAvatarVersion(uid, avatarVersion);
      await prefs.remove(_pendingProfileImageKey(uid));
      await _deleteCachedAvatarFile(previousLocalPath, keepPath: localPath);
      _cache = null;
      await _refreshAndNotify(forceRefresh: true);
      await UserAvatar.evictCachedUrl(previousAvatarUrl);
      return avatarUrl;
    } catch (e) {
      _lastPendingAvatarAttemptAt = DateTime.now();
      debugPrint('[UserProfileService] Avatar upload pending: $e');
      rethrow;
    }
  }

  Future<void> syncPendingAvatarUpload() async {
    final uid = await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.isEmpty) return;
    final uploaded = await _syncPendingAvatarUploadForUid(uid);
    if (uploaded) {
      _cache = null;
      await _refreshAndNotify(forceRefresh: true);
    }
  }

  /// Persists a bio and invalidates the cache.
  Future<void> updateBio(String bio) async {
    await _storage.write(key: _bioKey, value: bio.trim());
    await _saveBackendProfileBestEffort({'Bio': bio.trim()});
    _cache = null;
    await _refreshAndNotify(forceRefresh: true);
  }

  /// Saves the Wrytte custom phone field, then invalidates local profile data.
  /// Account-number changes must still go through the verified account flow.
  Future<void> updatePhoneNumber(String phoneNumber) async {
    final clean = phoneNumber.trim();
    final uid = await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.trim().isEmpty) {
      throw StateError('Cannot update profile number without a user ID.');
    }
    await MatrixProfileService.instance.setPhoneNumber(uid, clean);
    _cache = null;
    await _refreshAndNotify(forceRefresh: true);
  }

  /// Convenience: update multiple fields in one write pass.
  Future<void> updateProfile({
    String? name,
    String? firstName,
    String? lastName,
    String? phoneNumber,
    String? profileImage,
    String? bio,
    List<String>? links,
    String? channelAlias,
    String? groupAlias,
    Map<String, String>? visibilitySettings,
  }) async {
    final backendFields = <String, String>{};
    String? previousAvatarForEviction;
    final String? displayNameToSave =
        name != null
            ? name.trim()
            : (firstName != null || lastName != null)
            ? [
              firstName?.trim() ?? '',
              lastName?.trim() ?? '',
            ].where((part) => part.isNotEmpty).join(' ')
            : null;
    if (displayNameToSave != null) {
      final uid = await AuthService.instance.getCurrentUserId();
      if (uid == null || uid.trim().isEmpty) {
        throw StateError('Cannot update Matrix displayname without a user ID.');
      }
      await MatrixProfileService.instance.setDisplayName(
        uid,
        displayNameToSave,
      );
      if (displayNameToSave.isEmpty) {
        await _storage.delete(key: _nameKey);
      } else {
        await _storage.write(key: _nameKey, value: displayNameToSave);
        await AuthService.instance.updateStoredUsername(displayNameToSave);
      }
      await _storage.delete(key: _firstNameKey);
      await _storage.delete(key: _lastNameKey);
    }
    if (profileImage != null) {
      final normalizedAvatar = _resolveAvatarUrl(profileImage.trim());
      final storedAvatar = await _storage.read(key: _profileImageKey) ?? '';
      if (storedAvatar != normalizedAvatar) {
        _avatarMutationRevision++;
        previousAvatarForEviction = storedAvatar;
      }
      await _storage.write(key: _profileImageKey, value: normalizedAvatar);
      backendFields['AvatarImg'] = normalizedAvatar;
    }
    if (bio != null) {
      await _storage.write(key: _bioKey, value: bio.trim());
      backendFields['Bio'] = bio.trim();
    }
    if (phoneNumber != null) {
      final cleanPhone = phoneNumber.trim();
      backendFields['Phone'] = cleanPhone;
    }
    if (links != null) {
      await _storage.write(key: 'user_links', value: links.join('\n'));
      backendFields['Link'] = links.join('\n');
    }
    if (channelAlias != null) {
      await _storage.write(
        key: 'profile_channel_alias',
        value: channelAlias.trim(),
      );
      backendFields['ChannelAlias'] = channelAlias.trim();
    }
    if (groupAlias != null) {
      await _storage.write(
        key: 'profile_group_alias',
        value: groupAlias.trim(),
      );
      backendFields['GroupAlias'] = groupAlias.trim();
    }
    if (visibilitySettings != null) {
      await _storage.write(
        key: 'profile_visibility_settings',
        value: jsonEncode(visibilitySettings),
      );
      backendFields['VisibilitySettings'] = jsonEncode(visibilitySettings);
    }
    if (backendFields.isNotEmpty) {
      await _saveBackendProfileBestEffort(backendFields);
    }
    _cache = null;
    await _refreshAndNotify(forceRefresh: true);
    if (previousAvatarForEviction != null) {
      await UserAvatar.evictCachedUrl(previousAvatarForEviction);
    }
  }

  /// Stream that emits the current user's profile immediately from cache,
  /// then re-reads from storage. Use this in widgets that need live updates
  /// (e.g. after the user saves a new name or avatar).
  Stream<UserProfile?> getCurrentUserProfileStream({
    bool backendFirst = false,
    bool refreshFromBackend = true,
  }) async* {
    if (backendFirst && !_suppressBackendProfileReads) {
      final backendProfile = await getCurrentUserProfileForLogin();
      if (backendProfile != null) yield backendProfile;
      yield* _profileController.stream;
      return;
    }

    // Emit cached value instantly so the UI has zero-latency first frame
    final uid = await AuthService.instance.getCurrentUserId();
    if (_cache != null && uid != null && uid.isNotEmpty && _cache!.uid == uid) {
      yield _cache;
    }

    // Then yield a local-only read. Network/profile refresh must not block
    // avatar paint in the bottom nav.
    final fresh = await _readFromStorage(allowBackendRefresh: false);
    if (fresh != null) yield fresh;
    if (refreshFromBackend &&
        !_suppressBackendProfileReads &&
        !_currentBackendProfileIsFresh) {
      unawaited(_refreshAndNotify(forceRefresh: true));
    }
    yield* _profileController.stream;
  }

  /// Warm the cache on app start — call from main.dart after auth restore.
  Future<void> warmUp() async {
    _cache = await _readFromStorage(allowBackendRefresh: false);
    _profileController.add(_cache);
    unawaited(_syncPendingAvatarAndRefresh());
  }

  /// Fetches another user's profile by their UID.
  /// For the current user, delegates to [getCurrentUserProfile].
  /// For other users, returns a minimal stub built from what we know locally
  /// (contacts, Matrix display name, etc.) — extend as your contact store grows.
  Future<UserProfile?> getProfileByUid(
    String uid, {
    String? phone,
    bool forceRefresh = false,
  }) async {
    final requestedUid = uid.trim();
    final cacheKey = _publicProfileCacheKey(requestedUid, phone);
    if (requestedUid.isEmpty ||
        requestedUid.startsWith('!') ||
        requestedUid.startsWith('@!')) {
      debugPrint(
        '[UserProfileService] skipped room-scoped profile lookup: "$requestedUid"',
      );
      return null;
    }
    debugPrint(
      '[UserProfileService] profile lookup user_id="$requestedUid" '
      'force_refresh=$forceRefresh',
    );

    // If it's the current user, use the full local profile
    final ownerProfile = await _publicProfileForOwner(uid);
    if (ownerProfile != null) {
      debugPrint(
        '[UserProfileService] profile source=owner_profile user_id="$requestedUid"',
      );
      return forceRefresh
          ? getCurrentUserProfile(forceRefresh: true)
          : ownerProfile;
    }

    if (!forceRefresh) {
      final cached = _publicProfileCache[cacheKey] ??
          cachedPublicProfileByUid(requestedUid);
      if (cached != null) {
        debugPrint(
          '[UserProfileService] profile source=public_cache user_id="$requestedUid"',
        );
        return cached;
      }
      if (_publicProfileMisses.contains(cacheKey)) {
        debugPrint(
          '[UserProfileService] profile source=negative_cache user_id="$requestedUid"',
        );
        return null;
      }

      final pending = _publicProfileInFlight[cacheKey];
      if (pending != null) {
        debugPrint(
          '[UserProfileService] profile source=in_flight_request user_id="$requestedUid"',
        );
        return pending;
      }
    } else {
      _publicProfileMisses.remove(cacheKey);
      final pending = _publicProfileInFlight[cacheKey];
      if (pending != null) {
        debugPrint(
          '[UserProfileService] profile source=in_flight_request user_id="$requestedUid" '
          'force_refresh=true',
        );
        return pending;
      }
    }

    debugPrint(
      '[UserProfileService] profile source=module_api user_id="$requestedUid"',
    );
    final future = _getProfileByUidRemote(uid, phone: phone);
    _publicProfileInFlight[cacheKey] = future;
    return future.whenComplete(() {
      if (identical(_publicProfileInFlight[cacheKey], future)) {
        _publicProfileInFlight.remove(cacheKey);
      }
    });
  }

  Future<UserProfile?> _getProfileByUidRemote(
    String uid, {
    String? phone,
  }) async {
    final generation = _sessionGeneration;
    final cacheKey = _publicProfileCacheKey(uid, phone);
    final localpart = _matrixLocalpart(uid).toLowerCase();
    final profileRevision = _publicProfileRevisions[localpart] ?? 0;
    final previousProfile = cachedPublicProfileByUid(uid, phone: phone);
    if (previousProfile?.profileImage.isNotEmpty == true &&
        !_publicProfilePreviousAvatarUrls.containsKey(localpart)) {
      _publicProfilePreviousAvatarUrls.putIfAbsent(
        localpart,
        () => previousProfile!.profileImage,
      );
    }
    final remote = await _readPublicBackendProfileBestEffort(uid, phone: phone);
    if (generation != _sessionGeneration) return null;
    if ((_publicProfileRevisions[localpart] ?? 0) != profileRevision) {
      return _getProfileByUidRemote(uid, phone: phone);
    }
    if (remote == null) {
      // A network/module failure is not a successful empty profile. Keep
      // existing UI/cache values and allow a later retry instead of clearing
      // identity fields on transient errors.
      return null;
    }
    if (!_matchesRequestedPublicProfile(remote, uid: uid, phone: phone)) {
      debugPrint(
        '[UserProfileService] rejected unverified public profile for "$uid"',
      );
      final fallback = _fallbackPublicProfile(uid, phone: phone);
      _publicProfileCache[cacheKey] = fallback;
      return fallback;
    }
    var profile = _profileFromBackendFields(uid, remote, fallbackPhone: phone);
    if (profile.hasProfileImage) {
      profile = profile.copyWith(
        profileImage: _withAvatarFetchVersion(
          profile.profileImage,
          uid,
          profile.avatarVersion,
        ),
      );
    }
    profile = _reuseStablePublicAvatar(cacheKey, profile);
    final previousAvatar = _publicProfilePreviousAvatarUrls.remove(localpart);
    if (previousAvatar != null &&
        previousAvatar.isNotEmpty &&
        previousAvatar != profile.profileImage) {
      await UserAvatar.evictCachedUrl(previousAvatar);
      if (profile.hasProfileImage) {
        unawaited(
          AvatarPreloadService.replace(
            oldUrl: previousAvatar,
            newUrl: profile.profileImage,
          ),
        );
      }
    }
    // Public/member avatars remain URL-backed and are cached lazily by
    // CachedNetworkImage when rendered. Eager file downloads here duplicated
    // that cache and repeatedly timed out for profiles not on screen.
    _publicProfileCache[cacheKey] = profile;
    return profile;
  }

  /// Wipe cache on logout.
  void clearCache() {
    _sessionGeneration += 1;
    _profileReadRevision += 1;
    _avatarMutationRevision += 1;
    _activeAccountUid = null;
    _cache = null;
    _publicProfileCache.clear();
    _publicProfileInFlight.clear();
    _publicProfilePreviousAvatarUrls.clear();
    _publicProfileRevisions.clear();
    _publicProfileMisses.clear();
    _loginProfileInFlight = null;
    _currentProfileBackendFetchedAt = null;
    _profileController.add(null);
  }

  /// Called before the logout storage purge starts. It prevents outgoing
  /// widgets from starting another read against the former account while its
  /// shared legacy storage keys are being deleted.
  void beginLogout() {
    _logoutInProgress = true;
    clearCache();
  }

  // Expose cached value synchronously for widgets that need it immediately
  UserProfile? get cachedProfile => _cache;

  UserProfile? cachedPublicProfileByUid(String uid, {String? phone}) {
    final localpart = _matrixLocalpart(uid).toLowerCase();
    if (localpart.isEmpty) return null;

    final cacheKey = _publicProfileCacheKey(uid, phone);
    return _publicProfileCache[cacheKey];
  }

  Future<UserProfile?> _publicProfileForOwner(String uid) async {
    final currentUid = await AuthService.instance.getCurrentUserId();
    if (currentUid == null ||
        _matrixLocalpart(currentUid).toLowerCase() !=
            _matrixLocalpart(uid).toLowerCase()) {
      return null;
    }
    return getCurrentUserProfile();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE
  // ─────────────────────────────────────────────────────────────────────────

  Future<UserProfile?> _readFromStorage({
    bool forceRefresh = false,
    bool allowBackendRefresh = true,
    bool ignoreStoredAvatar = false,
    bool ignoreStoredProfile = false,
  }) async {
    final readRevision = ++_profileReadRevision;
    final avatarRevisionAtStart = _avatarMutationRevision;
    try {
      if (_logoutInProgress) return null;
      final uid = await AuthService.instance.getCurrentUserId();
      if (uid == null || uid.isEmpty) return null;
      final generation = _bindActiveAccount(uid);
      if (_logoutInProgress || !_isActiveSession(generation, uid)) return null;

      var phone = _normalizePhone(await _storage.read(key: _phoneKey) ?? '');
      var name =
          ignoreStoredProfile ? '' : await _storage.read(key: _nameKey) ?? '';
      var bio =
          ignoreStoredProfile ? '' : await _storage.read(key: _bioKey) ?? '';
      var moduleProfileLoaded = false;
      var onlineStatus = '';
      var channelAlias = '';
      var groupAlias = '';
      var visibilitySettings = <String, String>{};
      if (!ignoreStoredProfile) {
        channelAlias = await _storage.read(key: 'profile_channel_alias') ?? '';
        groupAlias = await _storage.read(key: 'profile_group_alias') ?? '';
        final storedVisibility =
            await _storage.read(key: 'profile_visibility_settings') ?? '';
        if (storedVisibility.isNotEmpty) {
          final decoded = jsonDecode(storedVisibility);
          if (decoded is Map) {
            visibilitySettings = decoded.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            );
          }
        }
      }
      var profileImage =
          ignoreStoredAvatar || ignoreStoredProfile
              ? ''
              : await _storage.read(key: _profileImageKey) ?? '';
      var localProfileImagePath =
          ignoreStoredAvatar || ignoreStoredProfile
              ? ''
              : await _readLocalProfileImagePath(uid);
      var avatarVersion =
          ignoreStoredAvatar || ignoreStoredProfile
              ? 0
              : await _readAvatarVersion(uid);
      var matrixDisplayNameLoaded = false;

      if (forceRefresh && !ignoreStoredProfile) {
        final uploaded = await _syncPendingAvatarUploadForUid(uid);
        if (uploaded) {
          profileImage = await _storage.read(key: _profileImageKey) ?? '';
          localProfileImagePath = await _readLocalProfileImagePath(uid);
        }
      }

      if (allowBackendRefresh &&
          !_suppressBackendProfileReads &&
          (forceRefresh || !_hasRealName(name) || profileImage.isEmpty)) {
        final remote = await _readBackendProfileBestEffort();
        if (!_isActiveSession(generation, uid) ||
            readRevision != _profileReadRevision) {
          return null;
        }
        if (remote.isNotEmpty) {
          moduleProfileLoaded = true;
          matrixDisplayNameLoaded = remote.containsKey('DisplayName');
          final remotePhone = _normalizePhone(_field(remote, 'Phone') ?? '');
          if (remotePhone.isNotEmpty) phone = remotePhone;
          // A successful Module response is authoritative: omitted fields
          // have been deleted or are no longer visible, so clear stale local
          // values instead of carrying them forward.
          bio = _field(remote, 'Bio') ?? '';
          onlineStatus = _field(remote, 'Presence') ?? '';
          channelAlias = _field(remote, 'ChannelAlias') ?? '';
          groupAlias = _field(remote, 'GroupAlias') ?? '';
          final visibilityJson = _field(remote, 'VisibilitySettings');
          visibilitySettings = <String, String>{};
          if (visibilityJson != null && visibilityJson.isNotEmpty) {
            final decoded = jsonDecode(visibilityJson);
            if (decoded is Map) {
              visibilitySettings = decoded.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              );
            }
          }
          final remoteAvatarVersion = _avatarVersionFromFields(remote);
          if (avatarRevisionAtStart != _avatarMutationRevision ||
              remoteAvatarVersion < avatarVersion) {
            // A local avatar write began while this profile request was in
            // flight, or the backend response carries an older version. Keep
            // the committed FE source instead of restoring a stale avatar.
            profileImage = await _storage.read(key: _profileImageKey) ?? '';
            localProfileImagePath = await _readLocalProfileImagePath(uid);
            avatarVersion = await _readAvatarVersion(uid);
          } else {
            final remoteAvatar = _resolveAvatarUrl(
              _field(remote, 'AvatarImg') ?? '',
            );
            if (remoteAvatar.isNotEmpty &&
                !_avatarUrlBelongsToUid(remoteAvatar, uid)) {
              debugPrint(
                '[UserProfileService] rejected cross-account current avatar '
                'active_user="$uid" avatar_url="$remoteAvatar"',
              );
              profileImage = '';
            } else {
              profileImage = remoteAvatar;
            }
            avatarVersion = remoteAvatarVersion;
            if (profileImage.isNotEmpty) {
              profileImage = _withAvatarFetchVersion(
                profileImage,
                uid,
                avatarVersion,
              );
            }
          }
          final remoteName =
              (_field(remote, 'DisplayName') ??
                      _field(remote, 'displayname') ??
                      '')
                  .trim();
          if (matrixDisplayNameLoaded) {
            if (!_isActiveSession(generation, uid)) return null;
            name = remoteName;
            await _storage.delete(key: _firstNameKey);
            await _storage.delete(key: _lastNameKey);
            if (_hasRealName(name)) {
              await _storage.write(key: _nameKey, value: name);
              await AuthService.instance.updateStoredUsername(name);
            } else {
              await _storage.delete(key: _nameKey);
              await AuthService.instance.clearStoredUsername();
            }
          }
          if (!_isActiveSession(generation, uid)) return null;
          await _storage.write(key: _bioKey, value: bio);
          await _storage.write(
            key: 'profile_channel_alias',
            value: channelAlias,
          );
          await _storage.write(key: 'profile_group_alias', value: groupAlias);
          await _storage.write(
            key: 'user_links',
            value: _field(remote, 'Link') ?? '',
          );
          await _storage.write(
            key: 'profile_visibility_settings',
            value: jsonEncode(visibilitySettings),
          );
          if (avatarRevisionAtStart == _avatarMutationRevision) {
            if (profileImage.isNotEmpty) {
              await _storage.write(key: _profileImageKey, value: profileImage);
              await _writeAvatarVersion(uid, avatarVersion);
            } else {
              await _storage.delete(key: _profileImageKey);
              await _writeAvatarVersion(uid, 0);
              final prefs = await SharedPreferences.getInstance();
              final pendingPath =
                  prefs.getString(_pendingProfileImageKey(uid))?.trim() ?? '';
              if (pendingPath.isNotEmpty && File(pendingPath).existsSync()) {
                localProfileImagePath = pendingPath;
              } else {
                localProfileImagePath = '';
                await _clearLocalAvatarCache(uid);
              }
            }
          }
          _currentProfileBackendFetchedAt = DateTime.now();
        }
      }
      if (!_hasRealName(name) &&
          !ignoreStoredProfile &&
          !matrixDisplayNameLoaded) {
        await AuthService.instance.getValidBackendToken();
        name = await _storage.read(key: _nameKey) ?? name;
      }
      if (!_hasRealName(name) &&
          !ignoreStoredProfile &&
          !matrixDisplayNameLoaded) {
        final restored = await AuthService.instance.hydrateStoredProfile(uid);
        if (restored != null && restored.hasUsableName) {
          name = restored.username;
          await _storage.write(key: _nameKey, value: name);
        }
      }
      final linksRaw =
          ignoreStoredProfile
              ? ''
              : await _storage.read(key: 'user_links') ?? '';

      if (avatarRevisionAtStart != _avatarMutationRevision) {
        profileImage = await _storage.read(key: _profileImageKey) ?? '';
        localProfileImagePath = await _readLocalProfileImagePath(uid);
        avatarVersion = await _readAvatarVersion(uid);
      }

      final profile = UserProfile(
        uid: uid,
        name: name,
        username: name, // username == display name in this app
        phone: phone,
        bio: bio,
        profileImage: profileImage,
        onlineStatus: onlineStatus,
        channelAlias: channelAlias,
        groupAlias: groupAlias,
        visibilitySettings: visibilitySettings,
        avatarVersion: avatarVersion,
        moduleProfileLoaded: moduleProfileLoaded,
        localProfileImagePath: localProfileImagePath,
        links:
            linksRaw
                .split('\n')
                .map((link) => link.trim())
                .where((link) => link.isNotEmpty)
                .toList(),
      );

      // A logout/account switch may finish while a backend request from the
      // previous screen is still in flight. Never allow that stale completion
      // to repopulate the process-wide profile cache for the next account.
      if (!_isActiveSession(generation, uid) ||
          readRevision != _profileReadRevision) {
        return null;
      }
      _cache = profile;
      _profileController.add(profile);
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
    cleaned = _stripInvalidNorthAmericaPrefix(cleaned);
    return cleaned;
  }

  /// Binds all current-profile reads to one authenticated account. Secure
  /// storage uses a few legacy shared keys, so an async read that belongs to
  /// a former account must become invalid as soon as another account starts.
  int _bindActiveAccount(String uid) {
    final normalizedUid = _matrixLocalpart(uid).toLowerCase();
    if (_activeAccountUid == normalizedUid) return _sessionGeneration;

    _sessionGeneration += 1;
    _activeAccountUid = normalizedUid;
    _cache = null;
    _loginProfileInFlight = null;
    _currentProfileBackendFetchedAt = null;
    _profileController.add(null);
    debugPrint(
      '[UserProfileService] profile session bound '
      'user_id="$normalizedUid" generation=$_sessionGeneration',
    );
    return _sessionGeneration;
  }

  bool _isActiveSession(int generation, String uid) {
    return generation == _sessionGeneration &&
        _activeAccountUid == _matrixLocalpart(uid).toLowerCase();
  }

  /// Backend avatar paths are account-owned (for example
  /// `/usrimg/<user-id>/avatar_img.jpg`). Never display an avatar whose path
  /// identifies another account, even if a stale response reaches this code.
  bool _avatarUrlBelongsToUid(String avatarUrl, String uid) {
    if (avatarUrl.trim().startsWith('mxc://')) return true;
    final owner = _matrixLocalpart(uid).toLowerCase();
    final path =
        Uri.tryParse(avatarUrl)?.path.toLowerCase() ??
        avatarUrl.toLowerCase().split('?').first;
    return path.contains('/$owner/');
  }

  bool get _currentBackendProfileIsFresh {
    final fetchedAt = _currentProfileBackendFetchedAt;
    return fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _currentProfileFreshness;
  }

  String _stripInvalidNorthAmericaPrefix(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (!phone.startsWith('+1')) return phone;
    if (digits.length <= 11) return phone;
    return '+${digits.substring(1)}';
  }

  String _trustedPhone(String backendPhone, {String? fallbackPhone}) {
    final normalizedBackend = _normalizePhone(backendPhone);
    final normalizedFallback = _normalizePhone(fallbackPhone ?? '');
    if (normalizedBackend.isEmpty) return normalizedFallback;
    if (normalizedFallback.isEmpty) return normalizedBackend;

    final backendDigits = normalizedBackend.replaceAll(RegExp(r'[^\d]'), '');
    final fallbackDigits = normalizedFallback.replaceAll(RegExp(r'[^\d]'), '');
    final backendLooksLikePrefixedFallback =
        backendDigits.startsWith('1') &&
        backendDigits.substring(1) == fallbackDigits;
    if (backendLooksLikePrefixedFallback) {
      return normalizedFallback;
    }

    return normalizedBackend;
  }

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
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

  String? _field(Map<String, String> fields, String wanted) {
    for (final entry in fields.entries) {
      if (entry.key.toLowerCase() == wanted.toLowerCase()) {
        return entry.value.trim();
      }
    }
    return null;
  }

  String _resolveAvatarUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) return trimmed;
    if (trimmed.startsWith('/')) return '${ApiService.baseUrl}$trimmed';
    return '${ApiService.baseUrl}/$trimmed';
  }

  Future<String> _uploadAvatarToMatrix(File file) async {
    await FileUploadLimits.validateAvatarImagePath(file.path);
    final matrix = MatrixClientService.instance.client;
    final bytes = await file.readAsBytes();
    final matrixFile = MatrixFile(
      bytes: bytes,
      name: file.uri.pathSegments.last,
      mimeType: _avatarMimeType(file.path),
    );
    final mxc = await matrix.uploadContent(
      matrixFile.bytes,
      filename: matrixFile.name,
      contentType: matrixFile.mimeType,
    );
    final value = mxc.toString();
    if (!value.startsWith('mxc://')) {
      throw StateError('Matrix media upload returned an invalid MXC URI.');
    }
    return value;
  }

  String _avatarMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  String _localProfileImageKey(String uid) =>
      '$_localProfileImagePrefix${_matrixLocalpart(uid)}';

  String _pendingProfileImageKey(String uid) =>
      '$_pendingProfileImagePrefix${_matrixLocalpart(uid)}';

  String _avatarVersionKey(String uid) =>
      '$_avatarVersionPrefix${_matrixLocalpart(uid)}';

  Future<int> _readAvatarVersion(String uid) async {
    final raw = await _storage.read(key: _avatarVersionKey(uid)) ?? '';
    final parsed = int.tryParse(raw) ?? 0;
    return parsed < 0 ? 0 : parsed;
  }

  Future<void> _writeAvatarVersion(String uid, int version) {
    return _storage.write(
      key: _avatarVersionKey(uid),
      value: (version < 0 ? 0 : version).toString(),
    );
  }

  Future<String> _readLocalProfileImagePath(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_localProfileImageKey(uid))?.trim() ?? '';
    if (path.isEmpty) return '';
    return File(path).existsSync() ? path : '';
  }

  Future<void> _clearLocalAvatarCache(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_localProfileImageKey(uid))?.trim() ?? '';
    await prefs.remove(_localProfileImageKey(uid));
    if (path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (error) {
        debugPrint('[UserProfileService] local avatar cleanup skipped: $error');
      }
    }
  }

  Future<void> _deleteCachedAvatarFile(
    String oldPath, {
    required String keepPath,
  }) async {
    final oldFilePath = oldPath.trim();
    if (oldFilePath.isEmpty || oldFilePath == keepPath.trim()) return;
    try {
      final oldFile = File(oldFilePath);
      if (await oldFile.exists()) await oldFile.delete();
    } catch (error) {
      debugPrint('[UserProfileService] old avatar cleanup skipped: $error');
    }
  }

  Future<String> _cacheProfileImageFile(String uid, File source) async {
    final supportDir = await getApplicationSupportDirectory();
    final avatarDir = Directory('${supportDir.path}/profile_avatars');
    if (!avatarDir.existsSync()) {
      await avatarDir.create(recursive: true);
    }
    final ext = _imageExtension(source.path);
    final safeUid = _matrixLocalpart(
      uid,
    ).replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final destination = File('${avatarDir.path}/$safeUid-$stamp$ext');
    if (source.path == destination.path) return destination.path;
    await source.copy(destination.path);
    unawaited(_deleteOlderLocalAvatarFiles(avatarDir, safeUid, destination));
    return destination.path;
  }

  Future<void> _deleteOlderLocalAvatarFiles(
    Directory avatarDir,
    String safeUid,
    File keep,
  ) async {
    try {
      if (!avatarDir.existsSync()) return;
      await for (final entity in avatarDir.list()) {
        if (entity is! File) continue;
        if (entity.path == keep.path) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('$safeUid-')) continue;
        await entity.delete();
      }
    } catch (e) {
      debugPrint('[UserProfileService] Old local avatar cleanup skipped: $e');
    }
  }

  String _imageExtension(String path) {
    final lower = path.toLowerCase();
    for (final ext in const ['.jpg', '.jpeg', '.png', '.webp']) {
      if (lower.endsWith(ext)) return ext;
    }
    return '.jpg';
  }

  Future<bool> _syncPendingAvatarUploadForUid(String uid) async {
    final lastAttempt = _lastPendingAvatarAttemptAt;
    if (lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(seconds: 30)) {
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    final pendingPath = prefs.getString(_pendingProfileImageKey(uid)) ?? '';
    if (pendingPath.trim().isEmpty) return false;
    final file = File(pendingPath);
    if (!file.existsSync()) {
      await prefs.remove(_pendingProfileImageKey(uid));
      return false;
    }
    try {
      _lastPendingAvatarAttemptAt = DateTime.now();
      final uploadedPath = await _uploadAvatarToMatrix(file);
      final requestedAvatarUrl = uploadedPath;
      if (requestedAvatarUrl.isEmpty) return false;
      final currentAvatar = await MatrixProfileService.instance.getProfile(uid);
      final avatarVersion = await MatrixProfileService.instance
          .setAvatarImageAndVersion(
            uid,
            mxcUrl: requestedAvatarUrl,
            create: currentAvatar.avatarUrl?.trim().isNotEmpty != true,
          );
      final savedAvatar = await MatrixProfileService.instance.getProfile(uid);
      final avatarUrl = _withAvatarFetchVersion(
        savedAvatar[WrytteProfile.avatarImageUrl]?.trim().isNotEmpty == true
            ? savedAvatar[WrytteProfile.avatarImageUrl]!
            : requestedAvatarUrl,
        uid,
        avatarVersion,
      );
      final previousAvatarUrl =
          await _storage.read(key: _profileImageKey) ?? '';
      _avatarMutationRevision++;
      await _storage.write(key: _profileImageKey, value: avatarUrl);
      await _writeAvatarVersion(uid, avatarVersion);
      await prefs.remove(_pendingProfileImageKey(uid));
      await UserAvatar.evictCachedUrl(previousAvatarUrl);
      return true;
    } catch (e) {
      debugPrint(
        '[UserProfileService] Pending avatar upload retry skipped: $e',
      );
      return false;
    }
  }

  UserProfile _profileFromBackendFields(
    String uid,
    Map<String, String> fields, {
    String? fallbackPhone,
  }) {
    final displayName =
        _field(fields, 'displayname') ??
        _field(fields, 'DisplayName') ??
        _field(fields, 'displayName') ??
        _field(fields, 'Name') ??
        _field(fields, 'name') ??
        _field(fields, 'Username') ??
        '';
    final avatar =
        _field(fields, 'AvatarImg') ??
        _field(fields, 'avatarImg') ??
        _field(fields, 'AvatarUrl') ??
        _field(fields, 'avatarUrl') ??
        _field(fields, 'ProfileImage') ??
        '';
    final backendPhone =
        _field(fields, 'Phone') ?? _field(fields, 'phone') ?? '';
    final wrytteId = WrytteId.forDisplay(backendPhone);
    final rawVisibility = _field(fields, 'VisibilitySettings') ?? '';
    var visibilitySettings = <String, String>{};
    if (rawVisibility.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawVisibility);
        if (decoded is Map) {
          visibilitySettings = decoded.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          );
        }
      } catch (_) {}
    }

    return UserProfile(
      uid: uid,
      name: displayName.trim(),
      username: displayName.trim(),
      phone:
          wrytteId ?? _trustedPhone(backendPhone, fallbackPhone: fallbackPhone),
      bio: _field(fields, 'Bio') ?? _field(fields, 'bio') ?? '',
      profileImage: _resolveAvatarUrl(avatar),
      onlineStatus: _field(fields, 'Presence') ?? '',
      channelAlias: _field(fields, 'ChannelAlias') ?? '',
      groupAlias: _field(fields, 'GroupAlias') ?? '',
      visibilitySettings: visibilitySettings,
      avatarVersion: _avatarVersionFromFields(fields),
      moduleProfileLoaded: true,
      links:
          [
                _field(fields, 'Link'),
                _field(fields, 'link'),
                _field(fields, 'Website'),
                _field(fields, 'website'),
              ]
              .whereType<String>()
              .where((link) => link.trim().isNotEmpty)
              .toList(),
    );
  }

  UserProfile _reuseStablePublicAvatar(String cacheKey, UserProfile fresh) {
    final cached = _publicProfileCache[cacheKey];
    if (cached == null) return fresh;
    if (fresh.moduleProfileLoaded) return fresh;

    final freshAvatar = fresh.profileImage.trim();
    final cachedAvatar = cached.profileImage.trim();
    if (freshAvatar.isEmpty) {
      return fresh.copyWith(
        profileImage: cachedAvatar.isNotEmpty ? cachedAvatar : null,
        localProfileImagePath:
            cached.localProfileImagePath.trim().isNotEmpty
                ? cached.localProfileImagePath
                : null,
      );
    }

    if (_stripAvatarVersion(freshAvatar) == _stripAvatarVersion(cachedAvatar)) {
      return fresh.copyWith(
        // The backend currently reuses filenames such as `avatar_img.jpg`.
        // Keep the fresh fetch version so CachedNetworkImage cannot serve an
        // older file merely because the base path did not change.
        profileImage: freshAvatar,
        localProfileImagePath:
            cached.localProfileImagePath.trim().isNotEmpty
                ? cached.localProfileImagePath
                : null,
      );
    }

    return fresh;
  }

  String _stripAvatarVersion(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return url;
    final params = Map<String, String>.from(uri.queryParameters)..remove('v');
    return uri
        .replace(queryParameters: params.isEmpty ? null : params)
        .toString();
  }

  String _withAvatarFetchVersion(String url, String userId, int avatarVersion) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.startsWith('mxc://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null) return trimmed;
      return uri
          .replace(
            queryParameters: {
              ...uri.queryParameters,
              'v': '${_matrixLocalpart(userId).toLowerCase()}-$avatarVersion',
            },
          )
          .toString();
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) return trimmed;
    // A fetch timestamp is not an avatar version. Using it here changed the
    // URL on every profile read, bypassed the image cache, and made the same
    // avatar download again when opening the header/profile. Version zero is
    // deliberately stable for older backend records. A real backend
    // AvatarVersion still changes the URL immediately after an upload.
    final version = avatarVersion.toString();
    final params = Map<String, String>.from(uri.queryParameters)
      ..['v'] =
          '${_matrixLocalpart(userId).toLowerCase()}-'
          '$version';
    return uri.replace(queryParameters: params).toString();
  }

  int _avatarVersionFromFields(Map<String, String> fields) {
    final raw =
        _field(fields, 'AvatarVersion') ??
        _field(fields, 'avatar_version') ??
        '';
    final parsed = int.tryParse(raw) ?? 0;
    return parsed < 0 ? 0 : parsed;
  }

  UserProfile _fallbackPublicProfile(String uid, {String? phone}) {
    return UserProfile(
      uid: uid,
      name: '',
      username: '',
      phone: _normalizePhone(phone ?? ''),
      bio: '',
      profileImage: '',
      links: const [],
    );
  }

  bool _matchesRequestedPublicProfile(
    Map<String, String> fields, {
    required String uid,
    String? phone,
  }) {
    final targetLocalpart = _matrixLocalpart(uid);
    final idFields = [
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
    ];
    for (final key in idFields) {
      final value = _field(fields, key);
      if (value == null || value.isEmpty) continue;
      if (_matrixLocalpart(value) == targetLocalpart) return true;
    }

    final requestedPhone = _normalizePhone(phone ?? '');
    final returnedPhone = _normalizePhone(
      _field(fields, 'Phone') ?? _field(fields, 'phone') ?? '',
    );
    if (requestedPhone.isNotEmpty &&
        returnedPhone.isNotEmpty &&
        requestedPhone == returnedPhone) {
      return true;
    }

    return false;
  }

  Future<Map<String, String>> _readBackendProfileBestEffort() async {
    try {
      final uid = await AuthService.instance.getCurrentUserId();
      if (uid == null || uid.trim().isEmpty) return const {};
      return _moduleProfileFields(
        await MatrixProfileService.instance.getProfile(uid),
        ownerRead: true,
      );
    } catch (e) {
      debugPrint('[UserProfileService] Module profile get skipped: $e');
      return const {};
    }
  }

  Future<UserProfile?> _refreshAndNotify({bool forceRefresh = false}) async {
    return _readFromStorage(forceRefresh: forceRefresh);
  }

  Future<void> _syncPendingAvatarAndRefresh() async {
    try {
      await syncPendingAvatarUpload();
      await _refreshAndNotify(forceRefresh: true);
    } catch (e) {
      debugPrint('[UserProfileService] Warmup avatar refresh skipped: $e');
    }
  }

  Future<Map<String, String>?> _readPublicBackendProfileBestEffort(
    String uid, {
    String? phone,
  }) async {
    try {
      return _moduleProfileFields(
        await MatrixProfileService.instance.getProfile(uid),
        fallbackUid: uid,
      );
    } catch (e) {
      debugPrint('[UserProfileService] Public Module profile get skipped: $e');
      return null;
    }
  }

  String _publicProfileCacheKey(String uid, String? phone) {
    return _matrixLocalpart(uid).toLowerCase();
  }

  Future<void> _saveBackendProfileBestEffort(
    Map<String, String> fields, {
    bool create = false,
  }) async {
    try {
      final uid = await AuthService.instance.getCurrentUserId();
      if (uid == null || uid.trim().isEmpty) return;
      final moduleFields = <String, dynamic>{};
      final visibility = <String, String>{};
      for (final entry in fields.entries) {
        switch (entry.key.toLowerCase()) {
          case 'bio':
            moduleFields[WrytteProfile.bio] = entry.value;
            break;
          case 'phone':
            moduleFields[WrytteProfile.phoneNumber] = entry.value;
            break;
          case 'link':
          case 'website':
            moduleFields[WrytteProfile.link] = entry.value;
            break;
          case 'channelalias':
            moduleFields[WrytteProfile.channelAlias] = entry.value;
            break;
          case 'groupalias':
            moduleFields[WrytteProfile.groupAlias] = entry.value;
            break;
          case 'visibilitysettings':
            try {
              final decoded = jsonDecode(entry.value);
              if (decoded is Map) {
                visibility.addAll(
                  decoded.map(
                    (key, value) => MapEntry(key.toString(), value.toString()),
                  ),
                );
              }
            } catch (_) {}
            break;
          case 'avatarimg':
          case 'avatarurl':
          case 'profileimage':
            moduleFields[WrytteProfile.avatarImageUrl] = entry.value;
            break;
        }
      }
      if (create) {
        moduleFields.removeWhere((_, value) => value.toString().trim().isEmpty);
        await MatrixProfileService.instance.addFields(
          uid,
          fields: moduleFields,
          visibility: visibility,
        );
      } else {
        await MatrixProfileService.instance.updateOwnerProfile(
          userId: uid,
          bio: moduleFields[WrytteProfile.bio]?.toString(),
          phoneNumber: moduleFields[WrytteProfile.phoneNumber]?.toString(),
          link: moduleFields[WrytteProfile.link]?.toString(),
          channelAlias: moduleFields[WrytteProfile.channelAlias]?.toString(),
          groupAlias: moduleFields[WrytteProfile.groupAlias]?.toString(),
          visibilitySettings: visibility.isEmpty ? null : visibility,
          avatarUrl: moduleFields[WrytteProfile.avatarImageUrl]?.toString(),
        );
      }
    } catch (e) {
      debugPrint('[UserProfileService] Module profile save skipped: $e');
      rethrow;
    }
  }

  Map<String, String> _moduleProfileFields(
    WrytteProfile profile, {
    String? fallbackUid,
    bool ownerRead = false,
  }) {
    final raw = profile.fields;
    final result = <String, String>{
      'userId': fallbackUid ?? profile.userId,
      'userid': fallbackUid ?? profile.userId,
    };
    void copy(String source, String target) {
      final value = raw[source]?.toString().trim() ?? '';
      if (value.isNotEmpty) result[target] = value;
    }

    copy(WrytteProfile.phoneNumber, 'Phone');
    copy(WrytteProfile.avatarImageUrl, 'AvatarImg');
    copy(WrytteProfile.avatarVersion, 'AvatarVersion');
    copy(WrytteProfile.bio, 'Bio');
    copy(WrytteProfile.link, 'Link');
    copy(WrytteProfile.channelAlias, 'ChannelAlias');
    copy(WrytteProfile.groupAlias, 'GroupAlias');
    if (raw.containsKey('displayname')) {
      result['DisplayName'] = raw['displayname']?.toString().trim() ?? '';
    }
    // The Module's Matrix presence value is authoritative. Keep the custom
    // field as a compatibility fallback for older Module responses.
    copy('presence', 'Presence');
    if (!result.containsKey('Presence')) {
      copy(WrytteProfile.onlineStatus, 'Presence');
    }
    result['VisibilitySettings'] = jsonEncode(profile.visibilitySettings);
    debugPrint(
      '[ModuleProfile.map] user_id="${fallbackUid ?? profile.userId}" '
      'owner_read=$ownerRead '
      'custom_avatar_present=${raw[WrytteProfile.avatarImageUrl]?.toString().trim().isNotEmpty == true} '
      'matrix_avatar_present=false '
      'avatar_returned=${result['AvatarImg']?.trim().isNotEmpty == true} '
      'bio_present=${raw[WrytteProfile.bio]?.toString().trim().isNotEmpty == true} '
      'bio_returned=${result['Bio']?.trim().isNotEmpty == true}',
    );
    return result;
  }
}
