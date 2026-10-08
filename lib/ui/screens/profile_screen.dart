import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui';
import 'package:wrytte/components/user_avatar.dart';
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
import 'package:wrytte/models/user_models/wrytte_profile.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';
import 'package:wrytte/ui/screens/channels/channel_feed_screen.dart';
import 'package:wrytte/ui/screens/group_profile_screen.dart';
import 'package:wrytte/ui/widgets/full_screen_image_viewer.dart';
import 'package:wrytte/ui/widgets/full_screen_video_viewer.dart';
import 'package:wrytte/ui/widgets/profile_tab_bar_section.dart';
import 'package:wrytte/ui/widgets/wrytte_file_card.dart';
import 'package:wrytte/ui/widgets/wrytte_link_preview.dart';
import 'package:wrytte/ui/widgets/wrytte_persistent_image.dart';
import 'package:wrytte/ui/widgets/wrytte_video_thumbnail.dart';
import 'package:wrytte/utils/wrytte_id.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'package:wrytte/utils/country_phone_number.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  /// When null — shows the current logged-in user's own profile.
  /// When provided — shows another user's profile (read-only).
  final String? uid;
  final String? conversationId;
  final String? savedNameHint;
  final String? initialAvatarUrl;
  final String? initialProfileName;
  final bool embeddedInHome;

  const ProfileScreen({
    super.key,
    this.uid,
    this.conversationId,
    this.savedNameHint,
    this.initialAvatarUrl,
    this.initialProfileName,
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
  List<ChatMessage> _conversationMessages = const [];
  StreamSubscription<UserProfile?>? _profileSub;
  StreamSubscription<String>? _publicProfileUpdatesSub;
  String? _seededSavedName;
  MatrixPublicGroup? _profileChannel;
  MatrixPublicGroup? _profileGroup;
  int _profileRoomResolveRevision = 0;

  late final TabController _tabController;

  bool get _isOtherUser {
    final uid = _validProfileUid(widget.uid);
    final ownUid = UserProfileService.instance.cachedProfile?.uid;
    if (uid != null && uid != ownUid) return true;
    return widget.conversationId?.trim().isNotEmpty ?? false;
  }

  List<String> get _tabs =>
      _isOtherUser ? ['Media', 'Files', 'Feed', 'Links'] : ['Posts', 'Saved'];

  @override
  void initState() {
    super.initState();
    _seededSavedName = _cleanName(
      widget.savedNameHint,
    ); // ← add, runs before first build
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
    unawaited(_loadProfile(forceRefresh: true));
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _publicProfileUpdatesSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile({bool forceRefresh = false}) async {
    var uid = _validProfileUid(widget.uid);
    uid ??= await _resolveProfileUidFromConversation();
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
        // Contact was deleted meanwhile — drop the hint so the public name shows.
        _seededSavedName = null;
      }
    });
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
      // An individual's tabs are strictly DM-scoped. Reject a group room even
      // if a caller accidentally supplies one in the future.
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
        _profileLoading = false;
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
        profile.bio.trim().isNotEmpty;
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
    if (local != null) return local;
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
      return MatrixPublicGroup(
        roomId: summary.roomId,
        name:
            summary.name?.trim().isNotEmpty == true
                ? summary.name!.trim()
                : reference.trim(),
        avatarUrl: summary.avatarUrl?.toString(),
        canonicalAlias: summary.canonicalAlias,
        topic: summary.topic,
        memberCount: summary.numJoinedMembers,
        worldReadable: summary.worldReadable,
        roomType: summary.roomType,
      );
    } catch (error) {
      apkLog(
        'Profile.room',
        'summary lookup failed ref="${reference.trim()}" error="$error"',
      );
      return null;
    }
  }

  Future<void> _loadProfileRoomCards(UserProfile profile) async {
    final revision = ++_profileRoomResolveRevision;
    final channelRef =
        _canViewProfileField(profile, 'Channel')
            ? profile.channelAlias.trim()
            : '';
    final groupRef =
        _canViewProfileField(profile, 'Group') ? profile.groupAlias.trim() : '';
    final results = await Future.wait<MatrixPublicGroup?>([
      channelRef.isEmpty
          ? Future<MatrixPublicGroup?>.value(null)
          : _resolveProfileRoom(channelRef, isChannel: true),
      groupRef.isEmpty
          ? Future<MatrixPublicGroup?>.value(null)
          : _resolveProfileRoom(groupRef, isChannel: false),
    ]);
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
    final room = MatrixChatService.instance.getRoomById(group.roomId);
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
                subscriberCount: group.memberCount,
                readOnlyUntilSubscribe: room?.membership != mx.Membership.join,
                subscribeAlias: group.canonicalAlias ?? reference,
              ),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => GroupProfileScreen(
                roomId: group.roomId,
                groupName: group.name,
                avatarUrl: group.avatarUrl,
                alias: group.canonicalAlias ?? reference,
                initialDescription: group.topic,
                initialMemberCount: group.memberCount,
                initiallyJoined: room?.membership == mx.Membership.join,
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
      // Seeded from the caller (chat header) — present on the very first frame.
      if (_seededSavedName != null && _seededSavedName!.isNotEmpty) {
        return WrytteId.forDisplay(_seededSavedName!) ?? _seededSavedName!;
      }
      // Saved contact resolved during load.
      final savedName = _cleanName(_savedContact?.formattedName);
      if (savedName.isNotEmpty) {
        return WrytteId.forDisplay(savedName) ?? savedName;
      }
      // Identity cache saved name.
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
    final profile = _profile;
    if (profile?.hasProfileImage == true) return profile!.profileImage;
    // A successful Module API response is authoritative. If it says there is
    // no avatar, don't fall back to the stale URL passed when this screen opened.
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
    final uri = Uri.parse(
      raw.startsWith('http://') || raw.startsWith('https://')
          ? raw
          : 'https://$raw',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
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
    final uid =
        _validProfileUid(widget.uid) ??
        _validProfileUid(_identity?.matrixUserId) ??
        _validProfileUid(_savedContact?.wrytteUserId);
    final phone = _profilePhone();
    if (uid == null && phone.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => NewContactPage(
              token: '',
              initialIdentifier: phone.isNotEmpty ? phone : uid,
              initialWrytteUserId: uid == null ? null : _toMatrixUserId(uid),
              initialName: _profileDisplayName(),
              initialBio: _profileBio(),
              readOnlyIdentifier: true,
            ),
      ),
    );
    if (mounted) _loadProfile();
  }

  Future<void> _deleteSavedContact() async {
    final contact = _savedContact;
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    final uid = _validProfileUid(widget.uid);
    if (contact == null ||
        ownerUserId == null ||
        ownerUserId.isEmpty ||
        uid == null) {
      return;
    }

    await ContactLocalDb.removeContact(contact, ownerUserId: ownerUserId);
    unawaited(
      ContactService()
          .removeContactFromBackend(ownerUserId: ownerUserId, contact: contact)
          .catchError(
            (e) =>
                debugPrint('[ProfileScreen] backend contact remove failed: $e'),
          ),
    );
    await ContactIdentityCache.instance.clearSavedName(
      ownerUserId: ownerUserId,
      matrixUserId: uid,
    );
    await ChatService().applyUnsavedContact(contact);
    ContactService.invalidateMatrixContactsCache();
    ContactService().invalidateCache();

    final identity = await ContactIdentityCache.instance.findByMatrixId(
      ownerUserId: ownerUserId,
      matrixUserId: uid,
    );
    if (!mounted) return;
    setState(() {
      _savedContact = null;
      _identity = identity;
    });
  }

  Future<void> _showMoreActions() async {
    final isSaved = _savedContact != null;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1F25),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSaved)
                  ListTile(
                    leading: const Icon(
                      Icons.person_remove_outlined,
                      color: Color(0xFFFF6B6B),
                    ),
                    title: const Text(
                      'Delete contact',
                      style: TextStyle(color: Color(0xFFFF6B6B)),
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      await _deleteSavedContact();
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.close, color: Colors.white70),
                  title: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
    );
  }

  static const TextStyle _bioStyle = TextStyle(
    color: Color(0xFFC6C6C6),
    fontSize: 14,
  );

  bool get _hasCard {
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
    return _profile?.bio.trim() ?? '';
  }

  @override
  Widget build(BuildContext context) {
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
    final List<String> links = _profile?.links ?? [];
    final channelRef =
        _canViewProfileField(_profile, 'Channel')
            ? _profile?.channelAlias.trim() ?? ''
            : '';
    final groupRef =
        _canViewProfileField(_profile, 'Group')
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
                          SizedBox(height: topBarHeight + 20),

                          // ── Avatar ──────────────────────────────────────────
                          _profileLoading && !hasProfile && !hasInitialAvatar
                              ? _buildAvatarShimmer(100)
                              : UserAvatar(
                                size: 100,
                                imageUrl: _profileAvatarUrl(),
                                localImagePath: _profile?.localProfileImagePath,
                                cacheIdentity:
                                    'user:${(widget.uid ?? _profile?.uid ?? '').trim().toLowerCase()}',
                                name: displayName,
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

                          if (bioText.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                              ),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF23262C),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: _buildBio(bioText),
                              ),
                            ),
                          ],

                          const SizedBox(height: 16),

                          // ── Quick actions (other user only) ─────────────────
                          if (_isOtherUser) ...[
                            _buildQuickActions(),
                            const SizedBox(height: 20),
                          ],

                          // ── Links and featured rooms ───────────────────────
                          if (!_profileLoading &&
                              (links.isNotEmpty ||
                                  channelRef.isNotEmpty ||
                                  groupRef.isNotEmpty)) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF23262C),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (links.isNotEmpty) _buildLinks(links),
                                    if (links.isNotEmpty &&
                                        (channelRef.isNotEmpty ||
                                            groupRef.isNotEmpty))
                                      const Divider(
                                        height: 24,
                                        color: Color(0xFF34373E),
                                      ),
                                    if (channelRef.isNotEmpty)
                                      _buildFeaturedRoomRow(
                                        label: 'Channel',
                                        reference: channelRef,
                                        room: _profileChannel,
                                        isChannel: true,
                                      ),
                                    if (channelRef.isNotEmpty &&
                                        groupRef.isNotEmpty)
                                      const Divider(
                                        height: 1,
                                        color: Color(0xFF34373E),
                                        indent: 54,
                                      ),
                                    if (groupRef.isNotEmpty)
                                      _buildFeaturedRoomRow(
                                        label: 'Group',
                                        reference: groupRef,
                                        room: _profileGroup,
                                        isChannel: false,
                                      ),
                                  ],
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

                    // ── Sticky tab bar — pins just below the top app bar ──────
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
                        // ── Back button ──────────────────────────────────
                        widget.embeddedInHome
                            ? const SizedBox(width: 44)
                            : _glassButton(
                              icon: Icons.arrow_back_ios,
                              onTap: () => Navigator.pop(context),
                            ),

                        // ── Title — only shown for own profile, truly centered ─
                        Expanded(
                          child:
                              _isOtherUser
                                  ? const SizedBox.shrink()
                                  : const Center(
                                    child: Text(
                                      "Profile",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                        ),

                        // ── Edit / action button ─────────────────────────
                        _isOtherUser
                            ? _glassButton(
                              icon: Icons.more_vert,
                              onTap: _showMoreActions,
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

  // ── Quick actions — solid background, no glass ────────────────────────────
  // CHANGE 3: Solid 0xFF23262C, no blur/opacity

  Widget _buildQuickActions() {
    final showAddContact =
        _savedContact == null && _cleanName(_identity?.savedName).isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: _actionPill(Icons.call_outlined, 'Calls', onTap: () {}),
          ),
          const SizedBox(width: 10),
          if (showAddContact) ...[
            Expanded(
              child: _actionPill(
                Icons.person_add_alt_1_outlined,
                'Add',
                onTap: _openAddContact,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: _actionPill(Icons.videocam_outlined, 'Video', onTap: () {}),
          ),
          const SizedBox(width: 10),
          Expanded(child: _actionPill(Icons.search, 'Search', onTap: () {})),
          const SizedBox(width: 10),
          Expanded(child: _actionPill(Icons.more_horiz, 'More', onTap: () {})),
        ],
      ),
    );
  }

  Widget _actionPill(IconData icon, String label, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          // CHANGE 3: Solid color, no transparency, no BackdropFilter
          color: const Color(0xFF23262C),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF23262C), width: 1.0),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Own profile tab content ────────────────────────────────────────────────

  Widget _buildPostsTab() {
    return ListView(
      padding: const EdgeInsets.only(top: 40, bottom: 120),
      // CHANGE 4: Bouncing physics so empty tabs have iOS-style spring bounce
      // without scrolling the header content away
      physics: const BouncingScrollPhysics(),
      children: [
        const Text(
          "Publish photo and video to\ndisplay on your profile page",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Center(
          child: FilledButton(
            onPressed: () {},
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: const Color(0xFF4DA3FF),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            child: const Text("Add storie", style: TextStyle(fontSize: 15)),
          ),
        ),
      ],
    );
  }

  Widget _buildSavedTab() {
    // CHANGE 4: Wrap in a scrollable with bouncing physics so it feels iOS-native
    // but won't fully scroll the header away when there's no data
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

  // ── Other user empty tab states ────────────────────────────────────────────
  // CHANGE 4: Each empty tab is a CustomScrollView with SliverFillRemaining
  // so it fills the space without allowing full header scroll-away,
  // but retains the iOS bounce animation on over-scroll.

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
        child: Text(bioText, textAlign: TextAlign.center, style: _bioStyle),
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
          return Text(bioText, textAlign: TextAlign.center, style: _bioStyle);
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
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }

  // ── Links ──────────────────────────────────────────────────────────────────

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
              const Icon(Icons.link, color: Color(0xFF4DA3FF), size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  firstLink,
                  style: const TextStyle(
                    color: Color(0xFF4DA3FF),
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
                      color: Color(0xFF4DA3FF),
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
                        const Icon(
                          Icons.link,
                          color: Color(0xFF4DA3FF),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            link,
                            style: const TextStyle(
                              color: Color(0xFF4DA3FF),
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

  Widget _buildFeaturedRoomRow({
    required String label,
    required String reference,
    required MatrixPublicGroup? room,
    required bool isChannel,
  }) {
    final title =
        room?.name.trim().isNotEmpty == true
            ? room!.name.trim()
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
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 16),
            onPressed: onTap,
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
                style: const TextStyle(color: Color(0xFF4DA3FF), fontSize: 16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sticky tab bar delegate ────────────────────────────────────────────────────
// CHANGE 5: topOffset is accepted but the delegate pins at its natural sliver
// position (just after the header slivers), which means the tab bar sticks
// right below where the header ends — and stays there on scroll.

class _StickyTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  // topOffset kept for reference / future use but pinning is handled by
  // SliverPersistentHeader(pinned: true) in the NestedScrollView header.
  final double topOffset;

  const _StickyTabBarDelegate({required this.child, this.topOffset = 0});

  static const double _height = 56.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  bool shouldRebuild(_StickyTabBarDelegate old) =>
      old.child != child || old.topOffset != topOffset;
}
