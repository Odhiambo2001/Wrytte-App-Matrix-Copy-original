import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/matrix/matrix_profile_service.dart';
import 'package:wrytte/services/matrix/block_state_service.dart';
import 'package:wrytte/services/matrix/mute_rooms_service.dart';
import 'package:wrytte/models/user_models/wrytte_profile.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';
import 'package:wrytte/ui/auth/widgets/sync_contacts_switch.dart';
import 'package:wrytte/ui/auth/widgets/wrytte_id_checkmark.dart';
import 'package:wrytte/ui/screens/channels/channel_feed_screen.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/widgets/full_screen_image_viewer.dart';
import 'package:wrytte/ui/widgets/full_screen_video_viewer.dart';
import 'package:wrytte/ui/widgets/profile_tab_bar_section.dart';
import 'package:wrytte/ui/widgets/wrytte_file_card.dart';
import 'package:wrytte/ui/widgets/wrytte_link_preview.dart';
import 'package:wrytte/ui/widgets/wrytte_persistent_image.dart';
import 'package:wrytte/ui/widgets/wrytte_video_thumbnail.dart';
import 'package:wrytte/data/repositories/camera_repository_impl.dart';
import 'package:wrytte/data/services/camera_capabilities_service.dart';
import 'package:wrytte/data/services/camera_session_manager.dart';
import 'package:wrytte/data/services/device_camera_service.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';
import 'package:wrytte/ui/camera/views/wrytte_camera_route.dart';
import 'package:wrytte/utils/wrytte_id.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'package:wrytte/utils/country_phone_number.dart';
import 'edit_profile_screen.dart';

enum ProfileContactStatus { saved, unsaved }

class ProfileScreen extends StatefulWidget {
  /// When null — shows the current logged-in user's own profile.
  /// When provided — shows another user's profile (read-only).
  final String? uid;
  final String? conversationId;
  final String? savedNameHint;
  final String? initialAvatarUrl;
  final String? initialProfileName;
  final ProfileContactStatus? contactStatus;
  final bool embeddedInHome;

  const ProfileScreen({
    super.key,
    this.uid,
    this.conversationId,
    this.savedNameHint,
    this.initialAvatarUrl,
    this.initialProfileName,
    this.contactStatus,
    this.embeddedInHome = false,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  bool _bioExpanded = false;
  bool _linksExpanded = false;

  UserProfile? _profile;
  Contact? _savedContact;
  ContactIdentity? _identity;
  bool _profileLoading = true;
  bool _showBlockUserCard = false;
  bool _showMoreOptions = false;
  bool _showMuteOptions = false;
  bool _showClearChatConfirmation = false;
  bool _roomMuted = false;
  final LayerLink _moreOptionsLayerLink = LayerLink();
  bool _redactedByBlock = false;
  List<ChatMessage> _conversationMessages = const [];
  StreamSubscription<UserProfile?>? _profileSub;
  StreamSubscription<String>? _publicProfileUpdatesSub;
  String? _seededSavedName;
  MatrixPublicGroup? _profileChannel;
  MatrixPublicGroup? _profileGroup;
  int _profileRoomResolveRevision = 0;
  bool _statusIconBuildLogged = false;
  bool _blockActionInFlight = false;
  bool _profileUnblockRefreshInFlight = false;

  late final TabController _tabController;

  bool get _isOtherUser {
    final uid = _profileTargetUserId;
    final ownUid = UserProfileService.instance.cachedProfile?.uid;
    if (uid != null && uid != ownUid) return true;
    return widget.conversationId?.trim().isNotEmpty ?? false;
  }

  String? get _profileTargetUserId =>
      _validProfileUid(widget.uid) ??
      _validProfileUid(_identity?.matrixUserId) ??
      _validProfileUid(_savedContact?.wrytteUserId) ??
      _validProfileUid(_profile?.uid);

  bool _isBlockedByBbb(String? userId, {String? roomId}) {
    final target = userId == null ? '' : _matrixLocalpart(userId).toLowerCase();
    if (target.isEmpty) return false;
    final effectiveRoom = roomId ?? widget.conversationId;
    // The owner must also redact a profile when the owner blocked that user.
    // BBB covers the inverse direction only.
    if (BlockStateService.instance.isBlocklisted(
      effectiveRoom ?? '',
      peerId: userId,
    )) {
      return true;
    }
    return BlockStateService.instance.isRedactedByBbb(
      userId!,
      roomId: effectiveRoom,
    );
  }

  bool get _showUnsavedProfileActions =>
      _isOtherUser &&
      widget.contactStatus != ProfileContactStatus.saved &&
      (widget.contactStatus == ProfileContactStatus.unsaved ||
          !_hasSavedContactHint) &&
      _savedContact == null &&
      _cleanName(_identity?.savedName).isEmpty;

  bool get _hasSavedContactHint =>
      widget.contactStatus == ProfileContactStatus.saved ||
      _cleanName(widget.savedNameHint).isNotEmpty;

  bool get _isProfileUserBlocked {
    final userId = _profileTargetUserId;
    if (userId == null) return false;
    try {
      return BlockStateService.instance.isBlocklisted(
            widget.conversationId ?? '',
            peerId: userId,
          );
    } catch (_) {
      return false;
    }
  }

  List<String> get _tabs =>
      _isOtherUser ? ['Media', 'Files', 'Feed', 'Links'] : ['Posts', 'Saved'];

  @override
  void initState() {
    super.initState();
    BlockStateService.instance.revision.addListener(_onBlockStateChanged);
    if (_isOtherUser) {
      final hintedUserId = _validProfileUid(widget.uid);
      if (hintedUserId != null) {
        _redactedByBlock = _isBlockedByBbb(
          hintedUserId,
          roomId: widget.conversationId,
        );
      }
    }
    _seededSavedName = _cleanName(
      widget.savedNameHint,
    );
    _tabController = TabController(length: _tabs.length, vsync: this);
    _seedProfileForFirstPaint();
    if (_profile != null) unawaited(_loadProfileRoomCards(_profile!));
    if (!_isOtherUser) {
      _profileSub = UserProfileService.instance
          .getCurrentUserProfileStream()
          .listen((profile) {
            if (!mounted || profile == null) return;
            setState(() {
              _profile = profile;
              _profileLoading = false;
            });
            unawaited(_loadProfileRoomCards(profile));
          });
    }
    _loadProfile();
    _loadConversationMessages();
    unawaited(_loadMuteState());
    if (_isOtherUser) {
      _publicProfileUpdatesSub = UserProfileService
          .instance
          .publicProfileUpdateStream
          .listen(_onPublicProfileUpdated);
    }
  }

  void _onPublicProfileUpdated(String userId) {
    if (!mounted) return;
    final profileUid =
        _validProfileUid(widget.uid) ??
        _validProfileUid(_identity?.matrixUserId) ??
        _validProfileUid(_savedContact?.wrytteUserId) ??
        _validProfileUid(_profile?.uid);
    if (profileUid == null ||
        _matrixLocalpart(profileUid).toLowerCase() !=
            _matrixLocalpart(userId).toLowerCase()) {
      return;
    }
    // The unblock path performs one atomic fetch, including channel/group
    // resolution.  Ignore intermediate notifications so a stale profile
    // cannot overwrite the complete refreshed result.
    if (_profileUnblockRefreshInFlight ||
        UserProfileService.instance.isPublicProfileRefreshing(profileUid)) {
      return;
    }
    unawaited(_loadProfile(forceRefresh: true));
  }

  @override
  void dispose() {
    BlockStateService.instance.revision.removeListener(_onBlockStateChanged);
    _profileSub?.cancel();
    _publicProfileUpdatesSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _onBlockStateChanged() {
    final uid = _profileTargetUserId;
    final redacted = _isBlockedByBbb(uid);
    if (redacted && mounted) {
      setState(() {
        _redactedByBlock = true;
      });
    }
    if (!redacted && _isOtherUser && uid != null) {
      if (_profileUnblockRefreshInFlight) return;
      // Keep all private/public profile surfaces redacted until the complete
      // profile refresh and featured-room resolution finish.
      if (mounted) {
        setState(() => _redactedByBlock = true);
      }
      _profileUnblockRefreshInFlight = true;
      unawaited(_refreshProfileAfterUnblock(uid));
    }
  }

  Future<void> _refreshProfileAfterUnblock(String uid) async {
    try {
      final refreshed = await UserProfileService.instance.getProfileByUid(
        uid,
        phone: _profilePhone(),
        forceRefresh: true,
      );
      if (!mounted || refreshed == null) return;

      // Resolve channel/group data before revealing any part of the profile.
      await _loadProfileRoomCards(refreshed);
      if (mounted) {
        setState(() {
          _profile = refreshed;
          _redactedByBlock = false;
          _profileLoading = false;
        });
      }
    } catch (error) {
      debugPrint('[ProfileScreen] unblock profile refresh failed: $error');
    } finally {
      _profileUnblockRefreshInFlight = false;
    }
  }

  Future<void> _loadProfile({bool forceRefresh = false}) async {
    var uid = _validProfileUid(widget.uid);
    debugPrint(
      '[ProfileScreen] load start: widgetUid="${widget.uid}" '
      'conversationId="${widget.conversationId}" '
      'initialName="${widget.initialProfileName}"',
    );
    uid ??= await _resolveProfileUidFromConversation();
    debugPrint('[ProfileScreen] resolved uid: "$uid"');
    if (uid != null && _isOtherUser) {
      final blockState = BlockStateService.instance;
      await blockState.load();
      _redactedByBlock = _isBlockedByBbb(uid);
    }
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    var identity =
        uid != null && ownerUserId != null && ownerUserId.isNotEmpty
            ? await ContactIdentityCache.instance.findByMatrixId(
              ownerUserId: ownerUserId,
              matrixUserId: uid,
            )
            : null;
    var savedContact = _isOtherUser ? await _findSavedContact(uid ?? '') : null;
    uid =
        uid ??
        _validProfileUid(savedContact?.wrytteUserId) ??
        _validProfileUid(identity?.matrixUserId);
    if (identity == null &&
        uid != null &&
        ownerUserId != null &&
        ownerUserId.isNotEmpty) {
      identity = await ContactIdentityCache.instance.findByMatrixId(
        ownerUserId: ownerUserId,
        matrixUserId: uid,
      );
    }
    savedContact ??= uid != null ? await _findSavedContact(uid) : null;
    if (mounted && (identity != null || savedContact != null)) {
      setState(() {
        _identity = identity;
        _savedContact = savedContact;
      });
    }
    final profileLookupPhone =
        _phoneFromIdentifier(savedContact?.primaryPhone).isNotEmpty
            ? _phoneFromIdentifier(savedContact?.primaryPhone)
            : identity?.phone ?? _phoneFromIdentifier(uid);
    final profile =
        uid != null
            ? await UserProfileService.instance.getProfileByUid(
              uid,
              phone: profileLookupPhone,
              forceRefresh: forceRefresh,
            )
            : _isOtherUser
            ? _profile
            : await UserProfileService.instance.getCurrentUserProfile(
              forceRefresh: forceRefresh,
            );
    debugPrint(
      '[ProfileScreen] lookup result: found=${profile != null} '
      'uid="${profile?.uid}" name="${profile?.displayName ?? profile?.name}" '
      'hasImage=${profile?.hasProfileImage}',
    );

    if (!mounted) return;
    setState(() {
      _profile = profile ?? _profile;
      _savedContact = savedContact;
      _identity = identity;
      _profileLoading = false;
    });
    if (profile != null) unawaited(_loadProfileRoomCards(profile));

    final matrixProfile =
        uid != null && profile?.moduleProfileLoaded != true
            ? await _loadMatrixProfile(uid)
            : null;

    if (uid != null && ownerUserId != null && ownerUserId.isNotEmpty) {
      if (savedContact == null) {
        await ContactIdentityCache.instance.clearSavedName(
          ownerUserId: ownerUserId,
          matrixUserId: uid,
        );
      } else if (profile != null) {
        final nextAvatar =
            profile.moduleProfileLoaded
                ? (profile.hasProfileImage ? profile.profileImage : null)
                : profile.hasProfileImage
                ? profile.profileImage
                : matrixProfile?.$2;
        if (nextAvatar?.trim().isNotEmpty == true) {
          unawaited(
            AvatarPreloadService.replace(
              oldUrl: identity?.avatarUrl,
              newUrl: nextAvatar,
            ),
          );
        }
        final refreshedContact =
            await ContactLocalDb.refreshPublicProfileFields(
              ownerUserId: ownerUserId,
              wrytteUserId: uid,
              phone:
                  profile.phone.isNotEmpty ? profile.phone : profileLookupPhone,
              avatarUrl:
                  profile.moduleProfileLoaded ? (nextAvatar ?? '') : nextAvatar,
              bio: profile.bio,
            );
        if (refreshedContact != null) {
          await ChatService().applySavedContact(refreshedContact);
        }
      }
      await ContactIdentityCache.instance.upsert(
        ownerUserId: ownerUserId,
        matrixUserId: uid,
        phone: profile?.phone ?? profileLookupPhone,
        profileName:
            _cleanName(profile?.displayName).isNotEmpty
                ? profile?.displayName
                : _cleanName(matrixProfile?.$1).isNotEmpty
                ? matrixProfile?.$1
                : identity?.profileName,
        savedName: savedContact?.formattedName,
        avatarUrl:
            profile?.moduleProfileLoaded == true
                ? (profile!.hasProfileImage ? profile.profileImage : '')
                : profile?.hasProfileImage == true
                ? profile!.profileImage
                : matrixProfile?.$2,
        bio:
            profile?.moduleProfileLoaded == true
                ? profile!.bio
                : profile?.bio.trim().isNotEmpty == true
                ? profile!.bio
                : identity?.bio,
        clearAvatar:
            profile?.moduleProfileLoaded == true &&
            profile?.hasProfileImage != true,
        clearBio: profile?.moduleProfileLoaded == true,
      );
      identity = await ContactIdentityCache.instance.findByMatrixId(
        ownerUserId: ownerUserId,
        matrixUserId: uid,
      );
    }

    if (!mounted) return;
    setState(() {
      _profile = profile ?? _profile;
      _savedContact = savedContact;
      _identity = identity;
      _profileLoading = false;
      final resolvedSaved = _cleanName(
        savedContact?.formattedName ?? identity?.savedName,
      );
      if (resolvedSaved.isNotEmpty) {
        _seededSavedName = resolvedSaved;
      } else if (savedContact == null && _seededSavedName != null) {
        _seededSavedName = null;
      }
    });
    debugPrint(
      '[ProfileActions] profile loaded: '
      'other=$_isOtherUser '
      'savedContact=${_savedContact != null} '
      'savedName="${_cleanName(_identity?.savedName)}" '
      'action=${_showUnsavedProfileActions ? 'Block/Add' : 'Edit'}',
    );
    final resolvedAvatar = _profileAvatarUrl();
    await AvatarPreloadService.warm(
      resolvedAvatar,
      cacheIdentity: 'user:${(uid ?? '').trim().toLowerCase()}',
    );
    apkLog(
      'Identity.display',
      'surface="profile" user_id="${_matrixLocalpart(uid ?? '')}" '
          'saved=${savedContact != null} '
          'profile="${savedContact != null ? 'profile2' : 'profile1'}" '
          'name_source="${savedContact != null ? 'saved_contact' : 'public_profile'}" '
          'name="${_profileDisplayName()}" phone="${_profilePhone()}" '
          'avatar=${(resolvedAvatar ?? '').trim().isNotEmpty} '
          'avatar_url="${resolvedAvatar ?? ''}" bio=${_profileBio().isNotEmpty}',
    );
  }

  Future<String?> _resolveProfileUidFromConversation() async {
    final conversationId = widget.conversationId?.trim() ?? '';
    if (conversationId.isEmpty) return null;

    final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
    final currentLocalpart = _matrixLocalpart(currentUserId);

    String? peerFrom(String? raw) {
      final value = _validProfileUid(raw);
      if (value == null) return null;
      if (currentLocalpart.isNotEmpty &&
          _matrixLocalpart(value) == currentLocalpart) {
        return null;
      }
      return value;
    }

    final room = MatrixChatService.instance.getRoomById(conversationId);
    final directPeer = peerFrom(room?.directChatMatrixID);
    if (directPeer != null) return directPeer;

    if (room != null) {
      for (final member in room.getParticipants([
        mx.Membership.join,
        mx.Membership.invite,
      ])) {
        final peer = peerFrom(member.id);
        if (peer != null) return peer;
      }
    }

    for (final message
        in ChatService().cachedMessagesFor(conversationId).reversed) {
      final sender = peerFrom(message.senderId);
      if (sender != null) return sender;
      final receiver = peerFrom(message.receiverId);
      if (receiver != null) return receiver;
    }

    final localMessages = await ChatLocalDb.instance.loadMessages(
      conversationId,
    );
    for (final message in localMessages.reversed) {
      if (message.isDeleted) continue;
      final sender = peerFrom(message.senderId);
      if (sender != null) return sender;
      final receiver = peerFrom(message.receiverId);
      if (receiver != null) return receiver;
    }

    return null;
  }

  Future<void> _loadConversationMessages() async {
    final conversationId = widget.conversationId?.trim() ?? '';
    if (conversationId.isEmpty) return;
    final profileUid = _validProfileUid(widget.uid);
    if (profileUid != null &&
        !ChatService().isVerifiedDirectConversation(
          conversationId,
          profileUid,
        )) {
      if (mounted) setState(() => _conversationMessages = const []);
      return;
    }
    final cached = ChatService().cachedMessagesFor(conversationId);
    if (mounted && cached.isNotEmpty) {
      setState(() => _conversationMessages = cached);
    }
    final local = await ChatLocalDb.instance.loadMessages(conversationId);
    if (!mounted) return;
    setState(() {
      _conversationMessages =
          local.where((message) => !message.isDeleted).toList()
            ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    });
  }

  void _seedProfileForFirstPaint() {
    if (_isOtherUser) {
      final uid = _validProfileUid(widget.uid) ?? '';
      final cached = UserProfileService.instance.cachedPublicProfileByUid(uid);
      if (cached != null && _hasRenderableProfile(cached)) {
        _profile = cached;
        return;
      }
      return;
    }

    final cached = UserProfileService.instance.cachedProfile;
    if (cached == null || !_hasRenderableProfile(cached)) return;
    _profile = cached;
    _profileLoading = false;
  }

  bool _hasRenderableProfile(UserProfile profile) {
    return _cleanName(profile.displayName).isNotEmpty ||
        profile.phone.trim().isNotEmpty ||
        profile.hasProfileImage ||
        profile.localProfileImagePath.trim().isNotEmpty ||
        profile.bio.trim().isNotEmpty ||
        profile.links.any((link) => link.trim().isNotEmpty) ||
        profile.channelAlias.trim().isNotEmpty ||
        profile.groupAlias.trim().isNotEmpty;
  }

  String _visibilityKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  bool _canViewProfileField(UserProfile? profile, String field) {
    if (!_isOtherUser) return true;
    final settings = profile?.visibilitySettings ?? const <String, String>{};
    final expectedKeys = <String>{
      _visibilityKey(field),
      _visibilityKey('com.wrytte.$field'),
      _visibilityKey('${field}Alias'),
      _visibilityKey('com.wrytte.${field.toLowerCase()}_alias'),
    };
    String? configured;
    for (final entry in settings.entries) {
      if (expectedKeys.contains(_visibilityKey(entry.key))) {
        configured = entry.value;
        break;
      }
    }
    final visibility = (configured ?? 'everyone').trim().toLowerCase();
    if (visibility == 'nobody' ||
        visibility == 'none' ||
        visibility == 'private') {
      return false;
    }
    if (visibility == 'contacts' || visibility == 'contacts_only') {
      return _savedContact != null;
    }
    return visibility == 'everyone' ||
        visibility == 'public' ||
        visibility.isEmpty;
  }

  MatrixPublicGroup? _profileRoomFromJoinedRooms(
    String reference, {
    required bool isChannel,
  }) {
    final normalized = reference.trim();
    if (normalized.isEmpty) return null;
    final matrix = MatrixChatService.instance;
    for (final room in matrix.rooms) {
      if (room.id != normalized && room.canonicalAlias.trim() != normalized) {
        continue;
      }
      final roomIsChannel = matrix.isChannelRoom(room);
      final roomIsGroup = matrix.isMatrixGroupRoom(room) && !roomIsChannel;
      if ((isChannel && !roomIsChannel) || (!isChannel && !roomIsGroup)) {
        continue;
      }
      return MatrixPublicGroup(
        roomId: room.id,
        name: room.getLocalizedDisplayname(),
        avatarUrl: room.avatar?.toString(),
        canonicalAlias:
            room.canonicalAlias.trim().isEmpty ? null : room.canonicalAlias,
        topic: room.topic,
        memberCount: matrix.groupMemberCount(room),
        worldReadable:
            room.historyVisibility == mx.HistoryVisibility.worldReadable,
        roomType: isChannel ? MatrixPublicGroup.channelRoomType : 'group',
      );
    }
    return null;
  }

  Future<MatrixPublicGroup?> _resolveProfileRoom(
    String reference, {
    required bool isChannel,
  }) async {
    final local = _profileRoomFromJoinedRooms(reference, isChannel: isChannel);
    if (local != null) {
      try {
        final client = await MatrixChatService.instance.connect();
        final summary = await client.getRoomSummary(local.roomId);
        var count = summary.numJoinedMembers;
        final room = MatrixChatService.instance.getRoomById(local.roomId);
        if (room != null && room.membership == mx.Membership.join) {
          final joinedMembers = await room.requestParticipants(
            const [mx.Membership.join],
            true,
            true,
          );
          count = joinedMembers.map((member) => member.id).toSet().length;
        }
        final refreshed = MatrixPublicGroup(
          roomId: local.roomId,
          name:
              summary.name?.trim().isNotEmpty == true
                  ? summary.name!.trim()
                  : local.name,
          avatarUrl: summary.avatarUrl?.toString() ?? local.avatarUrl,
          canonicalAlias: summary.canonicalAlias ?? local.canonicalAlias,
          topic: summary.topic ?? local.topic,
          memberCount: count,
          worldReadable: summary.worldReadable,
          roomType: summary.roomType ?? local.roomType,
        );
        unawaited(
          ChatService()
              .cacheSuggestedRoomProfile(refreshed.roomId, {
                'name': refreshed.name,
                'avatarUrl': refreshed.avatarUrl,
                'canonicalAlias': refreshed.canonicalAlias,
                'description': refreshed.topic,
                'memberCount': refreshed.memberCount,
              })
              .catchError((_) {}),
        );
        return refreshed;
      } catch (error) {
        apkLog(
          'Profile.room',
          'summary refresh failed room_id="${local.roomId}" error="$error"',
        );
        return local;
      }
    }
    try {
      final client = await MatrixChatService.instance.connect();
      final summary = await client.getRoomSummary(reference);
      final canonicalAlias = summary.canonicalAlias?.trim() ?? '';
      final aliasLocalpart =
          canonicalAlias.startsWith('#')
              ? canonicalAlias.substring(1)
              : canonicalAlias;
      final summaryIsChannel =
          summary.roomType?.trim().toLowerCase() ==
              MatrixPublicGroup.channelRoomType ||
          (aliasLocalpart.startsWith('@') &&
              !aliasLocalpart.startsWith('gr.@'));
      if ((isChannel && !summaryIsChannel) ||
          (!isChannel && summaryIsChannel)) {
        return null;
      }
      final summaryName = summary.name?.trim() ?? '';
      final summaryAvatar = summary.avatarUrl?.toString();
      final summaryTopic = summary.topic;
      unawaited(
        ChatService()
            .cacheSuggestedRoomProfile(summary.roomId, {
              'name': summaryName,
              'avatarUrl': summaryAvatar,
              'canonicalAlias': summary.canonicalAlias,
              'description': summaryTopic,
              'memberCount': summary.numJoinedMembers,
            })
            .catchError((_) {}),
      );
      return MatrixPublicGroup(
        roomId: summary.roomId,
        name: summaryName.isNotEmpty ? summaryName : reference.trim(),
        avatarUrl: summaryAvatar,
        canonicalAlias: summary.canonicalAlias,
        topic: summaryTopic,
        memberCount: summary.numJoinedMembers,
        worldReadable: summary.worldReadable,
        roomType: summary.roomType,
      );
    } catch (error) {
      apkLog(
        'Profile.room',
        'summary lookup failed ref="${reference.trim()}" error="$error"',
      );
      try {
        final chat = ChatService();
        final cached = await chat.loadSuggestedRoomProfile(reference.trim());
        if (cached == null) return null;
        final cachedMembers = await chat.loadSuggestedPreviewMembers(
          reference.trim(),
        );
        final joinedCount =
            cachedMembers
                .where((member) => member['membership']?.toString() == 'join')
                .length;
        return MatrixPublicGroup(
          roomId: reference.trim(),
          name:
              cached['name']?.toString().trim().isNotEmpty == true
                  ? cached['name'].toString().trim()
                  : reference.trim(),
          avatarUrl: cached['avatarUrl']?.toString(),
          canonicalAlias: cached['canonicalAlias']?.toString(),
          topic: cached['description']?.toString(),
          memberCount: joinedCount,
          worldReadable: true,
          roomType: isChannel ? MatrixPublicGroup.channelRoomType : 'group',
        );
      } catch (cacheError) {
        apkLog(
          'Profile.room',
          'cached room lookup failed ref="${reference.trim()}" error="$cacheError"',
        );
        return null;
      }
    }
  }

  Future<void> _loadProfileRoomCards(UserProfile profile) async {
    final revision = ++_profileRoomResolveRevision;
    int? channelMemberCount;
    int? groupMemberCount;
    final profileUserId = _profileTargetUserId ?? profile.uid;
    try {
      final moduleProfile = await MatrixProfileService.instance.getProfile(
        profileUserId,
      );
      channelMemberCount = int.tryParse(
        moduleProfile[WrytteProfile.channelMemberCount] ?? '',
      );
      groupMemberCount = int.tryParse(
        moduleProfile[WrytteProfile.groupMemberCount] ?? '',
      );
      apkLog(
        'Profile.room',
        'Module API room counts user_id="$profileUserId" '
            'channel=$channelMemberCount group=$groupMemberCount',
      );
    } catch (error) {
      apkLog(
        'Profile.room',
        'Module API room-count lookup failed user_id="$profileUserId" '
            'error="$error"',
      );
    }
    final channelRef =
        _canViewProfileField(profile, 'Channel')
            ? profile.channelAlias.trim()
            : '';
    final groupRef =
        _canViewProfileField(profile, 'Group') ? profile.groupAlias.trim() : '';
    final resolvedRooms = await Future.wait<MatrixPublicGroup?>([
      channelRef.isEmpty
          ? Future<MatrixPublicGroup?>.value(null)
          : _resolveProfileRoom(channelRef, isChannel: true),
      groupRef.isEmpty
          ? Future<MatrixPublicGroup?>.value(null)
          : _resolveProfileRoom(groupRef, isChannel: false),
    ]);
    MatrixPublicGroup? withModuleCount(MatrixPublicGroup? room, int? count) {
      if (room == null || count == null || count < 0) return room;
      return MatrixPublicGroup(
        roomId: room.roomId,
        name: room.name,
        avatarUrl: room.avatarUrl,
        canonicalAlias: room.canonicalAlias,
        topic: room.topic,
        memberCount: count,
        worldReadable: room.worldReadable,
        avatarVersion: room.avatarVersion,
        nameVersion: room.nameVersion,
        descriptionVersion: room.descriptionVersion,
        linkVersion: room.linkVersion,
        aliasVersion: room.aliasVersion,
        link: room.link,
        roomType: room.roomType,
      );
    }

    final results = [
      withModuleCount(resolvedRooms[0], channelMemberCount),
      withModuleCount(resolvedRooms[1], groupMemberCount),
    ];
    if (!mounted || revision != _profileRoomResolveRevision) return;
    setState(() {
      _profileChannel = results[0];
      _profileGroup = results[1];
    });
  }

  Future<void> _openProfileRoom(
    String reference, {
    required bool isChannel,
  }) async {
    final group = await _resolveProfileRoom(reference, isChannel: isChannel);
    if (!mounted) return;
    if (group == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'This ${isChannel ? 'channel' : 'group'} is unavailable.',
          ),
        ),
      );
      return;
    }
    var alreadyJoined = false;
    var previewMessages = const <ChatMessage>[];
    var hasMoreRoomEvents = false;
    try {
      final chatService = ChatService();
      await chatService.connect();
      final room = MatrixChatService.instance.getRoomById(group.roomId);
      alreadyJoined = room?.membership == mx.Membership.join;
      final page = await chatService.fetchProfileRoomEventPage(
        roomId: group.roomId,
        limit: 15,
        initial: true,
      );
      previewMessages = page.messages;
      hasMoreRoomEvents = page.hasMore;
    } catch (error) {
      apkLog(
        'Profile.room',
        'preview lookup failed room_id="${group.roomId}" error="$error"',
      );
    }
    final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
    if (!mounted) return;
    if (isChannel) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => ChannelFeedScreen(
                conversationId: group.roomId,
                currentUserId: currentUserId,
                title: group.name,
                avatarUrl: group.avatarUrl,
                initialPosts: previewMessages,
                subscriberCountIsAuthoritative: true,
                loadRoomEventsOnDemand: true,
                initialEventsHaveMore: hasMoreRoomEvents,
                subscriberCount: group.memberCount,
                readOnlyUntilSubscribe: !alreadyJoined,
                subscribeAlias: group.roomId,
              ),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => ChatScreen(
                conversationId: group.roomId,
                receiverId: group.roomId,
                currentUserId: currentUserId,
                title: group.name,
                avatarUrl: group.avatarUrl,
                initialMessages: previewMessages,
                loadRoomEventsOnDemand: true,
                initialEventsHaveMore: hasMoreRoomEvents,
                readOnlyUntilJoin: !alreadyJoined,
                initialMemberCount: group.memberCount,
                initialMemberCountIsAuthoritative: true,
                groupAlias: group.roomId,
                groupDescription: group.topic,
                conversationKind: ConversationKind.group,
                initialRoomProfileVersion: group.profileVersionFingerprint,
              ),
        ),
      );
    }
  }

  Future<Contact?> _findSavedContact(String uid, {String? phone}) async {
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    if (ownerUserId == null || ownerUserId.isEmpty) return null;

    final targetLocalpart = _matrixLocalpart(uid);
    String normalizedPhone(String? value) {
      final parsed = _phoneFromIdentifier(value);
      if (parsed.isEmpty) return '';
      return _formatPhone(parsed).replaceAll(RegExp(r'[^\d]'), '');
    }

    final targetPhone = normalizedPhone(phone);
    final contacts = await ContactService().getMatrixContactsCached(
      ownerUserId,
    );
    for (final contact in contacts) {
      final contactId = contact.wrytteUserId;
      final sameWrytteId =
          contactId != null &&
          contactId.isNotEmpty &&
          _matrixLocalpart(contactId) == targetLocalpart;
      final samePhone =
          targetPhone.isNotEmpty &&
          contact.phones.map(normalizedPhone).contains(targetPhone);
      if (sameWrytteId || samePhone) return contact;
    }
    return null;
  }

  Future<(String?, String?)?> _loadMatrixProfile(String uid) async {
    try {
      final profile = await UserProfileService.instance.getProfileByUid(
        uid,
        forceRefresh: false,
      );
      if (profile?.moduleProfileLoaded == true) {
        return (
          profile!.displayName.isEmpty ? null : profile.displayName,
          profile.hasProfileImage ? profile.profileImage : null,
        );
      }
      final matrixProfile = await MatrixProfileService.instance.getProfile(uid);
      return (
        matrixProfile.displayName ??
            [matrixProfile.firstNameValue, matrixProfile.lastNameValue]
                .whereType<String>()
                .where((part) => part.trim().isNotEmpty)
                .join(' '),
        matrixProfile.avatarUrl ?? matrixProfile[WrytteProfile.avatarImageUrl],
      );
    } catch (_) {
      return null;
    }
  }

  String? _validProfileUid(String? uid) {
    final trimmed = uid?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('!')) return null;
    if (trimmed.startsWith('@!')) return null;
    return trimmed;
  }

  String _toMatrixUserId(String uid) {
    final trimmed = uid.trim();
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

  bool _looksLikePhone(String value) {
    final stripped = value.trim().replaceAll(RegExp(r'[\s\-()+]'), '');
    if (stripped.length < 7 || stripped.length > 15) return false;
    return stripped.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(stripped);
  }

  String _extractPhone(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return '';
    final match = RegExp(r'(\+?\d[\d\s\-()]{6,}\d)').firstMatch(raw);
    if (match == null) return '';
    final phone = match.group(1)?.trim() ?? '';
    return _looksLikePhone(phone) ? phone : '';
  }

  String _phoneFromIdentifier(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty || _looksLikeMatrixId(raw)) return '';

    final extracted = _extractPhone(value);
    if (extracted.isNotEmpty) return extracted;

    final localpart = _matrixLocalpart(raw);
    if (_looksLikeMatrixId(localpart)) return '';
    final digits = localpart.replaceAll(RegExp(r'[^\d]'), '');
    return RegExp(r'^\+?\d{7,15}$').hasMatch(localpart) ? digits : '';
  }

  bool _looksLikeMatrixId(String value) {
    final trimmed = value.trim();
    final localpart = _matrixLocalpart(trimmed);
    final looksLikeGeneratedUid = RegExp(
      r'^[a-f0-9]{24,}$',
      caseSensitive: false,
    ).hasMatch(localpart);
    return trimmed.startsWith('@') ||
        trimmed.contains(':matrix.') ||
        looksLikeGeneratedUid;
  }

  String _cleanName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return '';
    }
    if (_looksLikePhone(trimmed) || _looksLikeMatrixId(trimmed)) return '';
    return trimmed;
  }

  String _profileDisplayName() {
    if (_isOtherUser) {
      if (_seededSavedName != null && _seededSavedName!.isNotEmpty) {
        return WrytteId.forDisplay(_seededSavedName!) ?? _seededSavedName!;
      }
      final savedName = _cleanName(_savedContact?.formattedName);
      if (savedName.isNotEmpty) {
        return WrytteId.forDisplay(savedName) ?? savedName;
      }
      final savedIdentityName = _cleanName(_identity?.savedName);
      if (savedIdentityName.isNotEmpty) {
        return WrytteId.forDisplay(savedIdentityName) ?? savedIdentityName;
      }
    }
    final profileName = _cleanName(_profile?.displayName);
    if (profileName.isNotEmpty) {
      return WrytteId.forDisplay(profileName) ?? profileName;
    }
    final initialName = _cleanName(widget.initialProfileName);
    if (initialName.isNotEmpty) {
      return WrytteId.forDisplay(initialName) ?? initialName;
    }
    return _profileWrytteId() ?? '';
  }

  String? _profileAvatarUrl() {
    if (_redactedByBlock) return null;
    final profile = _profile;
    if (profile?.hasProfileImage == true) return profile!.profileImage;
    if (profile?.moduleProfileLoaded == true) return null;
    final initial = widget.initialAvatarUrl?.trim() ?? '';
    return initial.isEmpty ? null : initial;
  }

  String _profilePhone() {
    final linkedWrytteId = _profileWrytteId();
    if (linkedWrytteId != null) return linkedWrytteId;

    final raw = _profile?.phone.trim() ?? '';
    final wrytteId = _displayWrytteId(raw);
    if (wrytteId != null) return wrytteId;
    final phone = _phoneFromIdentifier(_profile?.phone);
    if (phone.isNotEmpty) {
      return _formatPhone(phone);
    }
    return '';
  }

  String? _displayWrytteId(String value) {
    return WrytteId.forDisplay(value);
  }

  String? _profileWrytteId() {
    for (final candidate in [
      _profile?.uid,
      _profile?.phone,
      widget.uid,
      _identity?.matrixUserId,
      _savedContact?.wrytteUserId,
    ]) {
      final displayId = WrytteId.forDisplay(candidate ?? '');
      if (displayId != null) return displayId;
    }
    return null;
  }

  String _formatPhone(String phone) {
    return CountryPhoneNumber.formatInternationalDisplay(phone);
  }

  Future<void> _launchLink(String url) async {
    final raw = url.trim();
    if (raw.isEmpty) return;
    final uri = Uri.tryParse(
      raw.startsWith('http://') || raw.startsWith('https://')
          ? raw
          : 'https://$raw',
    );
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open $raw'),
          backgroundColor: const Color(0xFF23262C),
        ),
      );
      return;
    }
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open $raw'),
          backgroundColor: const Color(0xFF23262C),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open $raw'),
          backgroundColor: const Color(0xFF23262C),
        ),
      );
    }
  }

  Future<void> _openAddContact() async {
    debugPrint('[ProfileScreen] Add to contact tapped');
    final uid = _profileTargetUserId;
    final phone = _profilePhone();
    debugPrint(
      '[ProfileScreen] Add contact data: '
      'widgetUid="${widget.uid}" '
      'profileUid="$uid" '
      'phone="$phone" '
      'identityUid="${_identity?.matrixUserId}"',
    );
    if (uid == null && phone.isEmpty) {
      debugPrint(
        '[ProfileScreen] Add contact stopped: no profile identifier found',
      );
      return;
    }
    debugPrint('[ProfileScreen] Opening add-contact bottom sheet');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.60),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) => AnimatedPadding(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: FractionallySizedBox(
          heightFactor: MediaQuery.viewInsetsOf(sheetContext).bottom > 0
              ? 0.70
              : 0.82,
          child: _ProfileAddContactSheet(
            initialName: _profileDisplayName(),
            phone: phone.isNotEmpty ? phone : (uid ?? ''),
          ),
        ),
      ),
    );
    debugPrint('[ProfileScreen] Add-contact bottom sheet closed');
    if (mounted) _loadProfile();
  }

  Future<void> _openProfileEditSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.60),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) => AnimatedPadding(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: FractionallySizedBox(
          heightFactor: MediaQuery.viewInsetsOf(sheetContext).bottom > 0
              ? 0.70
              : 0.82,
          child: _ProfileAddContactSheet(
            initialName: _profileDisplayName(),
            phone: _profilePhone(),
            showDeleteContact: _isOtherUser && _savedContact != null,
            onDeleteContact: _confirmDeleteSavedContact,
          ),
        ),
      ),
    );
    if (mounted) unawaited(_loadProfile());
  }

  Future<void> _confirmDeleteSavedContact() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) {
        final screenW = MediaQuery.of(dialogContext).size.width;
        final dialogW = screenW * 0.78;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: (screenW - dialogW) / 2,
          ),
          child: Container(
            width: dialogW,
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 22),
            decoration: BoxDecoration(
              color: const Color(0xFF171A20),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xFF3A3D44), width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Are you sure you want to delete the contact?',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 24),
                _profileConfirmButton(
                  dialogContext,
                  'Delete',
                  const Color(0xFFFF5C52),
                  true,
                ),
                const SizedBox(height: 12),
                _profileConfirmButton(
                  dialogContext,
                  'Cancel',
                  Colors.white,
                  false,
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed == true) await _deleteSavedContact();
  }

  Widget _profileConfirmButton(
    BuildContext dialogContext,
    String label,
    Color color,
    bool confirmed,
  ) {
    return GestureDetector(
      onTap: () => Navigator.pop(dialogContext, confirmed),
      child: Container(
        width: double.infinity,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF23262C),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 17)),
      ),
    );
  }

  Future<void> _deleteSavedContact() async {
    final contact = _savedContact;
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    final uid = _profileTargetUserId;
    if (contact == null || ownerUserId == null || ownerUserId.isEmpty || uid == null) {
      return;
    }

    await ContactLocalDb.removeContact(contact, ownerUserId: ownerUserId);
    unawaited(
      ContactService()
          .removeContactFromBackend(ownerUserId: ownerUserId, contact: contact)
          .catchError(
            (e) => debugPrint('[ProfileScreen] backend contact remove failed: $e'),
          ),
    );
    await ContactIdentityCache.instance.clearSavedName(
      ownerUserId: ownerUserId,
      matrixUserId: uid,
    );
    await ChatService().applyUnsavedContact(contact);
    ContactService.invalidateMatrixContactsCache();
    ContactService().invalidateCache();

    if (!mounted) return;
    setState(() => _savedContact = null);
    Navigator.of(context).pop();
  }

  static const TextStyle _bioStyle = TextStyle(
    color: Color(0xFFC6C6C6),
    fontSize: 14,
  );

  bool get _hasCard {
    if (_redactedByBlock) return false;
    final bio = _profileBio();
    final links = _profile?.links ?? [];
    return bio.isNotEmpty ||
        links.isNotEmpty ||
        (_canViewProfileField(_profile, 'Channel') &&
            (_profile?.channelAlias.trim().isNotEmpty ?? false)) ||
        (_canViewProfileField(_profile, 'Group') &&
            (_profile?.groupAlias.trim().isNotEmpty ?? false));
  }

  String _profileBio() {
    if (_redactedByBlock) return '';
    return _profile?.bio.trim() ?? '';
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
      '[ProfileActions] build: loading=$_profileLoading '
      'other=$_isOtherUser saved=${_savedContact != null} '
      'rendered=${_profileLoading &&
              !_hasSavedContactHint &&
              widget.contactStatus != ProfileContactStatus.unsaved
          ? 'none'
          : (_showUnsavedProfileActions ? 'Block/Add' : 'Edit')}',
    );
    final theme = Theme.of(context);
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double topBarHeight = statusBarHeight + kToolbarHeight;

    final hasProfile = _profile != null;
    final hasInitialProfileName =
        _cleanName(widget.initialProfileName).isNotEmpty;
    final hasInitialAvatar =
        (widget.initialAvatarUrl?.trim().isNotEmpty ?? false);
    final String displayName =
        _profileLoading && !hasProfile && !hasInitialProfileName
            ? ''
            : _profileDisplayName();
    final String phone = _profileLoading && !hasProfile ? '' : _profilePhone();
    final String bioText = _profileBio();
    final List<String> links = _redactedByBlock ? const [] : (_profile?.links ?? []);
    final channelRef =
        !_redactedByBlock && _canViewProfileField(_profile, 'Channel')
            ? _profile?.channelAlias.trim() ?? ''
            : '';
    final groupRef =
        !_redactedByBlock && _canViewProfileField(_profile, 'Group')
            ? _profile?.groupAlias.trim() ?? ''
            : '';

    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'Inter'),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'Inter'),
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF08090B),
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            NestedScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              headerSliverBuilder:
                  (context, innerBoxIsScrolled) => [
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          // Reduced top spacing so avatar/name/phone sit higher
                          SizedBox(height: topBarHeight - 18),

                          // ── Avatar ──────────────────────────────────────────
                          SizedBox(
                            width: 100,
                            height: 100,
                            child:
                                _profileLoading &&
                                        !hasProfile &&
                                        !hasInitialAvatar
                                    ? _buildAvatarShimmer(100)
                                    : UserAvatar(
                                      size: 100,
                                      imageUrl: _profileAvatarUrl(),
                                      localImagePath:
                                          _redactedByBlock
                                              ? null
                                              : _profile?.localProfileImagePath,
                                      cacheIdentity:
                                          'user:${(widget.uid ?? _profile?.uid ?? '').trim().toLowerCase()}',
                                      name: displayName,
                                    ),
                          ),

                          const SizedBox(height: 12),

                          // ── Name ────────────────────────────────────────────
                          if (!_isOtherUser || displayName.isNotEmpty)
                            Text(
                              _isOtherUser
                                  ? displayName
                                  : displayName.isNotEmpty
                                  ? displayName
                                  : 'You',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),

                          const SizedBox(height: 4),

                          // ── Phone ───────────────────────────────────────────
                          if (phone.isNotEmpty)
                            Text(
                              phone,
                              style: const TextStyle(
                                color: Color(0xFF4DA3FF),
                                fontSize: 16,
                              ),
                            ),

                          const SizedBox(height: 16),

                          // ── Quick actions (other user only) ─────────────────
                          if (_isOtherUser) ...[
                            _buildQuickActions(),
                            const SizedBox(height: 20),
                          ],

                          // ── Bio, links, and featured rooms ────────────────
                          if (!_profileLoading &&
                              (bioText.isNotEmpty ||
                                  links.isNotEmpty ||
                                  channelRef.isNotEmpty ||
                                  groupRef.isNotEmpty)) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(60),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(vertical: 29),
                                    decoration: BoxDecoration(
                                  color: const Color(0xFF08090B),
                                  border: Border.all(
                                    color: const Color(0xFF23262C),
                                    width: 1,
                                  ),
                                  borderRadius: BorderRadius.circular(60),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.25),
                                      blurRadius: 30,
                                      offset: const Offset(0, 10),
                                    ),
                                  ],
                                ),


                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (bioText.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                        ),
                                        child: _buildBio(bioText),
                                      ),
                                    // NO divider between bio and links
                                    if (links.isNotEmpty)
                                      Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 20,
                                        ).copyWith(
                                          top: bioText.isNotEmpty ? 4 : 0,
                                        ),
                                        child: _buildLinks(links),
                                      ),
                                    if (links.isNotEmpty &&
                                        (channelRef.isNotEmpty ||
                                            groupRef.isNotEmpty))
                                      _profileSectionDivider(
                                        const Color(0xFF23262C),
                                        height: 24,
                                      ),
                                    if (channelRef.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                        ),
                                        child: _buildFeaturedRoomRow(
                                          label: 'Channel',
                                          reference: channelRef,
                                          room: _profileChannel,
                                          isChannel: true,
                                        ),
                                      ),
                                    if (channelRef.isNotEmpty &&
                                        groupRef.isNotEmpty)
                                      _profileSectionDivider(
                                        const Color(0xFF23262C),
                                        height: 1,
                                      ),
                                    if (groupRef.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                        ),
                                        child: _buildFeaturedRoomRow(
                                          label: 'Group',
                                          reference: groupRef,
                                          room: _profileGroup,
                                          isChannel: false,
                                        ),
                                      ),
                                  ],
                                ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                          ],

                          if (_profileLoading || !_hasCard)
                            const SizedBox(height: 4),
                        ],
                      ),
                    ),

                    // ── Sticky tab bar ───────────────────────────────────────
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _StickyTabBarDelegate(
                        topOffset: topBarHeight,
                        child: Container(
                          color: const Color(0xFF08090B),
                          child: ProfileTabBarSection(
                            controller: _tabController,
                            tabs: _tabs,
                          ),
                        ),
                      ),
                    ),
                  ],
              body: TabBarView(
                controller: _tabController,
                physics: const BouncingScrollPhysics(),
                children:
                    _isOtherUser
                        ? [
                          _buildMediaTab(),
                          _buildFilesTab(),
                          _buildEmptyTab(
                            Icons.dynamic_feed_outlined,
                            'No feed',
                          ),
                          _buildLinksTab(),
                        ]
                        : [_buildPostsTab(), _buildSavedTab()],
              ),
            ),

            // ── Top gradient scrim ────────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topBarHeight + 20,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.6, 1.0],
                      colors: [
                        const Color(0xFF08090B).withValues(alpha: 0.95),
                        const Color(0xFF08090B).withValues(alpha: 0.75),
                        const Color(0xFF08090B).withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            if (_showBlockUserCard)
              Positioned(
                top: topBarHeight + 5,
                right: 50,
                child: _buildBlockUserCard(),
              ),

            if (_showMoreOptions)
              CompositedTransformFollower(
                link: _moreOptionsLayerLink,
                showWhenUnlinked: false,
                offset: const Offset(-140, 66),
                child: _showMuteOptions
                    ? _buildMuteOptionsCard()
                    : _showClearChatConfirmation
                    ? _buildClearChatConfirmationCard()
                    : _buildMoreOptionsCard(),
              ),

            // ── Top bar ───────────────────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: EdgeInsets.only(top: statusBarHeight),
                child: SizedBox(
                  height: kToolbarHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        widget.embeddedInHome && !_isOtherUser
                            ? _buildTopAddButton()
                            : widget.embeddedInHome
                                ? const SizedBox(width: 36)
                                : _glassButton(
                                    icon: Icons.arrow_back_ios_new,
                                    onTap: () => Navigator.pop(context),
                                  ),

                        Expanded(
                          child: const SizedBox.shrink(),
                        ),

                        _isOtherUser &&
                                _profileLoading &&
                                widget.contactStatus == null &&
                                !_hasSavedContactHint
                            ? const SizedBox(width: 84, height: 44)
                            : _isOtherUser
                            ? _showUnsavedProfileActions
                                ? _buildUnsavedProfileActions()
                                : _glassTextButton(
                                    text: 'Edit',
                                    onTap: _openProfileEditSheet,
                                  )
                            : _glassTextButton(
                              text: "Edit",
                              onTap: () async {
                                final message = await Navigator.push<String>(
                                  context,
                                  MaterialPageRoute(
                                    builder:
                                        (_) => EditProfileScreen(
                                          initialProfile: _profile,
                                        ),
                                  ),
                                );
                                if (!context.mounted) return;
                                unawaited(_loadProfile());
                                if (message?.trim().isNotEmpty == true) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(message!),
                                      backgroundColor: const Color(0xFF4DA3FF),
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 12,
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Quick actions ──────────────────────────────────────────────────────────

  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
          Expanded(
            child: _actionPill(
              null,
              'Call',
              iconAsset: 'assets/images/Phone new.svg',
              iconSize: 24,
              onTap: () {},
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _actionPill(
              null,
              'Video',
              iconAsset: 'assets/images/Video call new.svg',
              iconSize: 28,
              onTap: () {},
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _actionPill(
              null,
              'Search',
              iconAsset: 'assets/images/Search icon new.svg',
              iconSize: 24,
              onTap: () {},
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: CompositedTransformTarget(
              link: _moreOptionsLayerLink,
              child: _actionPill(
                Icons.more_horiz,
                'More',
                iconSize: 24,
                onTap: () => setState(() => _showMoreOptions = !_showMoreOptions),
              ),
            ),
          ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMoreOptionsCard() {
    final options = <String>[
      _roomMuted ? 'Unmute' : 'Mute',
      'Share contact',
      'Auto delete',
      'Clear chat',
      if (widget.contactStatus == ProfileContactStatus.saved ||
          _savedContact != null)
        'Block user',
    ];
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(38),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF23262C).withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(38),
          border: Border.all(color: const Color(0xFF292C32)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              InkWell(
                onTap: option == 'Mute'
                    ? () => setState(() => _showMuteOptions = true)
                    : option == 'Unmute'
                    ? _unmuteRoom
                    : option == 'Clear chat'
                    ? () => setState(() => _showClearChatConfirmation = true)
                    : () {},
                child: SizedBox(
                  height: 52,
                  width: double.infinity,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Row(
                        children: [
                          if (_moreOptionIconPath(option) != null) ...[
                            SvgPicture.asset(
                              _moreOptionIconPath(option)!,
                              width: 20,
                              height: 20,
                              colorFilter: const ColorFilter.mode(
                                Colors.white,
                                BlendMode.srcIn,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            option,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildMuteOptionsCard() {
    const options = ['8 hours', '1 day', '7 days', 'Always'];
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(38),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF23262C).withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(38),
          border: Border.all(color: const Color(0xFF292C32)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _showMuteOptions = false),
              child: SizedBox(
                height: 52,
                child: Row(
                  children: [
                    const SizedBox(width: 28),
                    SvgPicture.asset(
                      'assets/svg/ic--round-arrow-back-ios.svg',
                      width: 24,
                      height: 24,
                      colorFilter: const ColorFilter.mode(
                        Colors.white,
                        BlendMode.srcIn,
                      ),
                    ),
                    const SizedBox(width: 26),
                    const Text(
                      'Back',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
            for (final option in options)
              InkWell(
                onTap: () => _applyMuteOption(option),
                child: SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      const SizedBox(width: 28),
                      SvgPicture.asset(
                        'assets/images/Bell new icon slash .svg',
                        width: 20,
                        height: 20,
                        colorFilter: ColorFilter.mode(
                          option == 'Always' ? const Color(0xFFFF5C52) : Colors.white,
                          BlendMode.srcIn,
                        ),
                      ),
                      const SizedBox(width: 26),
                      Text(
                        option,
                        style: TextStyle(
                          color: option == 'Always'
                              ? const Color(0xFFFF5C52)
                              : Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildClearChatConfirmationCard() {
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(38),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            width: 200,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withValues(alpha: 0.30),
              borderRadius: BorderRadius.circular(38),
              border: Border.all(color: const Color(0xFF292C32)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () => setState(() => _showClearChatConfirmation = false),
                  child: _clearChatConfirmationRow(
                    child: Row(
                      children: [
                        SvgPicture.asset(
                          'assets/svg/ic--round-arrow-back-ios.svg',
                          width: 24,
                          height: 24,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                        const SizedBox(width: 26),
                        const Text('Back', style: TextStyle(color: Colors.white, fontSize: 14)),
                      ],
                    ),
                  ),
                ),
                _clearChatConfirmationRow(
                  child: Text(
                    'Do you want to clear all messages with\n${_profileDisplayName()}?',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                InkWell(
                  onTap: () {},
                  child: _clearChatConfirmationRow(
                    child: const Text(
                      'Clear all messages',
                      style: TextStyle(color: Color(0xFFFF5C52), fontSize: 14),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _showClearChatConfirmation = false),
                  child: _clearChatConfirmationRow(
                    child: const Text('Cancel', style: TextStyle(color: Colors.white, fontSize: 14)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _clearChatConfirmationRow({required Widget child}) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: child,
        ),
      ),
    );
  }

  Future<void> _loadMuteState() async {
    final roomId = widget.conversationId?.trim() ?? '';
    if (roomId.isEmpty) return;
    final muted = await MuteRoomsService.instance.isMuted(roomId);
    if (mounted) setState(() => _roomMuted = muted);
  }

  Future<void> _applyMuteOption(String option) async {
    final roomId = widget.conversationId?.trim() ?? '';
    if (roomId.isEmpty) return;
    final duration = switch (option) {
      '8 hours' => const Duration(hours: 8),
      '1 day' => const Duration(days: 1),
      '7 days' => const Duration(days: 7),
      'Always' => null,
      _ => null,
    };
    if (option == 'Always') {
      await MuteRoomsService.instance.muteForever(roomId);
    } else if (duration != null) {
      await MuteRoomsService.instance.mute(roomId, duration);
    }
    if (!mounted) return;
    setState(() {
      _roomMuted = true;
      _showMuteOptions = false;
      _showMoreOptions = false;
    });
  }

  Future<void> _unmuteRoom() async {
    final roomId = widget.conversationId?.trim() ?? '';
    if (roomId.isEmpty) return;
    await MuteRoomsService.instance.unmute(roomId);
    if (!mounted) return;
    setState(() {
      _roomMuted = false;
      _showMoreOptions = false;
    });
  }

  String? _moreOptionIconPath(String option) {
    switch (option) {
      case 'Mute':
        return 'assets/images/Bell new icon slash .svg';
      case 'Unmute':
        return 'assets/images/Bell new icon .svg';
      case 'Share contact':
        return 'assets/images/Share icon.svg';
      case 'Auto delete':
        return 'assets/images/Disappearing messages icon.svg';
      case 'Clear chat':
        return 'assets/images/Clear messages icon.svg';
      case 'Block user':
        return 'assets/images/Block user.svg';
      default:
        return null;
    }
  }

  Widget _buildUnsavedProfileActions() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          width: 84,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF23262C)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showBlockUserCard = true),
                child: SvgPicture.asset(
                  'assets/images/Block user.svg',
                  width: 24,
                  height: 24,
                  colorFilter: ColorFilter.mode(
                    _isProfileUserBlocked
                        ? const Color(0xFFFF5C52)
                        : Colors.white,
                    BlendMode.srcIn,
                  ),
                ),
              ),
              const SizedBox(width: 20),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  debugPrint('[ProfileScreen] Add to contact icon tapped');
                  _openAddContact();
                },
                child: SvgPicture.asset(
                  'assets/images/Add to contact.svg',
                  width: 24,
                  height: 24,
                  semanticsLabel: 'Add to contact',
                  colorFilter: const ColorFilter.mode(
                    Colors.white,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBlockUserCard() {
    return GestureDetector(
      onTap: _isProfileUserBlocked ? _unblockProfileUser : _blockProfileUser,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1D24).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFF23262C), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
          SvgPicture.asset(
            'assets/images/Block user.svg',
            width: 24,
            height: 24,
            colorFilter: ColorFilter.mode(
              _isProfileUserBlocked
                  ? Colors.white
                  : const Color(0xFFFF5C52),
              BlendMode.srcIn,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _isProfileUserBlocked ? 'Unblock user' : 'Block user',
            style: TextStyle(
              color: _isProfileUserBlocked
                  ? Colors.white
                  : const Color(0xFFFF5C52),
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          ],
        ),
      ),
    );
  }

  Future<void> _blockProfileUser() async {
    if (_blockActionInFlight) return;
    _blockActionInFlight = true;
    try {
    final userId = _profileTargetUserId;
    final roomId = widget.conversationId?.trim() ?? '';
    if (userId == null || roomId.isEmpty) return;
    await BlockStateService.instance.addBlock(userId: userId, roomId: roomId);
    if (mounted) setState(() {});
    } finally {
      _blockActionInFlight = false;
    }
  }

  Future<void> _unblockProfileUser() async {
    if (_blockActionInFlight) return;
    _blockActionInFlight = true;
    try {
    final userId = _profileTargetUserId;
    final roomId = widget.conversationId?.trim() ?? '';
    if (userId == null || roomId.isEmpty) return;
    await BlockStateService.instance.removeBlock(userId: userId, roomId: roomId);
    if (mounted) setState(() {});
    } finally {
      _blockActionInFlight = false;
    }
  }

  Widget _actionPill(
    IconData? icon,
    String label, {
    String? iconAsset,
    double iconSize = 36,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,

      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF08090B),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: const Color(0xFF23262C),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [

          SizedBox(
            height: 30,
            child: Center(
              child:
                  iconAsset != null
                      ? SvgPicture.asset(
                          iconAsset,
                          width: iconSize,
                          height: iconSize,
                        )
                      : Icon(
                          icon,
                          color: Colors.white,
                          size: iconSize,
                        ),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 12,
            ),
          ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Own profile tab content ────────────────────────────────────────────────

  Widget _buildPostsTab() {
    return ListView(
      // Keep the empty-state content low in the available profile area,
      // matching the reference spacing below the Posts/Saved tab bar.
      padding: const EdgeInsets.only(top: 220, bottom: 120),
      physics: const BouncingScrollPhysics(),
      children: [
        const Text(
          "Publish photo and video to\ndisplay on your profile page",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: 11),
        ),
        const SizedBox(height: 6),
        _buildAddStoriesButton(),
      ],
    );
  }

  Widget _buildTopAddButton() {
    return GestureDetector(
      onTap: _openStoryCamera,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            width: 38,
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withValues(alpha: 0.30),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF23262C)),
            ),
            child: Center(
              child: SvgPicture.asset(
                'assets/images/status_icon.svg',
                width: 26,
                height: 26,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAddStoryButton() {
    if (!_statusIconBuildLogged) {
      _statusIconBuildLogged = true;
      apkLog(
        'Profile.status_icon',
        'build asset="assets/images/status_icon.svg" '
            'wrapper="none" size="92x92"',
      );
    }
    return GestureDetector(
      onTap: () {
        apkLog(
          'Profile.status_icon',
          'tap asset="assets/images/status_icon.svg" action="open_camera"',
        );
        unawaited(_openStoryCamera());
      },
      child: SizedBox(
        width: 92,
        height: 92,
        child: SvgPicture.asset(
          'assets/images/status_icon.svg',
          width: 92,
          height: 92,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  Widget _buildAddStoriesButton() {
    final screenWidth = MediaQuery.of(context).size.width;
    return Center(
      child: SizedBox(
        width: screenWidth * 0.6,
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF249FF0),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: const Color(0xFF249FF0),
                width: 1,
              ),
            ),
            child: SizedBox.expand(
              child: FilledButton(
                onPressed: _openStoryCamera,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF249FF0),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  side: const BorderSide(
                    color: Color(0xFF249FF0),
                    width: 1,
                  ),
                  padding: EdgeInsets.zero,
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                child: const Text('Add Stories'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openStoryCamera() async {
    final camera = CameraRepositoryImpl(
      DeviceCameraService(),
      const CameraCapabilitiesService(),
      CameraSessionManager(),
    );
    try {
      await showWrytteCamera(
        context,
        repository: camera,
        config: const CameraSessionConfig.chatAttachment(),
      );
    } finally {
      await camera.close();
    }
  }

  Widget _buildSavedTab() {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: const Center(
            child: Text(
              "No saved posts yet",
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyTab(IconData icon, String label) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 52,
                  color: Colors.white.withValues(alpha: 0.15),
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMediaTab() {
    final items =
        _conversationMessages
            .where(
              (message) =>
                  message.attachmentType == 'image' ||
                  message.attachmentType == 'video',
            )
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (items.isEmpty) {
      return _buildEmptyTab(Icons.photo_library_outlined, 'No media');
    }
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(14),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildMediaTile(items[index]),
              childCount: items.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilesTab() {
    final items =
        _conversationMessages
            .where((message) => message.attachmentType == 'file')
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (items.isEmpty) {
      return _buildEmptyTab(Icons.insert_drive_file_outlined, 'No files');
    }
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: WrytteFileCard(
                source: item.attachmentUrl ?? '',
                fileName: item.content.trim().isEmpty ? 'File' : item.content,
                profileStyle: true,
                trailing: Text(
                  _formatProfileMessageDate(item.timestamp),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 11,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildLinksTab() {
    final links =
        _conversationMessages
            .map(
              (message) => (
                link: _firstLinkIn(message.content),
                timestamp: message.timestamp,
              ),
            )
            .where((item) => item.link != null)
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (links.isEmpty) return _buildEmptyTab(Icons.link_outlined, 'No links');
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverList.builder(
          itemCount: links.length,
          itemBuilder: (context, index) {
            final item = links[index];
            final section = _linkSectionLabel(item.timestamp);
            final showSection =
                index == 0 ||
                _linkSectionLabel(links[index - 1].timestamp) != section;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSection)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 5),
                    child: Text(
                      section,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
                  child: WrytteLinkPreview(
                    url: item.link!,
                    showOriginalUrl: true,
                    compact: true,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  String _linkSectionLabel(DateTime timestamp) {
    final now = DateTime.now();
    final age = now.difference(timestamp);
    if (age.inDays < 7) return 'RECENT';
    if (age.inDays < 60) return 'LAST MONTH';
    const months = [
      'JANUARY',
      'FEBRUARY',
      'MARCH',
      'APRIL',
      'MAY',
      'JUNE',
      'JULY',
      'AUGUST',
      'SEPTEMBER',
      'OCTOBER',
      'NOVEMBER',
      'DECEMBER',
    ];
    return months[timestamp.month - 1];
  }

  Widget _buildMediaTile(ChatMessage message) {
    final url = message.attachmentUrl?.trim() ?? '';
    if (message.attachmentType == 'video') {
      return GestureDetector(
        onTap: () => FullScreenVideoViewer.open(context, url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              WrytteVideoThumbnail(source: url),
              IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.18),
                  child: const Center(
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final child = WryttePersistentImage(source: url, fit: BoxFit.cover);
    return GestureDetector(
      onTap: () => FullScreenImageViewer.open(context, url),
      child: ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
    );
  }

  String _formatProfileMessageDate(DateTime value) {
    final now = DateTime.now();
    if (now.year == value.year &&
        now.month == value.month &&
        now.day == value.day) {
      return 'Today';
    }
    return '${value.day}/${value.month}/${value.year}';
  }

  String? _firstLinkIn(String value) {
    final match = RegExp(r'https?://[^\s]+').firstMatch(value);
    return match?.group(0);
  }

  // ── Avatar shimmer ─────────────────────────────────────────────────────────

  Widget _buildAvatarShimmer(double size) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF2A2D34),
      ),
    );
  }

  // ── Bio ────────────────────────────────────────────────────────────────────

  Widget _buildBio(String bioText) {
    if (_bioExpanded) {
      return GestureDetector(
        onTap: () => setState(() => _bioExpanded = false),
        child: Text(bioText, textAlign: TextAlign.start, style: _bioStyle),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final fullPainter = TextPainter(
          text: TextSpan(text: bioText, style: _bioStyle),
          maxLines: 3,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        if (!fullPainter.didExceedMaxLines) {
          return Text(bioText, textAlign: TextAlign.start, style: _bioStyle);
        }

        int lo = 0, hi = bioText.length;
        while (lo < hi) {
          final mid = (lo + hi + 1) ~/ 2;
          final candidate = '${bioText.substring(0, mid).trimRight()}... more';
          final p = TextPainter(
            text: TextSpan(text: candidate, style: _bioStyle),
            maxLines: 3,
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: constraints.maxWidth);
          if (p.didExceedMaxLines) {
            hi = mid - 1;
          } else {
            lo = mid;
          }
        }

        final visibleText = bioText.substring(0, lo).trimRight();

        return GestureDetector(
          onTap: () => setState(() => _bioExpanded = true),
          child: Text.rich(
            TextSpan(
              style: _bioStyle,
              children: [
                TextSpan(text: visibleText),
                const TextSpan(
                  text: '... ',
                  style: TextStyle(color: Colors.white),
                ),
                const TextSpan(
                  text: 'read more',
                  style: TextStyle(color: Color(0xFF4DA3FF)),
                ),
              ],
            ),
            maxLines: 3,
            textAlign: TextAlign.start,
          ),
        );
      },
    );
  }

  // ── Links ──────────────────────────────────────────────────────────────────

  String _displayProfileLink(String value) {
    var display = value.trim();
    display = display.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    display = display.replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');
    if (display.length <= 33) return display;
    return '${display.substring(0, 30)}...';
  }

  Widget _buildLinks(List<String> links) {
    final firstLink = links[0];
    final hasMore = links.length > 1;
    final remainingCount = links.length - 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => _launchLink(firstLink),
          child: Row(
            children: [

              SizedBox(
                width: 12,
                height: 12,
                child: Transform.scale(
                  scaleX: -1,
                  child: SvgPicture.asset(
                    'assets/images/link_icon.svg',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _displayProfileLink(firstLink),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              if (hasMore && !_linksExpanded) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => setState(() => _linksExpanded = true),
                  child: Text(
                    '$remainingCount more',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_linksExpanded)
          ...links
              .skip(1)
              .map(
                (link) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: GestureDetector(
                    onTap: () => _launchLink(link),
                    child: Row(
                      children: [
                        ColorFiltered(
                          colorFilter: const ColorFilter.matrix([
                            0, 0, 0, 0, 255,
                            0, 0, 0, 0, 255,
                            0, 0, 0, 0, 255,
                            1, 0, 0, 0, 0,
                          ]),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: Transform.scale(
                              scaleX: -1,
                              child: SvgPicture.asset(
                                'assets/images/link_icon.svg',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _displayProfileLink(link),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ],
    );
  }

  Widget _profileSectionDivider(Color color, {required double height}) {
    return Padding(
      padding: const EdgeInsets.only(left: 20),
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: Row(
          children: [Expanded(child: Container(height: 1, color: color))],
        ),
      ),
    );
  }

  Widget _buildFeaturedRoomRow({
    required String label,
    required String reference,
    required MatrixPublicGroup? room,
    required bool isChannel,
  }) {
    final title =
        room?.name.trim().isNotEmpty == true
            ? room?.name.trim() ?? label
            : reference.startsWith('!')
            ? label
            : reference;
    final count = room?.memberCount;
    final countLabel =
        count == null
            ? ''
            : isChannel
            ? '$count ${count == 1 ? 'subscriber' : 'subscribers'}'
            : '$count ${count == 1 ? 'member' : 'members'}';
    return InkWell(
      onTap: () => _openProfileRoom(reference, isChannel: isChannel),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            UserAvatar(
              size: 42,
              imageUrl: room?.avatarUrl,
              name: title,
              cacheIdentity:
                  room == null
                      ? null
                      : 'room:${room.roomId}:${room.profileVersionFingerprint}',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (countLabel.isNotEmpty)
                    Text(
                      countLabel,
                      style: const TextStyle(
                        color: Color(0xFFB9BBC1),
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(color: Color(0xFFB9BBC1), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ── Glass helpers ──────────────────────────────────────────────────────────

  Widget _glassButton({required IconData icon, required VoidCallback onTap}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF23262C)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: GestureDetector(
              onTap: onTap,
              child: Icon(
                icon,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _glassTextButton({required String text, required VoidCallback onTap}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF23262C)),
          ),
          child: GestureDetector(
            onTap: onTap,
            child: Center(
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileAddContactSheet extends StatefulWidget {
  const _ProfileAddContactSheet({
    required this.initialName,
    required this.phone,
    this.showDeleteContact = false,
    this.onDeleteContact,
  });

  final String initialName;
  final String phone;
  final bool showDeleteContact;
  final VoidCallback? onDeleteContact;

  @override
  State<_ProfileAddContactSheet> createState() =>
      _ProfileAddContactSheetState();
}

class _ProfileAddContactSheetState extends State<_ProfileAddContactSheet> {
  late final TextEditingController _nameController;
  bool _syncToPhone = true;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0x4D23262C),
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: Border(
                top: BorderSide(
                  color: Color(0xFF23262C),
                  width: 1,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  30,
                  16,
                  MediaQuery.viewInsetsOf(context).bottom + 24,
                ),
                child: Column(
                  children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _sheetCircleButton(
                    icon: Icons.close,
                    onTap: () => Navigator.pop(context),
                  ),
                  AnimatedBuilder(
                    animation: _nameController,
                    builder: (context, _) {
                      final hasName = _nameController.text.trim().isNotEmpty;
                      return GestureDetector(
                        onTap: hasName
                            ? () => Navigator.pop(context, true)
                            : null,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: hasName
                                ? const Color(0xFF249FF0)
                                : const Color(0xFF3A3D44),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _sheetField(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _nameController,
                        autofocus: true,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                        ),
                        textAlignVertical: TextAlignVertical.center,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Name',
                          hintStyle: TextStyle(color: Colors.white70),
                          isCollapsed: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _sheetField(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.phone,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const WrytteIdCheckmark(),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Sync contact to phone',
                      style: TextStyle(color: Colors.white, fontSize: 17),
                    ),
                  ),
                  SyncContactsSwitch(
                    value: _syncToPhone,
                    onChanged: (value) => setState(() => _syncToPhone = value),
                  ),
                ],
              ),
              if (widget.showDeleteContact) ...[
                const SizedBox(height: 5),
                GestureDetector(
                  onTap: widget.onDeleteContact,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Container(
                        width: double.infinity,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFF23262C).withValues(alpha: 0.30),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: const Color(0xFF23262C)),
                        ),
                        child: const Text(
                          'Delete contact',
                          style: TextStyle(
                            color: Color(0xFFFF6B6B),
                            fontSize: 17,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sheetField({required Widget child}) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF23262C).withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF23262C)),
        ),
        child: child,
      ),
    ),
  );

  Widget _sheetCircleButton({
    required IconData icon,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withValues(alpha: 0.30),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF23262C)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    ),
  );
}

// ── Sticky tab bar delegate ────────────────────────────────────────────────────

class _StickyTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double topOffset;

  const _StickyTabBarDelegate({required this.child, this.topOffset = 0});

  static const double _height = 52.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox(height: _height, child: child);

  @override
  bool shouldRebuild(_StickyTabBarDelegate old) =>
      old.child != child || old.topOffset != topOffset;
}
