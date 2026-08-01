import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_avatar_sanitizer.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/contacts/user_search_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/screens/channels/channel_feed_screen.dart';
import 'package:wrytte/ui/screens/group_profile_screen.dart';
import 'package:wrytte/ui/screens/chats/widgets/conversation_tile.dart';
import 'package:wrytte/ui/screens/chats/widgets/mini_chat_window.dart';
import 'package:wrytte/ui/screens/chats/widgets/top_bar.dart';
import 'package:wrytte/ui/screens/firebase_new_chat_screen.dart';
import 'package:wrytte/ui/widgets/wrytte_link_preview.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'package:wrytte/utils/country_phone_number.dart';
import 'widgets/search_bar.dart' as local_widgets;
import 'widgets/tab_bar_section.dart';

// =============================================================================
//  ConversationsScreen
//
//  Name resolution priority (highest -> lowest):
//    1. Saved contacts from local/backend contact storage.
//    2. Phone number.
// =============================================================================

const double _kSearchBarHeight = 60.0;
const double _kTabBarHeight = 56.0;

class ConversationsScreen extends StatefulWidget {
  final Function(int)? onUnreadCountUpdated;
  final String currentUserId;
  final List<Contact> initialSavedContacts;

  const ConversationsScreen({
    super.key,
    this.onUnreadCountUpdated,
    this.currentUserId = '',
    this.initialSavedContacts = const [],
  });

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}
//final Map<String, (String?, String?)?> _matrixProfileCache = {};

class _ConversationsScreenState extends State<ConversationsScreen>
    with SingleTickerProviderStateMixin {
  static const List<mx.Membership> _groupMemberships = [
    mx.Membership.join,
    mx.Membership.invite,
  ];

  final ChatService _chat = ChatService();
  final UserSearchService _userSearchService = UserSearchService();
  final Map<String, (String?, String?)?> _matrixProfileCache = {};

  List<ChatConversation> _conversations = [];
  List<MatrixPublicGroup> _suggestedGroups = const [];
  Map<String, String> _cachedRoomCategories = const {};
  Map<String, String> _localRoomAvatarPaths = const {};
  Map<String, String> _localRoomAvatarSources = const {};

  String _currentUserId = '';
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  StreamSubscription<List<ChatConversation>>? _convSub;
  StreamSubscription<bool>? _chatConnectionSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<String>? _contactsChangedSub;
  StreamSubscription? _matrixSyncSub;
  Timer? _conversationBatchTimer;
  Timer? _groupExitTimer;
  GroupExitRequest? _pendingGroupExit;
  DateTime? _groupExitDeadline;
  int _groupExitSecondsRemaining = 5;
  final Set<String> _groupExitHiddenRoomIds = {};

  late final TabController _tabController;
  final ScrollController _scrollCtrl = ScrollController();
  double _searchBarProgress = 0.0;

  // ── Priority 1: saved contact names keyed by phone, Matrix ID, and localpart.
  final Map<String, String> _contactNameCache = {};
  final Map<String, String?> _contactAvatarCache = {};
  final Map<String, ContactIdentity> _identityCache = {};
  final Map<String, String> _groupLastSenderNames = {};
  final Set<String> _groupLastSenderInFlight = {};
  Set<String> _dismissedDeletedGroupRoomIds = const <String>{};
  List<Contact> _savedContacts = const [];
  bool _initialCacheWarmup = true;
  int _conversationPaintVersion = 0;
  int _conversationRefreshVersion = 0;
  List<ChatConversation>? _pendingConversationBatch;
  bool _conversationBatchInFlight = false;
  Future<void>? _contactRestoreFuture;
  bool _loadingSuggestedGroups = false;
  final Set<String> _openingSuggestedGroupIds = {};
  final Set<String> _subscribingSuggestedGroupIds = {};
  final Set<String> _openingConversationIds = {};
  DateTime? _lastSuggestedGroupsLoadAt;
  String? _lastGroupsDiagnostic;
  static const Duration _suggestedGroupsRefreshInterval = Duration(seconds: 8);

  // ===========================================================================
  //  LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _seedSavedContacts(widget.initialSavedContacts);
    _seedHydratedConversationSnapshot();
    // Do not synchronously paint cached DM rows here. Even when initial saved
    // contacts are present, backend contact rows can lack the UID-to-phone
    // mapping used by older cached conversations. _initialize first loads the
    // persisted identity cache and Profile 2 contacts, then publishes rows.
    _scrollCtrl.addListener(_onScroll);
    Future.microtask(_initialize);
    try {
      _matrixSyncSub = MatrixClientService.instance.client.onSync.stream.listen(
        (_) {
          if (mounted && _tabController.index == 1) setState(() {});
        },
      );
    } catch (_) {}
  }

  void _seedHydratedConversationSnapshot() {
    final requestedOwner = widget.currentUserId.trim().toLowerCase();
    final hydratedOwner = _chat.currentUserId?.trim().toLowerCase() ?? '';
    if (requestedOwner.isEmpty || hydratedOwner != requestedOwner) return;
    final snapshot = _chat.cachedConversationsSnapshot;
    if (snapshot.isNotEmpty) {
      _conversations = List<ChatConversation>.from(snapshot);
    }
  }

  @override
  void dispose() {
    _convSub?.cancel();
    _chatConnectionSub?.cancel();
    _connectivitySub?.cancel();
    _contactsChangedSub?.cancel();
    _matrixSyncSub?.cancel();
    _conversationBatchTimer?.cancel();
    _groupExitTimer?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final progress = (_scrollCtrl.offset / _kSearchBarHeight).clamp(0.0, 1.0);
    if ((progress - _searchBarProgress).abs() > 0.005) {
      setState(() => _searchBarProgress = progress);
    }
  }

  // ===========================================================================
  //  INITIALIZE
  // ===========================================================================

  void _seedSavedContacts(List<Contact> contacts) {
    if (contacts.isEmpty) return;
    _savedContacts = _sortContacts(contacts);
    _contactNameCache.clear();
    _contactAvatarCache.clear();
    for (final c in _savedContacts) {
      final name = c.displayName ?? '';
      if (name.isEmpty || _looksLikePhone(name)) continue;
      _cacheContactName(c.wrytteUserId, name, c.avatarUrl);
      _cacheContactName(_matrixLocalpart(c.wrytteUserId), name, c.avatarUrl);
      for (final phone in c.phones) {
        _cacheContactName(phone, name, c.avatarUrl);
      }
    }
  }

  Future<void> _initialize() async {
    _currentUserId =
        widget.currentUserId.isNotEmpty
            ? widget.currentUserId
            : await AuthService.instance.getCurrentUserId() ?? '';

    if (_currentUserId.isEmpty) return;

    // Load the account-scoped deleted-room dismissal list before reading
    // SQLite. ChatService.connect() loads the same list later, but waiting for
    // that would allow a dismissed shell to flash during the first local paint.
    _dismissedDeletedGroupRoomIds = await _chat
        .dismissedDeletedGroupRoomIdsForOwner(_currentUserId);
    _dismissedDeletedGroupRoomIds = <String>{
      ..._dismissedDeletedGroupRoomIds,
      ...MatrixChatService.retiredTestGroupRoomIds,
    };
    await _chat.restoreCreatedGroupRoomIdsForOwner(_currentUserId);
    await _loadCachedRoomCategories();
    await _loadLocalRoomAvatarPaths();
    await _loadCachedPublicRoomDirectory();
    await _loadIdentityCacheFast();
    await _loadSavedContacts();
    await _loadLocalConversations();
    await _repairOfflineRoomCategories();
    if (mounted) setState(() => _initialCacheWarmup = false);

    // Phonebook matching is not required for the first paint. Deferring it
    // avoids competing with initial layout and Matrix restoration.
    unawaited(_runDeferredStartupEnrichment());

    // Subscribe to Matrix conversation stream
    _convSub = _chat.conversationsStream.listen(_queueConversationBatch);
    _contactsChangedSub = ContactService.contactsChanged.listen((ownerUserId) {
      if (ownerUserId.trim().toLowerCase() !=
          _currentUserId.trim().toLowerCase()) {
        return;
      }
      unawaited(_reloadContactsAndRepaint(reason: 'local contact changed'));
    });

    _chatConnectionSub = _chat.connectionStream.listen((connected) {
      if (connected) {
        unawaited(_restoreContactsAfterMatrixReady());
        unawaited(_cacheRoomAvatars(_suggestedGroups));
        unawaited(_loadSuggestedGroups());
      }
    });

    // Connect ChatService (idempotent) after local conversations are visible.
    try {
      await _chat.connect();
      await _retireTestGroupsFromAccount();
      unawaited(_restoreContactsAfterMatrixReady());
      unawaited(_cacheRoomAvatars(_suggestedGroups));
      unawaited(_loadSuggestedGroups());
    } catch (e) {
      debugPrint('[ConversationsScreen] chat connect skipped: $e');
    }

    // Retry enrichment when connectivity is restored
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet) {
        _retryEnrichment();
        unawaited(_loadSuggestedGroups());
      }
    });
  }

  Future<void> _retireTestGroupsFromAccount() async {
    final matrix = MatrixChatService.instance;
    final retired = MatrixChatService.retiredTestGroupRoomIds;

    // Persist the Matrix account-data tombstones in one request so these
    // disposable rooms remain suppressed across devices and reinstalls.
    await matrix.markPublicGroupsDeleted(
      retired.map((roomId) {
        final room = matrix.getRoomById(roomId);
        return MatrixPublicGroup(
          roomId: roomId,
          name: room?.name ?? 'Retired test group',
          canonicalAlias:
              room?.canonicalAlias.trim().isNotEmpty == true
                  ? room!.canonicalAlias
                  : null,
          memberCount: 0,
          worldReadable: false,
        );
      }),
    );

    for (final roomId in retired) {
      // Purge the SQLite row, messages and locally stored attachments first;
      // then remove the room from this Matrix account with leave + forget.
      await _chat.dismissDeletedGroupLocally(roomId);
      try {
        await matrix.leaveGroup(roomId);
      } catch (error) {
        apkLog(
          'Groups.cleanup',
          'test group leave/forget failed room_id="$roomId" error="$error"',
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _dismissedDeletedGroupRoomIds = <String>{
        ..._dismissedDeletedGroupRoomIds,
        ...retired,
      };
      _suggestedGroups = _suggestedGroups
          .where((group) => !retired.contains(group.roomId))
          .toList(growable: false);
    });
    apkLog(
      'Groups.cleanup',
      'retired test groups removed count=${retired.length}',
    );
  }

  String get _publicRoomDirectoryCacheKey =>
      'wrytte.public_room_directory.$_currentUserId';

  String get _roomCategoryCacheKey => 'wrytte.room_categories.$_currentUserId';

  String get _roomAvatarPathsCacheKey =>
      'wrytte.room_avatar_paths.$_currentUserId';

  String get _roomAvatarSourcesCacheKey =>
      'wrytte.room_avatar_sources.$_currentUserId';

  Future<void> _loadCachedRoomCategories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(_roomCategoryCacheKey);
      if (encoded == null || encoded.isEmpty) return;
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return;
      final categories = decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
      if (!mounted) return;
      _cachedRoomCategories = Map<String, String>.unmodifiable(categories);
      apkLog(
        'RoomCategories.local',
        'restored owner="$_currentUserId" rooms=${categories.length} '
            'channel_owned=${categories.values.where((v) => v == 'channel_owned').length} '
            'channel_subscribed=${categories.values.where((v) => v == 'channel_subscribed').length} '
            'channel_suggested=${categories.values.where((v) => v == 'channel_suggested').length} '
            'group_owned=${categories.values.where((v) => v == 'group_owned').length} '
            'group_joined=${categories.values.where((v) => v == 'group_joined').length} '
            'group_suggested=${categories.values.where((v) => v == 'group_suggested').length}',
      );
    } catch (error) {
      apkLog(
        'RoomCategories.local',
        'restore failed owner="$_currentUserId" error="$error"',
      );
    }
  }

  Future<void> _repairOfflineRoomCategories() async {
    if (_currentUserId.trim().isEmpty) return;
    final repaired = Map<String, String>.from(_cachedRoomCategories);
    final directoryById = <String, MatrixPublicGroup>{
      for (final room in _suggestedGroups) room.roomId: room,
    };
    final localRoomIds = <String>{};
    final repairedKinds = <String, String>{};

    for (final conversation in _conversations.where(
      _isDisplayableGroupConversation,
    )) {
      localRoomIds.add(conversation.id);
      final previous = repaired[conversation.id];
      final liveRoom = MatrixChatService.instance.getRoomById(conversation.id);
      final directoryRoom = directoryById[conversation.id];
      final isChannel =
          (liveRoom != null &&
              MatrixChatService.instance.isChannelRoom(liveRoom)) ||
          directoryRoom?.isChannel == true ||
          conversation.isChannelKind ||
          previous?.startsWith('channel_') == true;
      final owned =
          previous == 'channel_owned' ||
          previous == 'group_owned' ||
          _chat.isCreatedGroupRoom(conversation.id);
      repaired[conversation.id] =
          isChannel
              ? (owned ? 'channel_owned' : 'channel_subscribed')
              : (owned ? 'group_owned' : 'group_joined');
      repairedKinds[conversation.id] =
          isChannel ? ConversationKind.channel : ConversationKind.group;
    }

    for (final room in _suggestedGroups) {
      if (localRoomIds.contains(room.roomId)) continue;
      repaired[room.roomId] =
          _isSuggestedChannel(room) ? 'channel_suggested' : 'group_suggested';
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_roomCategoryCacheKey, jsonEncode(repaired));
    final correctedConversations = _conversations
        .map((conversation) {
          final kind = repairedKinds[conversation.id];
          if (kind == null || conversation.conversationKind == kind) {
            return conversation;
          }
          return conversation.copyWith(
            conversationKind: kind,
            otherUserId: conversation.id,
          );
        })
        .toList(growable: false);
    await ChatLocalDb.instance.saveConversations(correctedConversations);
    if (!mounted) return;
    setState(() {
      _cachedRoomCategories = Map<String, String>.unmodifiable(repaired);
      _conversations = correctedConversations;
    });
    apkLog(
      'RoomCategories.local',
      'offline repair owner="$_currentUserId" rooms=${repaired.length} '
          'channel_owned=${repaired.values.where((v) => v == 'channel_owned').length} '
          'channel_subscribed=${repaired.values.where((v) => v == 'channel_subscribed').length} '
          'channel_suggested=${repaired.values.where((v) => v == 'channel_suggested').length} '
          'group_owned=${repaired.values.where((v) => v == 'group_owned').length} '
          'group_joined=${repaired.values.where((v) => v == 'group_joined').length} '
          'group_suggested=${repaired.values.where((v) => v == 'group_suggested').length}',
    );
  }

  Future<void> _loadLocalRoomAvatarPaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(_roomAvatarPathsCacheKey);
      if (encoded == null || encoded.isEmpty) return;
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return;
      final encodedSources = prefs.getString(_roomAvatarSourcesCacheKey);
      final decodedSources =
          encodedSources == null || encodedSources.isEmpty
              ? const <String, dynamic>{}
              : jsonDecode(encodedSources);
      final paths = <String, String>{};
      final sources = <String, String>{};
      for (final entry in decoded.entries) {
        final roomId = entry.key.toString().trim();
        final path = entry.value.toString().trim();
        if (roomId.isNotEmpty && path.isNotEmpty && File(path).existsSync()) {
          paths[roomId] = path;
          if (decodedSources is Map) {
            final source = decodedSources[roomId]?.toString().trim() ?? '';
            if (source.isNotEmpty) sources[roomId] = source;
          }
        }
      }
      if (!mounted) return;
      _localRoomAvatarPaths = Map<String, String>.unmodifiable(paths);
      _localRoomAvatarSources = Map<String, String>.unmodifiable(sources);
      apkLog(
        'RoomAvatars.local',
        'restored owner="$_currentUserId" complete=${paths.length}',
      );
    } catch (error) {
      apkLog(
        'RoomAvatars.local',
        'restore failed owner="$_currentUserId" error="$error"',
      );
    }
  }

  Future<void> _cacheRoomAvatars(List<MatrixPublicGroup> discovered) async {
    final sources = <String, String>{
      for (final room in discovered)
        if (room.avatarUrl?.trim().isNotEmpty == true)
          room.roomId: room.avatarUrl!.trim(),
    };
    for (final conversation in _conversations.where(
      _isDisplayableGroupConversation,
    )) {
      final liveAvatar = _groupRoomAvatarUrl(
        MatrixChatService.instance.getRoomById(conversation.id),
      );
      final source =
          liveAvatar?.trim().isNotEmpty == true
              ? liveAvatar!.trim()
              : conversation.otherUserAvatar?.trim() ?? '';
      if (source.isNotEmpty) sources[conversation.id] = source;
    }

    final paths = Map<String, String>.from(_localRoomAvatarPaths);
    final cachedSources = Map<String, String>.from(_localRoomAvatarSources);
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(root.path, 'Wrytte Room Avatars'));
    await directory.create(recursive: true);

    for (final entry in sources.entries) {
      try {
        final existingPath = paths[entry.key]?.trim() ?? '';
        if (existingPath.isNotEmpty &&
            cachedSources[entry.key] == entry.value &&
            await File(existingPath).exists() &&
            await File(existingPath).length() > 0) {
          apkLog(
            'RoomAvatars.local',
            'state="reused" room_id="${entry.key}" '
                'local_path="$existingPath"',
          );
          continue;
        }
        var resolved = entry.value;
        if (resolved.startsWith('mxc://')) {
          final mxc = Uri.parse(resolved);
          final mediaId =
              mxc.pathSegments.isEmpty ? '' : mxc.pathSegments.join('/');
          if (mxc.host.isEmpty || mediaId.isEmpty) continue;
          final response = await MatrixClientService.instance.client.getContent(
            mxc.host,
            mediaId,
          );
          if (response.data.isEmpty) {
            throw StateError('Matrix avatar response was empty');
          }
          final extension = _avatarExtensionForContentType(
            response.contentType,
          );
          final target = File(
            p.join(
              directory.path,
              '${_stableRoomAvatarKey(entry.key)}$extension',
            ),
          );
          await target.writeAsBytes(response.data, flush: true);
          paths[entry.key] = target.path;
          cachedSources[entry.key] = entry.value;
          apkLog(
            'RoomAvatars.local',
            'state="complete" source="matrix" room_id="${entry.key}" '
                'bytes=${response.data.length} local_path="${target.path}"',
          );
          continue;
        } else if (resolved.startsWith('/')) {
          resolved = '${ApiService.baseUrl}$resolved';
        }
        if (!resolved.startsWith('http')) continue;
        final uri = Uri.tryParse(resolved);
        final isBackendAvatar =
            uri?.host == 'wryttedev.azurewebsites.net' ||
            uri?.host == 'wrytte.com';
        final backendToken =
            isBackendAvatar
                ? (AuthService.instance.cachedBackendToken?.trim().isNotEmpty ==
                        true
                    ? AuthService.instance.cachedBackendToken
                    : await AuthService.instance.getValidBackendToken())
                : null;
        final cached = await DefaultCacheManager().getSingleFile(
          resolved,
          headers:
              backendToken?.trim().isNotEmpty == true
                  ? {'Authorization': 'Bearer ${backendToken!.trim()}'}
                  : null,
        );
        final extension = p
            .extension(uri?.path ?? '')
            .replaceAll(RegExp(r'[^a-zA-Z0-9.]'), '');
        final target = File(
          p.join(
            directory.path,
            '${_stableRoomAvatarKey(entry.key)}'
            '${extension.isEmpty ? '.img' : extension}',
          ),
        );
        await cached.copy(target.path);
        paths[entry.key] = target.path;
        cachedSources[entry.key] = entry.value;
        apkLog(
          'RoomAvatars.local',
          'state="complete" source="backend" room_id="${entry.key}" '
              'bytes=${await target.length()} local_path="${target.path}"',
        );
      } catch (error) {
        apkLog(
          'RoomAvatars.local',
          'state="failed" room_id="${entry.key}" error="$error"',
        );
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_roomAvatarPathsCacheKey, jsonEncode(paths));
    await prefs.setString(
      _roomAvatarSourcesCacheKey,
      jsonEncode(cachedSources),
    );
    if (mounted) {
      setState(() {
        _localRoomAvatarPaths = Map<String, String>.unmodifiable(paths);
        _localRoomAvatarSources = Map<String, String>.unmodifiable(
          cachedSources,
        );
      });
    }
  }

  String _stableRoomAvatarKey(String roomId) {
    var hash = 0xcbf29ce484222325;
    for (final byte in roomId.codeUnits) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }

  String _avatarExtensionForContentType(String? contentType) {
    final type = contentType?.split(';').first.trim().toLowerCase() ?? '';
    return switch (type) {
      'image/png' => '.png',
      'image/webp' => '.webp',
      'image/gif' => '.gif',
      'image/bmp' => '.bmp',
      _ => '.jpg',
    };
  }

  Future<void> _saveRoomCategorySnapshot(
    List<MatrixPublicGroup> discovered,
  ) async {
    if (_currentUserId.trim().isEmpty) return;
    // Merge instead of replacing. A partial sync must never erase categories
    // that are required for a later offline launch.
    final categories = Map<String, String>.from(_cachedRoomCategories);
    final joinedIds =
        MatrixChatService.instance.rooms
            .where((room) => room.membership == mx.Membership.join)
            .map((room) => room.id)
            .toSet();

    for (final conversation in _conversations.where(
      _isDisplayableGroupConversation,
    )) {
      final liveRoom = MatrixChatService.instance.getRoomById(conversation.id);
      if (liveRoom == null && !joinedIds.contains(conversation.id)) {
        // The locally persisted row is still authoritative offline.
        final cached = categories[conversation.id];
        if (cached != null) continue;
      }
      final isChannel = _isChannelConversation(conversation);
      final owned = _isOwnGroupConversation(conversation);
      categories[conversation.id] =
          isChannel
              ? (owned ? 'channel_owned' : 'channel_subscribed')
              : (owned ? 'group_owned' : 'group_joined');
    }
    final localRoomIds = _conversations.map((room) => room.id).toSet();
    for (final room in discovered.where(
      (room) =>
          !joinedIds.contains(room.roomId) &&
          !localRoomIds.contains(room.roomId),
    )) {
      categories[room.roomId] =
          _isSuggestedChannel(room) ? 'channel_suggested' : 'group_suggested';
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_roomCategoryCacheKey, jsonEncode(categories));
    if (mounted) {
      setState(
        () =>
            _cachedRoomCategories = Map<String, String>.unmodifiable(
              categories,
            ),
      );
    }
    apkLog(
      'RoomCategories.local',
      'saved owner="$_currentUserId" rooms=${categories.length}',
    );
  }

  Future<void> _loadCachedPublicRoomDirectory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(_publicRoomDirectoryCacheKey);
      if (encoded == null || encoded.isEmpty) return;
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return;
      final groups = decoded
          .whereType<Map>()
          .map(
            (item) => MatrixPublicGroup.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .where((group) => group.roomId.trim().isNotEmpty)
          .where(
            (group) =>
                !_dismissedDeletedGroupRoomIds.contains(group.roomId) &&
                !MatrixChatService.retiredTestGroupRoomIds.contains(
                  group.roomId,
                ),
          )
          .toList(growable: false);
      if (!mounted) return;
      setState(() => _suggestedGroups = groups);
      apkLog(
        'PublicRooms.local',
        'restored owner="$_currentUserId" rooms=${groups.length} '
            'channels=${groups.where((group) => group.isChannel).length} '
            'groups=${groups.where((group) => !group.isChannel).length}',
      );
    } catch (error) {
      apkLog(
        'PublicRooms.local',
        'restore failed owner="$_currentUserId" error="$error"',
      );
    }
  }

  Future<void> _saveCachedPublicRoomDirectory(
    List<MatrixPublicGroup> groups,
  ) async {
    if (_currentUserId.trim().isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _publicRoomDirectoryCacheKey,
        jsonEncode(groups.map((group) => group.toJson()).toList()),
      );
      apkLog(
        'PublicRooms.local',
        'saved owner="$_currentUserId" rooms=${groups.length}',
      );
    } catch (error) {
      apkLog(
        'PublicRooms.local',
        'save failed owner="$_currentUserId" error="$error"',
      );
    }
  }

  Future<void> _loadSuggestedGroups({bool force = false}) async {
    if (_loadingSuggestedGroups) return;
    final now = DateTime.now();
    final lastLoad = _lastSuggestedGroupsLoadAt;
    if (!force &&
        lastLoad != null &&
        now.difference(lastLoad) < _suggestedGroupsRefreshInterval) {
      return;
    }
    _lastSuggestedGroupsLoadAt = now;
    _loadingSuggestedGroups = true;
    try {
      final discovered = await MatrixChatService.instance.fetchPublicGroups();
      if (discovered.isEmpty && _suggestedGroups.isNotEmpty) {
        apkLog(
          'SuggestedPreview',
          'empty discovery ignored; retained cached rooms=${_suggestedGroups.length}',
        );
        return;
      }
      final groups = await Future.wait(
        discovered
            .where(
              (group) => !_dismissedDeletedGroupRoomIds.contains(group.roomId),
            )
            .map((group) async {
              final profile = await _chat.loadSuggestedRoomProfile(
                group.roomId,
              );
              return profile == null ? group : group.copyWithProfile(profile);
            }),
      );
      if (!mounted) return;
      setState(() => _suggestedGroups = groups);
      await _saveCachedPublicRoomDirectory(groups);
      await _saveRoomCategorySnapshot(groups);
      unawaited(_cacheRoomAvatars(groups));
      unawaited(_chat.auditDiscoveredChannelCacheCoverage(groups));
      unawaited(_chat.auditDiscoveredGroupCacheCoverage(groups));
      apkLog(
        'SuggestedPreview',
        'discovery complete groups=${groups.length} '
            'world_readable=${groups.where((group) => group.worldReadable).length}',
      );
      unawaited(
        _warmSuggestedGroupPreviews(_previewEligibleSuggestedGroups(groups)),
      );
    } finally {
      _loadingSuggestedGroups = false;
    }
  }

  Future<void> _warmSuggestedGroupPreviews(
    List<MatrixPublicGroup> groups,
  ) async {
    // Dendrite's public-room directory can report world_readable=false even
    // when authoritative room state permits previewing. Attempt every public
    // suggestion and let the room history endpoint enforce access.
    final previewable = groups.toList(growable: false);
    // A room can require many history pages. Warming rooms sequentially keeps
    // those requests below the homeserver rate limit and serializes removals.
    for (final group in previewable) {
      final fresh = await ChatLocalDb.instance.isSuggestedPreviewFresh(
        group.roomId,
      );
      if (!fresh) {
        await _chat.fetchPublicGroupPreview(roomId: group.roomId);
      } else {
        apkLog(
          'SuggestedPreview',
          'warm skipped fresh room_id="${group.roomId}"',
        );
      }
      final profile = await _chat.loadSuggestedRoomProfile(group.roomId);
      if (profile != null && mounted) {
        setState(() {
          _suggestedGroups = _suggestedGroups
              .map(
                (candidate) =>
                    candidate.roomId == group.roomId
                        ? candidate.copyWithProfile(profile)
                        : candidate,
              )
              .toList(growable: false);
        });
      }
      final complete = await ChatLocalDb.instance.isSuggestedPreviewComplete(
        group.roomId,
      );
      if (!complete) continue;
      final members = await _chat.loadSuggestedPreviewMembers(group.roomId);
      final joinedCount =
          members
              .where(
                (member) =>
                    member['membership']?.toString().toLowerCase() == 'join',
              )
              .length;
      if (joinedCount > 0) continue;

      await MatrixChatService.instance.dismissPublicGroup(
        roomId: group.roomId,
        canonicalAlias: group.canonicalAlias,
      );
      if (!mounted) return;
      setState(() {
        _suggestedGroups = _suggestedGroups
            .where((candidate) => candidate.roomId != group.roomId)
            .toList(growable: false);
      });
      apkLog(
        'SuggestedPreview',
        'removed zero-member suggestion room_id="${group.roomId}"',
      );
    }
    await _saveCachedPublicRoomDirectory(_suggestedGroups);
    unawaited(_cacheRoomAvatars(_suggestedGroups));
    await _chat.auditDiscoveredChannelCacheCoverage(_suggestedGroups);
    await _chat.auditDiscoveredGroupCacheCoverage(_suggestedGroups);
  }

  List<MatrixPublicGroup> _previewEligibleSuggestedGroups(
    List<MatrixPublicGroup> groups,
  ) {
    final allGroups =
        _conversations.where(_isDisplayableGroupConversation).toList();
    final createdIds = _chat.createdGroupRoomIds;
    final joinedIds = {
      ...allGroups.map((group) => group.id),
      ..._joinedMatrixGroupRoomIds(),
      ...createdIds,
    };
    final joinedAliases = _joinedMatrixGroupAliases();
    final localGroupNames = allGroups.map(_normalizedGroupTitle).toSet();
    return groups
        .where(
          (group) =>
              group.memberCount > 0 &&
              !MatrixChatService.instance.isPublicGroupDismissed(group) &&
              !_chat.isConversationDeleted(group.roomId) &&
              !joinedIds.contains(group.roomId) &&
              !_suggestedAliasMatchesJoined(group, joinedAliases) &&
              !_suggestedNameMatchesLocalGroup(group, localGroupNames),
        )
        .toList(growable: false);
  }

  void _queueConversationBatch(List<ChatConversation> incoming) {
    _pendingConversationBatch = incoming;
    _conversationBatchTimer?.cancel();
    _conversationBatchTimer = Timer(const Duration(milliseconds: 160), () {
      unawaited(_processQueuedConversationBatch());
    });
  }

  Future<void> _processQueuedConversationBatch() async {
    if (_conversationBatchInFlight) return;
    _conversationBatchInFlight = true;

    try {
      while (mounted && _pendingConversationBatch != null) {
        final incoming = _pendingConversationBatch!;
        _pendingConversationBatch = null;

        final local = await ChatLocalDb.instance.loadConversations();
        final mergedCache = _mergeConversationLists(local, incoming);
        final rows = _enrichSavedContactNames(
          _realConversationRows(mergedCache),
        );
        final version = ++_conversationPaintVersion;
        final visible = await _prepareConversationsForFirstPaint(rows, version);
        if (!mounted || version != _conversationPaintVersion) continue;

        setState(() => _conversations = visible);
        _notifyUnread(_conversations);
      }
    } finally {
      _conversationBatchInFlight = false;
      if (mounted && _pendingConversationBatch != null) {
        _conversationBatchTimer?.cancel();
        _conversationBatchTimer = Timer(const Duration(milliseconds: 80), () {
          unawaited(_processQueuedConversationBatch());
        });
      }
    }
  }

  Future<void> _repaintConversationsWithCurrentContactData() async {
    if (!mounted || _conversations.isEmpty) return;
    final rows = _enrichSavedContactNames(
      _realConversationRows(_conversations),
    );
    final visible = await _enrichNames(rows);
    await _publishPreparedConversations(visible);
  }

  Future<void> _loadLocalConversations() async {
    try {
      final local = await ChatLocalDb.instance.loadConversations();
      if (!mounted) return;
      final initialRows = _mergeConversationLists(
        local,
        _chat.cachedConversationsSnapshot,
      );
      final withContactRows = _enrichSavedContactNames(
        _realConversationRows(initialRows),
      );
      if (withContactRows.isEmpty && _initialCacheWarmup) {
        return;
      }

      final version = ++_conversationPaintVersion;
      final visible = await _prepareConversationsForFirstPaint(
        withContactRows,
        version,
      );
      if (!mounted || version != _conversationPaintVersion) return;
      setState(() => _conversations = visible);
      _notifyUnread(_conversations);

      _prewarmVisibleMessages(visible);
    } catch (e) {
      debugPrint('[ConversationsScreen] local conversation load error: $e');
    }
  }

  Future<void> _loadIdentityCacheFast() async {
    try {
      await _loadIdentityCache();
    } catch (e) {
      debugPrint('[ConversationsScreen] initial identity cache skipped: $e');
    }
  }

  Future<void> _runDeferredStartupEnrichment() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    await _loadPhonebookIdentitiesAndRefresh();
  }

  void _prewarmVisibleMessages(List<ChatConversation> conversations) {
    for (final conversation in conversations) {
      if (_chat.cachedMessagesFor(conversation.id).isNotEmpty) continue;
      unawaited(_chat.loadCachedMessages(conversation.id));
    }
  }

  Future<void> _loadPhonebookIdentitiesAndRefresh() async {
    try {
      await ContactService().getWrytteContactsOptimized();
      await _loadIdentityCache();
      final rows = _enrichSavedContactNames(_conversations);
      final enriched = await _enrichNames(rows);
      await _publishPreparedConversations(enriched);
    } catch (e) {
      debugPrint('[ConversationsScreen] phone identity refresh skipped: $e');
    }
  }

  // ===========================================================================
  //  LOAD SAVED CONTACTS
  //  Reads contacts the user explicitly saved (savedBy == currentUserId).
  //  Populates _contactNameCache keyed by phone digits for O(1) lookup.
  // ===========================================================================

  Future<void> _loadSavedContacts({bool refreshBackend = true}) async {
    try {
      final contacts = await _loadImmediateContactSource();
      _savedContacts = contacts;
      await _rebuildContactNameCaches(contacts);

      debugPrint(
        '[ConversationsScreen] loaded ${_contactNameCache.length} immediate contact names',
      );

      if (refreshBackend) {
        unawaited(_refreshContactSourceInBackground());
      }
    } catch (e) {
      debugPrint('[ConversationsScreen] _loadSavedContacts error: $e');
    }
  }

  Future<List<Contact>> _loadImmediateContactSource() async {
    final saved = await ContactLocalDb.loadSavedContacts(
      ownerUserId: _currentUserId,
    );
    if (saved.isNotEmpty) {
      return _sortContacts(saved);
    }

    return const [];
  }

  Future<void> _refreshContactSourceInBackground() async {
    try {
      final contacts = await ContactService().getMatrixContactsCached(
        _currentUserId,
      );
      if (contacts.isEmpty || !mounted) return;
      _savedContacts = _sortContacts(contacts);
      await _rebuildContactNameCaches(_savedContacts);
      final rows = _enrichSavedContactNames(
        _realConversationRows(_conversations),
      );
      final enriched = await _enrichNames(rows);
      await _publishPreparedConversations(enriched);
    } catch (e) {
      debugPrint(
        '[ConversationsScreen] background contact refresh skipped: $e',
      );
    }
  }

  Future<void> _restoreContactsAfterMatrixReady() async {
    final pending = _contactRestoreFuture;
    if (pending != null) return pending;
    final future = _restoreContactsAfterMatrixReadyInternal();
    _contactRestoreFuture = future;
    try {
      await future;
    } finally {
      if (identical(_contactRestoreFuture, future)) {
        _contactRestoreFuture = null;
      }
    }
  }

  Future<void> _restoreContactsAfterMatrixReadyInternal() async {
    try {
      final contacts = await ContactService().getMatrixContactsCached(
        _currentUserId,
      );
      if (contacts.isEmpty || !mounted) return;
      _savedContacts = _sortContacts(contacts);
      await _rebuildContactNameCaches(_savedContacts);
      await _repaintConversationsWithCurrentContactData();
    } catch (e) {
      debugPrint('[ConversationsScreen] contact restore skipped: $e');
    }
  }

  List<Contact> _sortContacts(List<Contact> contacts) {
    return List<Contact>.from(contacts)
      ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
  }

  Future<void> _rebuildContactNameCaches(List<Contact> contacts) async {
    // Clear existing cache before reloading so removed/renamed contacts
    // don't linger.
    _contactNameCache.clear();
    _contactAvatarCache.clear();

    for (final c in contacts) {
      final name = c.displayName ?? '';
      // Only cache real human names — skip if it looks like a phone number.
      if (name.isEmpty || _looksLikePhone(name)) continue;

      _cacheContactName(c.wrytteUserId, name, c.avatarUrl);
      _cacheContactName(_matrixLocalpart(c.wrytteUserId), name, c.avatarUrl);
      if (c.wrytteUserId != null && c.wrytteUserId!.trim().isNotEmpty) {
        await ContactIdentityCache.instance.upsert(
          ownerUserId: _currentUserId,
          matrixUserId: c.wrytteUserId!,
          phone: c.primaryPhone,
          savedName: name,
          avatarUrl: c.avatarUrl,
        );
      }

      for (final phone in c.phones) {
        _cacheContactName(phone, name, c.avatarUrl);
      }
    }
    await _loadIdentityCache();
  }

  Future<void> _loadIdentityCache() async {
    _identityCache
      ..clear()
      ..addAll(
        await ContactIdentityCache.instance.loadAll(
          ownerUserId: _currentUserId,
        ),
      );
  }

  // ===========================================================================
  //  ENRICHMENT
  //
  //  Pass 1 — saved contact names (ALWAYS applied, even over Matrix displayname).
  //    Matrix displayname is set at registration, not the
  //    local user's chosen contact name.
  //
  // ===========================================================================

  Future<List<ChatConversation>> _enrichNames(
    List<ChatConversation> convs,
  ) async {
    final afterSavedContacts = _enrichSavedContactNames(convs);

    // ── Pass 2: public backend profile fills sender avatar/name for "Everyone"
    // visibility. Saved contact names stay above public names, but the avatar
    // should still show even when the receiver has not saved the sender.
    //final enriched = <ChatConversation>[];

    /** 
    for (final conv in afterSavedContacts) {
      enriched.add(await _enrichConversationFromPublicProfile(conv));
    }
    **/

    return Future.wait(
      afterSavedContacts.map(
        (conv) => _enrichConversationFromPublicProfile(conv),
      ),
    );
  }

  Future<void> _publishPreparedConversations(
    List<ChatConversation> conversations,
  ) async {
    if (!mounted) return;
    final refreshVersion = ++_conversationRefreshVersion;
    var rows = _enrichSavedContactNames(_realConversationRows(conversations));
    if (_hasRowsMissingStableIdentity(rows)) {
      rows = await _enrichNames(rows);
    }
    unawaited(_precacheConversationAvatars(rows));
    if (!mounted || refreshVersion != _conversationRefreshVersion) return;
    setState(() => _conversations = rows);
    _notifyUnread(_conversations);
  }

  Future<List<ChatConversation>> _prepareConversationsForFirstPaint(
    List<ChatConversation> convs,
    int version,
  ) async {
    var withSavedContacts = _enrichSavedContactNames(convs);
    if (_hasRowsMissingStableIdentity(withSavedContacts)) {
      withSavedContacts = await _enrichNames(withSavedContacts);
    }
    unawaited(_precacheInitialConversationAvatars(withSavedContacts));
    return withSavedContacts;
  }

  Future<void> _precacheInitialConversationAvatars(
    List<ChatConversation> conversations,
  ) async {
    try {
      await _precacheConversationAvatars(conversations);
    } catch (e) {
      debugPrint('[ConversationsScreen] initial avatar batch skipped: $e');
    }
  }

  bool _hasRowsMissingStableIdentity(List<ChatConversation> convs) {
    for (final conv in convs) {
      if (_isGroupConversation(conv)) continue;
      final contactKey = _contactKeyForConversation(conv);
      final cachedPublicName = _cachedPublicNameForConversation(conv);
      final identityName = _cleanHumanName(
        _identityForConversation(conv)?.profileName,
      );
      final hasStableName =
          contactKey != null ||
          (cachedPublicName != null && cachedPublicName.isNotEmpty) ||
          identityName.isNotEmpty ||
          _conversationHasPhoneLabel(conv);
      if (!hasStableName) return true;
      final avatar = _avatarForConversation(conv);
      if ((avatar ?? '').trim().isEmpty) return true;
    }
    return false;
  }

  bool _conversationHasPhoneLabel(ChatConversation conv) {
    final phone = _fallbackPhoneForConversation(conv);
    if (phone.isNotEmpty) return true;

    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      if (_phoneFromIdentifier(candidate).isNotEmpty) return true;
    }
    return false;
  }

  Future<void> _precacheConversationAvatars(
    List<ChatConversation> conversations,
  ) async {
    if (!mounted) return;
    final token =
        AuthService.instance.cachedBackendToken ??
        await AuthService.instance.getValidBackendToken();
    final seen = <String>{};
    final futures = <Future<void>>[];

    for (final conversation in conversations) {
      final rawAvatar = _avatarForConversation(conversation);
      final url = _resolveAvatarUrl(rawAvatar);
      if (url.isEmpty || !seen.add(url)) continue;
      futures.add(
        _warmAvatarImage(
          CachedNetworkImageProvider(
            url,
            headers: _avatarAuthHeaders(url, token, rawUrl: rawAvatar),
          ),
        ).catchError((e) {
          debugPrint(
            '[ConversationsScreen] avatar precache skipped url="$url" error=$e',
          );
        }),
      );
    }

    if (futures.isEmpty) return;
    await Future.wait(futures);
  }

  Future<void> _warmAvatarImage(ImageProvider provider) {
    final completer = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, __) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  String _resolveAvatarUrl(String? raw) {
    final url = raw?.trim() ?? '';
    if (url.isEmpty) return '';
    if (url.startsWith('mxc://')) return _resolveMxcAvatarUrl(url);
    if (url.startsWith('/')) return '${ApiService.baseUrl}$url';
    return url;
  }

  String _resolveMxcAvatarUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.isScheme('mxc')) return '';
    final mediaId = uri.pathSegments.join('/');
    if (uri.host.isEmpty || mediaId.isEmpty) return '';
    final homeserver = Uri.tryParse(MatrixConfig.homeserver);
    if (homeserver == null || !homeserver.hasScheme) return '';
    return homeserver
        .resolve(
          '/_matrix/media/v3/download/'
          '${Uri.encodeComponent(uri.host)}/'
          '${Uri.encodeComponent(mediaId)}',
        )
        .toString();
  }

  Map<String, String>? _avatarAuthHeaders(
    String url,
    String? token, {
    String? rawUrl,
  }) {
    if (rawUrl?.trim().startsWith('mxc://') == true) {
      final matrixToken =
          MatrixClientService.instance.client.accessToken?.trim() ?? '';
      return matrixToken.isEmpty
          ? null
          : {'Authorization': 'Bearer $matrixToken'};
    }
    final clean = token?.trim() ?? '';
    if (clean.isEmpty) return null;
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final isWrytteImage =
        url.startsWith('${ApiService.baseUrl}/usrimg/') ||
        url.startsWith('/usrimg/') ||
        host == 'wryttedev.azurewebsites.net' ||
        host == 'wrytte.com';
    if (!isWrytteImage) return null;
    return {'Authorization': 'Bearer $clean'};
  }

  List<ChatConversation> _enrichSavedContactNames(
    List<ChatConversation> convs,
  ) {
    final deduped = _dedupeLocalPlaceholders(_realConversationRows(convs));

    // Saved contact names always win. Matrix displayname is the registered
    // profile name, not necessarily this user's saved contact label.
    final enriched =
        deduped.map((c) {
          if (_isGroupConversation(c)) {
            final groupTitle = _conversationTitle(c);
            return c.copyWith(
              otherUserName: groupTitle.trim().isEmpty ? 'Group' : groupTitle,
              otherUserAvatar: _preferredAvatarForConversation(c, null),
            );
          }
          final title = _conversationTitle(c);
          final contactKey = _contactKeyForConversation(c);
          final fallbackTitle = _fallbackConversationTitle(c);
          return c.copyWith(
            otherUserName: title.trim().isEmpty ? fallbackTitle : title,
            otherUserAvatar: _preferredAvatarForConversation(c, contactKey),
          );
        }).toList();

    return _dedupePeerConversations(enriched);
  }

  List<ChatConversation> _mergeConversationLists(
    List<ChatConversation> cached,
    List<ChatConversation> incoming,
  ) {
    final byId = <String, ChatConversation>{
      for (final conversation in cached) conversation.id: conversation,
    };

    for (final conversation in incoming) {
      final existing = byId[conversation.id];
      byId[conversation.id] =
          existing == null
              ? conversation
              : _preferRicherConversation(existing, conversation);
    }

    final merged =
        byId.values.toList()
          ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    return merged;
  }

  List<ChatConversation> _realConversationRows(
    List<ChatConversation> conversations,
  ) {
    return conversations.where((conversation) {
      if (_dismissedDeletedGroupRoomIds.contains(conversation.id)) {
        return false;
      }
      // Saving or merely opening a contact must not create a visible chat
      // row. Direct chats appear after their first sent/received message.
      if (!_isGroupConversation(conversation) &&
          conversation.lastMessage.trim().isEmpty) {
        return false;
      }
      return true;
    }).toList();
  }

  ChatConversation _preferRicherConversation(
    ChatConversation cached,
    ChatConversation incoming,
  ) {
    final incomingHasMessage = incoming.lastMessage.trim().isNotEmpty;
    final cachedHasMessage = cached.lastMessage.trim().isNotEmpty;
    final unreadCount = cached.unreadCount == 0 ? 0 : incoming.unreadCount;
    if (!incomingHasMessage && cachedHasMessage) {
      return cached.copyWith(
        unreadCount: unreadCount,
        otherUserName: incoming.otherUserName ?? cached.otherUserName,
        otherUserAvatar:
            cached.otherUserAvatar?.trim().isNotEmpty == true
                ? cached.otherUserAvatar
                : incoming.otherUserAvatar,
      );
    }
    return incoming.copyWith(
      unreadCount: unreadCount,
      otherUserName: incoming.otherUserName ?? cached.otherUserName,
      otherUserAvatar:
          cached.otherUserAvatar?.trim().isNotEmpty == true
              ? cached.otherUserAvatar
              : incoming.otherUserAvatar,
    );
  }

  Future<ChatConversation> _enrichConversationFromPublicProfile(
    ChatConversation conv,
  ) async {
    if (_isGroupConversation(conv)) return conv;
    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final profileUid =
        _profileUidForConversation(conv) ??
        await _profileUidFromPhone(fallbackPhone);
    if (profileUid == null ||
        profileUid.trim().startsWith('!') ||
        profileUid.trim().startsWith('@!')) {
      return conv;
    }

    final profile = await UserProfileService.instance.getProfileByUid(
      profileUid,
      phone: fallbackPhone,
      forceRefresh: false,
    );
    final matrixProfile = await _loadMatrixProfile(profileUid);
    if (profile == null && matrixProfile == null) return conv;

    final contactKey = _contactKeyForConversation(conv);
    var contactName =
        contactKey == null
            ? ''
            : _cleanHumanName(_contactNameCache[contactKey]);
    final contactAvatar = _safeDirectAvatarUrl(
      contactKey == null ? null : _contactAvatarCache[contactKey],
    );
    final phone = _fallbackPhoneForConversation(conv);
    final name =
        contactName.isNotEmpty
            ? contactName
            : phone.isNotEmpty
            ? _formatPhone(phone)
            : '';
    final existingAvatar = _safeDirectAvatarUrl(conv.otherUserAvatar);
    final identityAvatar = _safeDirectAvatarUrl(
      _identityForConversation(conv)?.avatarUrl,
    );
    final profileAvatar = _safeDirectAvatarUrl(
      profile?.hasProfileImage == true ? profile!.profileImage : null,
    );
    final matrixAvatar = _safeDirectAvatarUrl(matrixProfile?.$2);
    final avatar =
        contactAvatar ??
        profileAvatar ??
        matrixAvatar ??
        existingAvatar ??
        identityAvatar;
    if ((avatar ?? '').trim().isNotEmpty &&
        avatar?.trim() != conv.otherUserAvatar?.trim()) {
      unawaited(
        AvatarPreloadService.replace(
          oldUrl: conv.otherUserAvatar,
          newUrl: avatar,
        ),
      );
    }
    final refreshedSavedContact =
        profile == null
            ? null
            : await ContactLocalDb.refreshPublicProfileFields(
              ownerUserId: _currentUserId,
              wrytteUserId: profileUid,
              phone: profile.phone.isNotEmpty ? profile.phone : phone,
              avatarUrl: avatar,
              bio: profile.bio,
            );
    if (refreshedSavedContact != null) {
      _cacheContactName(
        refreshedSavedContact.wrytteUserId,
        refreshedSavedContact.formattedName,
        refreshedSavedContact.avatarUrl,
      );
      for (final savedPhone in refreshedSavedContact.phones) {
        _cacheContactName(
          savedPhone,
          refreshedSavedContact.formattedName,
          refreshedSavedContact.avatarUrl,
        );
      }
      contactName = _cleanHumanName(refreshedSavedContact.formattedName);
    }
    final resolvedName =
        contactName.isNotEmpty
            ? contactName
            : phone.isNotEmpty
            ? _formatPhone(phone)
            : name;
    final enriched = conv.copyWith(
      otherUserName: resolvedName,
      otherUserAvatar: avatar,
    );
    apkLog(
      'Identity.display',
      'surface="chat_list" user_id="${_matrixLocalpart(profileUid) ?? profileUid}" '
          'saved=${contactName.isNotEmpty} profile="${contactName.isNotEmpty ? 'profile2' : 'profile1'}" '
          'name_source="${contactName.isNotEmpty ? 'saved_contact' : 'phone'}" '
          'name="$resolvedName" phone="${profile?.phone ?? phone}" '
          'avatar=${(avatar ?? '').trim().isNotEmpty} avatar_url="${avatar ?? ''}" '
          'bio=${profile?.bio.trim().isNotEmpty == true}',
    );

    if (resolvedName.trim().isNotEmpty || (avatar ?? '').trim().isNotEmpty) {
      await ChatLocalDb.instance.updateConversationUserInfo(
        conversationId: conv.id,
        name: resolvedName.trim(),
        avatar: avatar,
        clearAvatar:
            avatar == null &&
            ContactAvatarSanitizer.sanitizeAvatarUrl(conv.otherUserAvatar) ==
                null &&
            (conv.otherUserAvatar?.trim().isNotEmpty ?? false),
      );
      final identity = ContactIdentity(
        matrixUserId: profileUid,
        phone: profile?.phone ?? phone,
        profileName:
            _cleanHumanName(profile?.displayName).isNotEmpty
                ? _cleanHumanName(profile?.displayName)
                : _cleanHumanName(matrixProfile?.$1).isNotEmpty
                ? _cleanHumanName(matrixProfile?.$1)
                : null,
        avatarUrl: avatar,
        bio: profile?.bio,
      );
      _cacheIdentity(identity);
      await ContactIdentityCache.instance.upsert(
        ownerUserId: _currentUserId,
        matrixUserId: profileUid,
        phone: profile?.phone ?? phone,
        profileName:
            _cleanHumanName(profile?.displayName).isNotEmpty
                ? _cleanHumanName(profile?.displayName)
                : _cleanHumanName(matrixProfile?.$1).isNotEmpty
                ? _cleanHumanName(matrixProfile?.$1)
                : null,
        avatarUrl: avatar,
        bio: profile?.bio,
      );
    }
    return enriched;
  }

  Future<String?> _profileUidFromPhone(String phone) async {
    final cleanPhone = _normalizePhone(phone);
    if (cleanPhone.isEmpty) return null;
    final digits = cleanPhone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length < 7) return null;

    try {
      final result = await _userSearchService.searchUsersByPhones(
        phoneNumbersC: '$digits|$cleanPhone',
        token: '',
      );
      final resolved =
          result[cleanPhone] ??
          result[digits] ??
          result[cleanPhone.replaceFirst('+', '')];
      if (resolved == null ||
          resolved.isEmpty ||
          resolved == UserSearchService.registeredWithoutMatrixId) {
        return null;
      }
      final localpart = _matrixLocalpart(resolved) ?? resolved;
      return resolved.startsWith('@')
          ? resolved
          : '@$localpart:${MatrixConfig.serverName}';
    } catch (e) {
      debugPrint(
        '[ConversationsScreen] profile phone lookup skipped phone="$cleanPhone": $e',
      );
      return null;
    }
  }

  Future<(String?, String?)?> _loadMatrixProfile(String uid) async {
    if (_matrixProfileCache.containsKey(uid)) return _matrixProfileCache[uid];
    try {
      if (!MatrixClientService.instance.isLoggedIn) return null;
      final matrixUserId =
          uid.startsWith('@') ? uid : '@$uid:${MatrixConfig.serverName}';
      final profile = await MatrixClientService.instance.client
          .getProfileFromUserId(
            matrixUserId,
            timeout: const Duration(seconds: 2),
          );
      final result = (profile.displayName, profile.avatarUrl?.toString());
      _matrixProfileCache[uid] = result;
      return result;
    } catch (_) {
      _matrixProfileCache[uid] = null;
      return null;
    }
  }

  String? _profileUidForConversation(ChatConversation conv) {
    for (final candidate in [
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final value = candidate.trim();
      if (value.isEmpty || _isCurrentUserIdentifier(value)) continue;
      if (value.startsWith('!') || value.startsWith('@!')) continue;
      final localpart = _matrixLocalpart(value) ?? value;
      if (localpart.isEmpty) continue;
      return value.startsWith('@')
          ? value
          : '@$localpart:${MatrixConfig.serverName}';
    }
    return null;
  }

  String _fallbackPhoneForConversation(ChatConversation conv) {
    for (final candidate in [
      _identityForConversation(conv)?.phone,
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final phone = _extractPhone(candidate);
      if (phone.isNotEmpty) return phone;
    }
    return '';
  }

  String _fallbackConversationTitle(ChatConversation conv) {
    if (_isGroupConversation(conv)) {
      final room = MatrixChatService.instance.getRoomById(conv.id);
      final roomName = _cleanGroupName(room?.name, room: room);
      if (roomName.isNotEmpty) return roomName;
      final alias = _cleanGroupName(_displayGroupAlias(room), room: room);
      if (alias.isNotEmpty) return alias;
      final groupName = _cleanGroupName(conv.otherUserName, room: room);
      if (groupName.isNotEmpty) return groupName;
      return 'Group';
    }
    final phone = _fallbackPhoneForConversation(conv);
    if (phone.isNotEmpty) return _formatPhone(phone);

    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final name = _cleanHumanName(candidate);
      if (name.isNotEmpty) return name;
    }

    return _fallbackConversationIdentifier(conv);
  }

  String _fallbackConversationIdentifier(ChatConversation conv) {
    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final value = candidate?.trim() ?? '';
      if (value.isEmpty || _isCurrentUserIdentifier(value)) continue;
      if (value.startsWith('!') || value.startsWith('@!')) continue;
      final localpart = _matrixLocalpart(value) ?? value;
      if (localpart.trim().isNotEmpty) return localpart.trim();
    }
    return conv.id;
  }

  String _conversationTitle(ChatConversation conv) {
    if (_isGroupConversation(conv)) {
      final room = MatrixChatService.instance.getRoomById(conv.id);
      final deletedName =
          room
              ?.getState(ChatService.groupDeletedStateType)
              ?.content[ChatService.groupDeletedNameKey]
              ?.toString()
              .trim() ??
          '';
      if (deletedName.isNotEmpty) return deletedName;
      final roomName = _cleanGroupName(room?.name, room: room);
      if (roomName.isNotEmpty) return roomName;
      final alias = _cleanGroupName(_displayGroupAlias(room), room: room);
      if (alias.isNotEmpty) return alias;
      final groupName = _cleanGroupName(conv.otherUserName, room: room);
      if (groupName.isNotEmpty) return groupName;
      return 'Group';
    }
    final identity = _identityForConversation(conv);
    final contactKey = _contactKeyForConversation(conv);

    // Saved contact labels are local user intent and always win.
    final savedIdentityName = _cleanHumanName(identity?.savedName);
    if (savedIdentityName.isNotEmpty) return savedIdentityName;

    if (contactKey != null) {
      final contactName = _cleanHumanName(_contactNameCache[contactKey]);
      if (contactName.isNotEmpty) return contactName;
    }

    final identityPhone = _extractPhone(identity?.phone);
    if (identityPhone.isNotEmpty) return _formatPhone(identityPhone);

    if (contactKey != null) {
      final phone = _extractPhone(contactKey);
      if (phone.isNotEmpty) return _formatPhone(phone);
    }

    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final phone = _phoneFromIdentifier(candidate);
      if (phone.isNotEmpty) return _formatPhone(phone);
    }

    return '';
  }

  bool _isGroupConversation(ChatConversation conv) {
    // Deleted-room identity is authoritative. It must be evaluated before an
    // explicit cached kind because older rows may have been mis-stamped as DM.
    if (conv.lastMessageType == ChatService.groupDeletedMessageType) {
      return true;
    }
    if (ChatService.isGroupDeletedPreview(conv.lastMessage)) return true;
    if (conv.deletedAt != null && conv.id.startsWith('!')) return true;
    if (_cachedRoomCategories.containsKey(conv.id)) return true;
    if (conv.hasExplicitKind) {
      return conv.isGroupKind || conv.isChannelKind;
    }
    if (_chat.isCreatedGroupRoom(conv.id)) return true;

    final explicitlyStoredGroup =
        (conv.lastMessageType == 'group' ||
            conv.lastMessageType == ChatService.groupDeletedMessageType) &&
        conv.id.startsWith('!') &&
        conv.otherUserId == conv.id;
    if (explicitlyStoredGroup) return true;

    if (MatrixClientService.instance.isInitialized) {
      final room = MatrixChatService.instance.getRoomById(conv.id);
      if (room != null) {
        if (MatrixChatService.instance.isMatrixGroupRoom(room)) return true;
        if (room.isDirectChat ||
            MatrixChatService.instance.looksLikeUnmarkedDirectRoom(room)) {
          return false;
        }
        return conv.lastMessageType == 'group' &&
            conv.otherUserId == conv.id &&
            _cleanHumanName(conv.otherUserName).isNotEmpty &&
            _cleanHumanName(conv.otherUserName) != 'Group';
      }
    }
    return false;
  }

  bool _isDisplayableGroupConversation(ChatConversation conv) {
    if (_groupExitHiddenRoomIds.contains(conv.id)) return false;
    if (!_isGroupConversation(conv)) return false;
    final title = _cleanHumanName(_conversationTitle(conv));
    final normalized = title.toLowerCase();
    if (title.isEmpty || normalized == 'empty chat' || normalized == 'group') {
      return false;
    }
    return true;
  }

  ContactIdentity? _identityForConversation(ChatConversation conv) {
    for (final key in _conversationKeys(conv)) {
      final localpart = _matrixLocalpart(key)?.toLowerCase();
      if (localpart != null && _identityCache.containsKey(localpart)) {
        return _identityCache[localpart];
      }
    }
    return null;
  }

  String? _avatarForConversation(ChatConversation conv) {
    if (_isGroupConversation(conv)) {
      if (_isChannelConversation(conv)) {
        final room = MatrixChatService.instance.getRoomById(conv.id);
        final rawAvatar =
            room?.getState(mx.EventTypes.RoomAvatar)?.content['url'];
        final channelAvatar = rawAvatar is String ? rawAvatar.trim() : '';
        if (channelAvatar.isNotEmpty) return channelAvatar;
        final publicAvatar = _suggestedGroups
            .where((group) => group.roomId == conv.id)
            .map((group) => group.avatarUrl?.trim() ?? '')
            .firstWhere((avatar) => avatar.isNotEmpty, orElse: () => '');
        if (publicAvatar.isNotEmpty) return publicAvatar;
      }
      final roomAvatar = _groupRoomAvatarUrl(
        MatrixChatService.instance.getRoomById(conv.id),
      );
      if (roomAvatar?.trim().isNotEmpty == true) return roomAvatar!.trim();
      final publicAvatar = _suggestedGroups
          .where((group) => group.roomId == conv.id)
          .map((group) => group.avatarUrl?.trim() ?? '')
          .firstWhere((avatar) => avatar.isNotEmpty, orElse: () => '');
      if (publicAvatar.isNotEmpty) return publicAvatar;
      final storedAvatar = conv.otherUserAvatar?.trim() ?? '';
      return storedAvatar.isEmpty ? null : storedAvatar;
    }

    final contactKey = _contactKeyForConversation(conv);
    final contactAvatar = _safeDirectAvatarUrl(
      contactKey == null ? null : _contactAvatarCache[contactKey],
    );
    if (contactAvatar != null) {
      return contactAvatar;
    }

    final cachedPublicAvatar = _safeDirectAvatarUrl(
      _cachedPublicAvatarForConversation(conv),
    );
    if (cachedPublicAvatar != null) {
      return cachedPublicAvatar;
    }

    final identityAvatar = _safeDirectAvatarUrl(
      _identityForConversation(conv)?.avatarUrl,
    );
    if (identityAvatar != null) {
      return identityAvatar;
    }

    return null;
  }

  String? _preferredAvatarForConversation(
    ChatConversation conv,
    String? contactKey,
  ) {
    if (_isGroupConversation(conv)) {
      final roomAvatar = _groupRoomAvatarUrl(
        MatrixChatService.instance.getRoomById(conv.id),
      );
      if (roomAvatar?.trim().isNotEmpty == true) return roomAvatar!.trim();
      return null;
    }
    final contactAvatar = _safeDirectAvatarUrl(
      contactKey == null ? null : _contactAvatarCache[contactKey],
    );
    if (contactAvatar != null) {
      return contactAvatar;
    }

    final cachedPublicAvatar = _safeDirectAvatarUrl(
      _cachedPublicAvatarForConversation(conv),
    );
    if (cachedPublicAvatar != null) {
      return cachedPublicAvatar;
    }

    final identityAvatar = _safeDirectAvatarUrl(
      _identityForConversation(conv)?.avatarUrl,
    );
    if (identityAvatar != null) {
      return identityAvatar;
    }

    return null;
  }

  String? _safeDirectAvatarUrl(String? avatarUrl) {
    final safe = ContactAvatarSanitizer.sanitizeAvatarUrl(avatarUrl);
    // A contact and a room may legitimately use the same image URL. The
    // conversation kind and peer ID establish ownership; URL equality does
    // not make a valid direct-contact avatar unsafe.
    if (safe == null) return null;
    return safe;
  }

  bool _isKnownGroupAvatar(String? avatarUrl) {
    final key = _normaliseAvatarIdentity(avatarUrl);
    if (key.isEmpty) return false;
    for (final conversation in _conversations) {
      if (!_isGroupConversation(conversation)) continue;
      if (_normaliseAvatarIdentity(conversation.otherUserAvatar) == key) {
        return true;
      }
      final roomAvatar = _groupRoomAvatarUrl(
        MatrixChatService.instance.getRoomById(conversation.id),
      );
      if (_normaliseAvatarIdentity(roomAvatar) == key) return true;
    }
    if (MatrixClientService.instance.isInitialized) {
      for (final room in MatrixChatService.instance.rooms) {
        if (!MatrixChatService.instance.isMatrixGroupRoom(room)) continue;
        if (_normaliseAvatarIdentity(_groupRoomAvatarUrl(room)) == key) {
          return true;
        }
      }
    }
    return false;
  }

  String? _cachedPublicAvatarForConversation(ChatConversation conv) {
    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final uid = _profileUidForConversation(conv);
    if (uid == null) return null;
    final cached = UserProfileService.instance.cachedPublicProfileByUid(
      uid,
      phone: fallbackPhone,
    );
    return cached?.hasProfileImage == true ? cached!.profileImage : null;
  }

  String? _localAvatarPathForConversation(ChatConversation conv) {
    if (_isGroupConversation(conv)) {
      final path = _localRoomAvatarPaths[conv.id]?.trim() ?? '';
      return path.isEmpty ? null : path;
    }
    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final uid = _profileUidForConversation(conv);
    if (uid == null) return null;
    final cached = UserProfileService.instance.cachedPublicProfileByUid(
      uid,
      phone: fallbackPhone,
    );
    final localPath = cached?.localProfileImagePath.trim() ?? '';
    return localPath.isEmpty ? null : localPath;
  }

  String? _cachedPublicNameForConversation(ChatConversation conv) {
    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final uid = _profileUidForConversation(conv);
    if (uid == null) return null;
    final cached = UserProfileService.instance.cachedPublicProfileByUid(
      uid,
      phone: fallbackPhone,
    );
    final name = _cleanHumanName(cached?.displayName);
    return name.isEmpty ? null : name;
  }

  void _cacheIdentity(ContactIdentity identity) {
    for (final key in [
      ..._identityKeys(identity.matrixUserId),
      ..._identityKeys(identity.phone),
    ]) {
      final localpart = _matrixLocalpart(key)?.toLowerCase();
      if (localpart != null && localpart.isNotEmpty) {
        _identityCache[localpart] = identity;
      }
    }
  }

  List<ChatConversation> _dedupeLocalPlaceholders(
    List<ChatConversation> convs,
  ) {
    final matrixPeerKeys =
        convs
            .where((c) => c.id.startsWith('!'))
            .expand(_conversationKeys)
            .toSet();

    if (matrixPeerKeys.isEmpty) return convs;

    return convs.where((c) {
      if (!c.id.startsWith('si_')) return true;
      return !_conversationKeys(c).any(matrixPeerKeys.contains);
    }).toList();
  }

  List<ChatConversation> _dedupePeerConversations(
    List<ChatConversation> conversations,
  ) {
    final byKey = <String, ChatConversation>{};

    for (final conversation in conversations) {
      final key = _dedupePeerKey(conversation);
      final existing = byKey[key];
      byKey[key] =
          existing == null
              ? conversation
              : _preferPeerDedupeConversation(existing, conversation);
    }

    final deduped =
        byKey.values.toList()
          ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    return deduped;
  }

  String _dedupePeerKey(ChatConversation conv) {
    if (_isGroupConversation(conv)) return 'group:${conv.id}';

    final contactKey = _contactKeyForConversation(conv);
    if (contactKey != null && contactKey.trim().isNotEmpty) {
      return 'contact:${_canonicalIdentityKey(contactKey)}';
    }

    final identity = _identityForConversation(conv);
    final identityKey = _canonicalIdentityKey(
      identity?.matrixUserId ?? identity?.phone ?? '',
    );
    if (identityKey.isNotEmpty) return 'identity:$identityKey';

    final phone = _fallbackPhoneForConversation(conv);
    final phoneKey = _canonicalIdentityKey(phone);
    if (phoneKey.startsWith('p:')) return 'phone:$phoneKey';

    final uid = _profileUidForConversation(conv);
    final uidKey = _canonicalIdentityKey(uid ?? '');
    if (uidKey.isNotEmpty) return 'uid:$uidKey';

    final title = _cleanHumanName(conv.otherUserName).toLowerCase();
    final avatar = _normaliseAvatarIdentity(_avatarForConversation(conv));
    if (title.isNotEmpty && avatar.isNotEmpty) {
      return 'name-avatar:$title|$avatar';
    }

    return 'conversation:${conv.id}';
  }

  String _canonicalIdentityKey(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final digits = value.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length >= 6) return 'p:$digits';
    final localpart = _matrixLocalpart(value) ?? value;
    final cleaned = localpart.trim().toLowerCase();
    return cleaned.isEmpty ? '' : 'u:$cleaned';
  }

  ChatConversation _preferPeerDedupeConversation(
    ChatConversation a,
    ChatConversation b,
  ) {
    final aHasMessage = a.lastMessage.trim().isNotEmpty;
    final bHasMessage = b.lastMessage.trim().isNotEmpty;
    final chosen =
        aHasMessage != bHasMessage
            ? (aHasMessage ? a : b)
            : b.lastMessageTime.isAfter(a.lastMessageTime)
            ? b
            : a;
    final other = identical(chosen, a) ? b : a;
    final mergedParticipants =
        <String>{
          ...chosen.participants,
          ...other.participants,
        }.where((participant) => participant.trim().isNotEmpty).toList();
    final unread =
        chosen.unreadCount > other.unreadCount
            ? chosen.unreadCount
            : other.unreadCount;
    final chosenName = _cleanHumanName(chosen.otherUserName);
    final otherName = _cleanHumanName(other.otherUserName);
    return chosen.copyWith(
      participants: mergedParticipants,
      unreadCount: unread,
      otherUserName: chosenName.isNotEmpty ? chosen.otherUserName : otherName,
      otherUserAvatar:
          chosen.otherUserAvatar?.trim().isNotEmpty == true
              ? chosen.otherUserAvatar
              : other.otherUserAvatar,
    );
  }

  String? _contactKeyForConversation(ChatConversation conv) {
    for (final key in _conversationKeys(conv)) {
      if (_contactNameCache.containsKey(key)) return key;
    }
    return null;
  }

  Iterable<String> _conversationKeys(ChatConversation conv) sync* {
    yield* _identityKeys(conv.otherUserId);
    if (!_isCurrentUserIdentifier(conv.lastMessageSenderId)) {
      yield* _identityKeys(conv.lastMessageSenderId);
    }
    if (conv.otherUserName != null) yield* _identityKeys(conv.otherUserName!);
    for (final participant in conv.participants) {
      if (!_isCurrentUserIdentifier(participant)) {
        yield* _identityKeys(participant);
      }
    }
  }

  bool _isCurrentUserIdentifier(String value) {
    final current = _currentUserId.trim();
    if (current.isEmpty) return false;
    final localpart = _matrixLocalpart(value) ?? value.trim();
    return localpart == current ||
        value.trim() == '@$current:${MatrixConfig.serverName}';
  }

  void _cacheContactName(String? raw, String name, String? avatarUrl) {
    final avatar = _safeDirectAvatarUrl(avatarUrl);
    for (final key in _identityKeys(raw)) {
      _contactNameCache[key] = name;
      _contactAvatarCache[key] = avatar;
    }
  }

  Iterable<String> _identityKeys(String? raw) sync* {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return;

    yield value;

    final localpart = _matrixLocalpart(value);
    if (localpart != null && localpart.isNotEmpty) yield localpart;

    // Only an actual phone-shaped value may create a numeric lookup key.
    // Matrix user IDs are opaque: stripping letters from a UID used to create
    // digit fragments that could collide with another contact's phone.
    if (_looksLikePhone(value) && !_looksLikeMatrixId(value)) {
      final digits = value.replaceAll(RegExp(r'[^\d]'), '');
      if (digits.length >= 7) yield digits;
    }
  }

  String _directAvatarCacheIdentity(ChatConversation conversation) {
    final uid = _profileUidForConversation(conversation)?.trim() ?? '';
    final peer =
        uid.isNotEmpty ? uid.toLowerCase() : conversation.id.toLowerCase();
    return 'user:$peer';
  }

  String? _matrixLocalpart(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  /// Returns true when [value] is a raw phone number rather than a
  /// human display name.
  bool _looksLikePhone(String value) {
    final s = value.replaceAll(RegExp(r'[\s\-()+]'), '');
    if (s.length < 7 || s.length > 15) return false;
    return s.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(s);
  }

  bool _looksLikeMatrixId(String value) {
    final trimmed = value.trim();
    final localpart = _matrixLocalpart(trimmed) ?? trimmed;
    return trimmed.startsWith('@') ||
        trimmed.startsWith('!') ||
        trimmed.contains(':matrix.') ||
        RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart);
  }

  String _cleanHumanName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' ||
        lowered == 'uder' ||
        lowered == 'unknown' ||
        lowered.startsWith('group with ')) {
      return '';
    }
    if (_looksLikePhone(trimmed) || _looksLikeMatrixId(trimmed)) return '';
    return trimmed;
  }

  String _cleanGroupName(String? value, {mx.Room? room}) {
    final name = _cleanHumanName(value);
    if (name.isEmpty || name.startsWith('gr.@')) return '';
    if (room != null && _looksLikeGroupMemberName(room, name)) return '';
    if (_looksLikeKnownContactName(name)) return '';
    return name;
  }

  String _displayGroupAlias(mx.Room? room) {
    final raw = room?.canonicalAlias.trim() ?? '';
    if (raw.isEmpty) return '';
    final withoutHash = raw.startsWith('#') ? raw.substring(1) : raw;
    return withoutHash.split(':').first.trim();
  }

  String? _groupRoomAvatarUrl(mx.Room? room) {
    final raw = room?.getState(mx.EventTypes.RoomAvatar)?.content['url'];
    final avatar = raw is String ? raw.trim() : '';
    if (avatar.isEmpty || _matchesGroupParticipantAvatar(room, avatar)) {
      return null;
    }
    return avatar;
  }

  bool _matchesGroupParticipantAvatar(mx.Room? room, String avatarUrl) {
    if (room == null) return false;
    final normalizedAvatar = _normaliseAvatarIdentity(avatarUrl);
    if (normalizedAvatar.isEmpty) return false;
    for (final member in room.getParticipants(_groupMemberships)) {
      if (member.id == MatrixClientService.instance.userId) continue;
      final memberAvatar = _normaliseAvatarIdentity(
        member.avatarUrl?.toString(),
      );
      if (memberAvatar.isNotEmpty && memberAvatar == normalizedAvatar) {
        return true;
      }
    }
    return false;
  }

  String _normaliseAvatarIdentity(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed;
    if (uri.scheme == 'mxc') {
      return 'mxc://${uri.host}${uri.path}';
    }
    final segments = uri.pathSegments;
    final mediaIndex = segments.indexOf('media');
    if (mediaIndex >= 1 &&
        mediaIndex + 4 < segments.length &&
        segments[mediaIndex - 1] == '_matrix' &&
        segments[mediaIndex + 1] == 'v3' &&
        (segments[mediaIndex + 2] == 'download' ||
            segments[mediaIndex + 2] == 'thumbnail')) {
      final serverName = segments[mediaIndex + 3];
      final mediaId = segments.sublist(mediaIndex + 4).join('/');
      if (serverName.isNotEmpty && mediaId.isNotEmpty) {
        return 'mxc://$serverName/$mediaId';
      }
    }
    return trimmed;
  }

  bool _looksLikeGroupMemberName(mx.Room room, String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    for (final member in room.getParticipants([mx.Membership.join])) {
      if (member.id == MatrixClientService.instance.userId) continue;
      final memberName =
          _cleanHumanName(member.calcDisplayname()).toLowerCase();
      if (memberName.isNotEmpty && memberName == normalized) return true;
    }
    return false;
  }

  bool _looksLikeKnownContactName(String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return _contactNameCache.values.any(
      (contactName) => contactName.trim().toLowerCase() == normalized,
    );
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

    final localpart = _matrixLocalpart(raw) ?? raw;
    if (_looksLikeMatrixId(localpart)) return '';
    final digits = localpart.replaceAll(RegExp(r'[^\d]'), '');
    return RegExp(r'^\+?\d{7,15}$').hasMatch(localpart) ? digits : '';
  }

  String _formatPhone(String phone) {
    return CountryPhoneNumber.formatInternationalDisplay(phone);
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

  String _stripInvalidNorthAmericaPrefix(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (!phone.startsWith('+1')) return phone;
    if (digits.length <= 11) return phone;
    return '+${digits.substring(1)}';
  }

  Future<void> _retryEnrichment() async {
    await _reloadContactsAndRepaint(reason: 'retry enrichment');
  }

  Future<void> _reloadContactsAndRepaint({required String reason}) async {
    _groupLastSenderNames.clear();
    await _loadSavedContacts(refreshBackend: false);
    final enriched = await _enrichNames(_conversations);
    await _publishPreparedConversations(enriched);
    debugPrint('[ConversationsScreen] contact repaint done reason="$reason"');
  }

  // ===========================================================================
  //  HELPERS
  // ===========================================================================

  void _notifyUnread(List<ChatConversation> convs) {
    final total = convs.fold(0, (sum, c) => sum + c.unreadCount);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onUnreadCountUpdated?.call(total);
    });
  }

  String _sanitize(String s) =>
      String.fromCharCodes(s.runes.where((r) => r <= 0xD7FF || r >= 0xE000));

  String _conversationPreview(ChatConversation conversation) {
    final raw = conversation.lastMessage;
    final rawTrimmed = raw.trim();
    if (conversation.lastMessageType == 'voice' ||
        RegExp(
          r'^voice_\d+\.aac$',
          caseSensitive: false,
        ).hasMatch(rawTrimmed)) {
      return 'Voice message';
    }
    var text = _sanitize(raw).trim();
    if (text.startsWith('> ')) {
      final parts = text.split('\n\n');
      if (parts.length > 1) {
        text = parts.sublist(1).join('\n\n').trim();
      }
    }
    text = text.replaceFirst(RegExp(r'^<[^>]+>\s*'), '').trim();
    text =
        text.replaceFirst(RegExp(r'^@[A-Za-z0-9._=-]+:[^\s]+\s*'), '').trim();
    return linkDisplayText(text);
  }

  void _enterSelection() => setState(() {
    _isSelectionMode = true;
    _selectedIds.clear();
  });
  void _exitSelection() => setState(() {
    _isSelectionMode = false;
    _selectedIds.clear();
  });
  void _toggleSelection(String id) => setState(() {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
    }
  });

  void _onPin() => debugPrint('Pin: ${_selectedIds.toList()}');
  void _onMarkAsRead() => debugPrint('MarkAsRead: ${_selectedIds.toList()}');
  void _onMute() => debugPrint('Mute: ${_selectedIds.toList()}');
  void _onArchive() => debugPrint('Archive: ${_selectedIds.toList()}');
  void _onDelete() => debugPrint('Delete: ${_selectedIds.toList()}');

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    final isToday =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (isToday) {
      final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m ${local.hour >= 12 ? 'PM' : 'AM'}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (local.year == yesterday.year &&
        local.month == yesterday.month &&
        local.day == yesterday.day) {
      return 'Yesterday';
    }
    if (now.difference(local).inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    }
    return '${local.day}/${local.month}/${local.year}';
  }

  // ===========================================================================
  //  CONVERSATION TILE
  // ===========================================================================

  Widget _buildTile(ChatConversation conv, {bool channelOnly = false}) {
    final name = _sanitize(_conversationTitle(conv));
    final avatar = _avatarForConversation(conv);
    final localAvatarPath = _localAvatarPathForConversation(conv);
    final selected = _selectedIds.contains(conv.id);
    final isDeleted =
        conv.deletedAt != null ||
        conv.lastMessageType == ChatService.groupDeletedMessageType ||
        ChatService.isGroupDeletedPreview(conv.lastMessage);
    final hasMessage = !isDeleted && conv.lastMessage.trim().isNotEmpty;
    // A deleted-group shell is intentionally title-only. Sender and preview
    // text belong to the purged conversation and must never be shown.
    final senderName =
        hasMessage && _isGroupConversation(conv)
            ? _groupLastSenderName(conv)
            : null;

    return ConversationTile(
      name: name,
      hasMessage: hasMessage,
      senderName: senderName,
      lastMessage: isDeleted ? '' : _conversationPreview(conv),
      time: hasMessage ? _formatTime(conv.lastMessageTime) : '',
      avatarUrl: avatar,
      avatarCacheIdentity:
          _isGroupConversation(conv)
              ? MatrixChatService.instance.roomProfileCacheIdentity(
                accountId: _currentUserId,
                roomId: conv.id,
                avatarUrl: avatar,
                room: MatrixChatService.instance.getRoomById(conv.id),
              )
              : _directAvatarCacheIdentity(conv),
      localAvatarPath: localAvatarPath,
      unreadCount: conv.unreadCount,
      isDeleted: isDeleted,
      isSelectionMode: _isSelectionMode,
      isSelected: selected,
      onSelectionToggle: () => _toggleSelection(conv.id),
      channelOnly: channelOnly,
      channelSubscriberCount:
          channelOnly ? _channelSubscriberCount(conv) : null,
      onLongPress: () async {
        if (isDeleted) {
          await _removeDeletedRoomShell(
            conv,
            name,
            isChannel: channelOnly || _isChannelConversation(conv),
          );
          return;
        }
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Preview',
          barrierColor: Colors.transparent,
          pageBuilder:
              (_, __, ___) => MiniChatPreview(
                conversationId: conv.id,
                name: name,
                avatarUrl: avatar,
                currentUserId: _currentUserId,
                receiverId: conv.otherUserId,
              ),
        );
      },
      onTap: () async {
        if (_isSelectionMode) {
          _toggleSelection(conv.id);
          return;
        }
        if (!_openingConversationIds.add(conv.id)) {
          apkLog(
            'Conversation.navigation',
            'duplicate open suppressed conversation_id="${conv.id}"',
          );
          return;
        }

        var initialMessages = _chat.cachedMessagesFor(conv.id);
        if (initialMessages.isEmpty) {
          initialMessages = await _chat.loadCachedMessages(conv.id);
          if (!mounted) return;
        }

        unawaited(_chat.markConversationAsRead(conv.id));
        unawaited(
          NotificationService.instance.clearConversationNotifications(conv.id),
        );

        if (mounted) {
          setState(() {
            _conversations =
                _conversations
                    .map(
                      (c) => c.id == conv.id ? c.copyWith(unreadCount: 0) : c,
                    )
                    .toList();
          });
          _notifyUnread(_conversations);
        }

        if (!mounted) return;
        final isGroup = _isGroupConversation(conv);
        final isChannel = _isChannelConversation(conv);
        final chatReceiverId = isGroup ? conv.id : conv.otherUserId;
        if (!isGroup) {
          await AvatarPreloadService.warm(
            avatar,
            cacheIdentity: _directAvatarCacheIdentity(conv),
          );
          apkLog(
            'Identity.display',
            'surface="conversation_open" user_id="${_matrixLocalpart(chatReceiverId) ?? chatReceiverId}" '
                'name="$name" avatar=${(avatar ?? '').trim().isNotEmpty} '
                'avatar_url="${avatar ?? ''}"',
          );
          if (!mounted) return;
        }

        final groupResult = await Navigator.push<Object?>(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 220),
            pageBuilder:
                (_, __, ___) =>
                    isChannel
                        ? ChannelFeedScreen(
                          conversationId: conv.id,
                          currentUserId: _currentUserId,
                          title: name,
                          avatarUrl: avatar,
                          localAvatarPath: localAvatarPath,
                          initialPosts: initialMessages,
                          subscriberCount: conv.participants.length,
                          canPost: _isOwnGroupConversation(conv),
                        )
                        : ChatScreen(
                          conversationId: conv.id,
                          receiverId: chatReceiverId,
                          currentUserId: _currentUserId,
                          title: name,
                          avatarUrl: avatar,
                          initialMessages: initialMessages,
                          initialMemberCount:
                              isGroup && conv.participants.length > 1
                                  ? conv.participants.length
                                  : null,
                          conversationKind:
                              isGroup
                                  ? ConversationKind.group
                                  : ConversationKind.direct,
                        ),
            transitionsBuilder: (_, animation, __, child) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(1, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              );
            },
          ),
        ).whenComplete(() => _openingConversationIds.remove(conv.id));
        if (!mounted) return;
        await _loadLocalConversations();
        if (groupResult is GroupExitRequest) {
          await _handleGroupExit(groupResult);
          return;
        }
        if (isGroup) {
          await _loadSuggestedGroups(force: true);
        }
      },
    );
  }

  int _channelSubscriberCount(ChatConversation conversation) {
    return conversation.participants.length;
  }

  Future<void> _removeDeletedRoomShell(
    ChatConversation conversation,
    String roomName, {
    required bool isChannel,
  }) async {
    final roomKind = isChannel ? 'Channel' : 'Group';
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFF23262C),
            title: Text(
              'Delete $roomKind',
              style: const TextStyle(color: Colors.white),
            ),
            content: Text(
              'Delete $roomName completely from this device?',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Color(0xFFE85D75)),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    // Update the screen guard immediately so a concurrent contact or Matrix
    // repaint cannot republish the row while persistence is completing.
    _dismissedDeletedGroupRoomIds = <String>{
      ..._dismissedDeletedGroupRoomIds,
      conversation.id,
    };
    await _chat.dismissDeletedGroupLocally(conversation.id);
    final room = MatrixChatService.instance.getRoomById(conversation.id);
    final alias = room?.canonicalAlias;
    // Deleted shells bypass the normal five-second exit request, so they must
    // perform the permanent Matrix-account cleanup here as well. Persist the
    // server-backed tombstone before leave/forget so a later login cannot
    // restore the room from a fresh sync.
    await MatrixChatService.instance.markPublicGroupDeleted(
      roomId: conversation.id,
      canonicalAlias: alias,
    );
    await MatrixChatService.instance.leaveGroup(conversation.id);
    apkLog(
      isChannel ? 'Channels.deleteShell' : 'Groups.deleteShell',
      'permanently removed room_kind="${roomKind.toLowerCase()}" '
      'room_id="${conversation.id}" alias="$alias"',
    );
    if (!mounted) return;
    await _loadLocalConversations();
    await _loadSuggestedGroups(force: true);
  }

  String _groupLastSenderName(ChatConversation conversation) {
    final senderId = conversation.lastMessageSenderId.trim();
    if (senderId.isEmpty || senderId.startsWith('!')) return '';
    if (_isCurrentUserIdentifier(senderId)) return 'You';

    final cached = _cleanHumanName(_groupLastSenderNames[senderId]);
    if (cached.isNotEmpty) return cached;

    final senderLocalpart = _matrixLocalpart(senderId)?.toLowerCase() ?? '';
    for (final contact in _savedContacts) {
      final contactLocalpart =
          _matrixLocalpart(contact.wrytteUserId)?.toLowerCase() ?? '';
      if (senderLocalpart.isEmpty || contactLocalpart != senderLocalpart) {
        continue;
      }
      final profile2Name = _cleanHumanName(contact.formattedName);
      if (profile2Name.isNotEmpty) {
        _groupLastSenderNames[senderId] = profile2Name;
        return profile2Name;
      }
    }

    final profile1 =
        _identityCache[senderId.toLowerCase()] ??
        _identityCache['@$senderLocalpart:${MatrixConfig.serverName}'
            .toLowerCase()];
    final profile1Name = _cleanHumanName(profile1?.profileName);
    if (profile1Name.isNotEmpty) {
      _groupLastSenderNames[senderId] = profile1Name;
      return profile1Name;
    }

    final room = MatrixChatService.instance.getRoomById(conversation.id);
    if (room != null) {
      for (final member in room.getParticipants(_groupMemberships)) {
        if (member.id != senderId) continue;
        final matrixName = _cleanHumanName(member.calcDisplayname());
        if (matrixName.isNotEmpty) {
          _groupLastSenderNames[senderId] = matrixName;
          unawaited(_fetchGroupLastSenderProfile(senderId));
          return matrixName;
        }
      }
    }

    unawaited(_fetchGroupLastSenderProfile(senderId));
    return senderLocalpart;
  }

  Future<void> _fetchGroupLastSenderProfile(String senderId) async {
    if (!_groupLastSenderInFlight.add(senderId)) return;
    try {
      final localpart = _matrixLocalpart(senderId) ?? '';
      if (localpart.isEmpty) return;
      final profile = await UserProfileService.instance.getProfileByUid(
        localpart,
        forceRefresh: false,
      );
      final name = _cleanHumanName(profile?.displayName);
      if (name.isEmpty) return;
      await ContactIdentityCache.instance.upsert(
        ownerUserId: _currentUserId,
        matrixUserId: senderId,
        phone: profile?.phone,
        profileName: name,
        avatarUrl: profile?.profileImage,
        bio: profile?.bio,
      );
      if (_groupLastSenderNames[senderId] == name) return;
      _groupLastSenderNames[senderId] = name;
      if (mounted) setState(() {});
    } finally {
      _groupLastSenderInFlight.remove(senderId);
    }
  }

  // ===========================================================================
  //  BUILD
  // ===========================================================================

  Widget _buildConversationTab(
    double topPadding, {
    required List<ChatConversation> conversations,
    required String emptyTitle,
    required String emptySubtitle,
    required IconData emptyIcon,
    ScrollController? controller,
  }) {
    if (conversations.isEmpty) {
      if (_initialCacheWarmup) {
        return ScrollConfiguration(
          behavior: const _ConversationsScrollBehavior(),
          child: ListView(
            controller: controller,
            padding: EdgeInsets.only(top: topPadding, bottom: 120),
            physics: const BouncingScrollPhysics(),
            children: const [
              _ConversationLoadingRow(),
              _ConversationLoadingRow(),
            ],
          ),
        );
      }

      return ScrollConfiguration(
        behavior: const _ConversationsScrollBehavior(),
        child: ListView(
          controller: controller,
          padding: EdgeInsets.only(top: topPadding, bottom: 120),
          physics: const BouncingScrollPhysics(),
          children: [
            const SizedBox(height: 60),
            Center(
              child: Column(
                children: [
                  Icon(
                    emptyIcon,
                    size: 64,
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    emptyTitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    emptySubtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.2),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF4DA3FF),
      backgroundColor: Colors.transparent,
      onRefresh: () async {
        await _loadSavedContacts();
        await _loadLocalConversations();
        await _chat.fetchConversations();
        await _retryEnrichment();
      },
      child: ScrollConfiguration(
        behavior: const _ConversationsScrollBehavior(),
        child: ListView.builder(
          controller: controller,
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(top: topPadding, bottom: 120),
          itemCount: conversations.length,
          itemBuilder:
              (_, i) => KeyedSubtree(
                key: ValueKey(conversations[i].id),
                child: _buildTile(conversations[i]),
              ),
        ),
      ),
    );
  }

  Widget _buildChatsTab(double topPadding) {
    final chats =
        _conversations.where((c) => !_isGroupConversation(c)).toList();
    return _buildConversationTab(
      topPadding,
      conversations: chats,
      emptyTitle: 'No conversations yet',
      emptySubtitle: 'Tap the pencil icon to start a new chat',
      emptyIcon: Icons.chat_bubble_outline_rounded,
      controller: _scrollCtrl,
    );
  }

  bool _isChannelConversation(ChatConversation conversation) {
    final liveRoom = MatrixChatService.instance.getRoomById(conversation.id);
    if (liveRoom != null &&
        MatrixChatService.instance.isChannelRoom(liveRoom)) {
      return true;
    }
    final directoryRoom =
        _suggestedGroups
            .where((room) => room.roomId == conversation.id)
            .firstOrNull;
    if (directoryRoom?.isChannel == true) return true;
    if (conversation.isChannelKind) return true;
    final category = _cachedRoomCategories[conversation.id];
    if (category?.startsWith('channel_') == true) return true;
    if (category?.startsWith('group_') == true) return false;
    if (liveRoom != null) return false;
    if (directoryRoom != null) return false;
    return false;
  }

  bool _isSuggestedChannel(MatrixPublicGroup room) {
    if (room.isChannel) return true;
    final category = _cachedRoomCategories[room.roomId];
    if (category?.startsWith('channel_') == true) return true;
    if (category?.startsWith('group_') == true) return false;
    return false;
  }

  Widget _buildChannelsTab(double topPadding) {
    final allChannels =
        _conversations
            .where(
              (conversation) =>
                  _isChannelConversation(conversation) &&
                  _cachedRoomCategories[conversation.id] !=
                      'channel_suggested' &&
                  _isDisplayableGroupConversation(conversation),
            )
            .toList();
    final ownChannels = allChannels.where(_isOwnGroupConversation).toList();
    final subscriptions =
        allChannels
            .where((channel) => !ownChannels.any((own) => own.id == channel.id))
            .toList();
    final suggestedChannels =
        _suggestedGroups
            .where(_isSuggestedChannel)
            .where(
              (group) =>
                  !allChannels.any((channel) => channel.id == group.roomId),
            )
            .toList();

    return ListView(
      padding: EdgeInsets.only(top: topPadding, bottom: 120),
      children: [
        if (ownChannels.isNotEmpty) ...[
          _groupSectionHeader('Your channels ${ownChannels.length}'),
          ...ownChannels.map(
            (channel) => _buildTile(channel, channelOnly: true),
          ),
        ],
        if (subscriptions.isNotEmpty) ...[
          _groupSectionHeader('Subscriptions ${subscriptions.length}'),
          ...subscriptions.map(
            (channel) => _buildTile(channel, channelOnly: true),
          ),
        ],
        if (suggestedChannels.isNotEmpty) ...[
          _groupSectionHeader('Suggested'),
          ...suggestedChannels.map(_suggestedChannelTile),
        ],
        if (ownChannels.isEmpty &&
            subscriptions.isEmpty &&
            suggestedChannels.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 280),
            child: Center(
              child: Text(
                'No channels yet',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            ),
          ),
      ],
    );
  }

  Widget _suggestedChannelTile(MatrixPublicGroup channel) {
    final isSubscribing = _subscribingSuggestedGroupIds.contains(
      channel.roomId,
    );
    return InkWell(
      onTap: () => _openSuggestedGroup(channel),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            UserAvatar(
              imageUrl: channel.avatarUrl,
              localImagePath: _localRoomAvatarPaths[channel.roomId],
              name: channel.name,
              size: 60,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${channel.memberCount} subscribers',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 1,
                    child: LayoutBuilder(
                      builder:
                          (context, constraints) => OverflowBox(
                            alignment: Alignment.centerLeft,
                            maxWidth: constraints.maxWidth + 20,
                            maxHeight: 1,
                            child: SizedBox(
                              width: constraints.maxWidth + 20,
                              height: 1,
                              child: Divider(
                                color: Colors.grey.withOpacity(0.3),
                                thickness: 0.5,
                                height: 1,
                              ),
                            ),
                          ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 36,
              child: FilledButton(
                onPressed:
                    isSubscribing ? null : () => _joinSuggestedGroup(channel),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF4DA3FF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                child:
                    isSubscribing
                        ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(width: 8),
                            Text('Subscribing'),
                          ],
                        )
                        : const Text('Subscribe'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupsTab(double topPadding) {
    final allGroups =
        _conversations
            .where(
              (conversation) =>
                  !_isChannelConversation(conversation) &&
                  _cachedRoomCategories[conversation.id] != 'group_suggested' &&
                  _isDisplayableGroupConversation(conversation),
            )
            .toList();
    final createdIds = _chat.createdGroupRoomIds;
    final shouldPromotePublicGroupsAsOwn =
        allGroups.isEmpty &&
        createdIds.isNotEmpty &&
        MatrixChatService.instance.rooms.isEmpty;
    final promotedOwnGroups =
        shouldPromotePublicGroupsAsOwn
            ? _suggestedGroups
                .where((g) => !_isSuggestedChannel(g))
                .where((g) => createdIds.contains(g.roomId))
                .where(
                  (g) => !MatrixChatService.instance.isPublicGroupDismissed(g),
                )
                .map(_publicGroupAsOwnedConversation)
                .toList()
            : const <ChatConversation>[];
    final ownGroups = [
      ...allGroups.where(_isOwnGroupConversation),
      ...promotedOwnGroups,
    ];
    final joinedGroups =
        allGroups.where((group) => !_isOwnGroupConversation(group)).toList();
    final localGroupNames = allGroups.map(_normalizedGroupTitle).toSet();
    final joinedIds = {
      ...allGroups.map((group) => group.id),
      ...promotedOwnGroups.map((group) => group.id),
      ..._joinedMatrixGroupRoomIds(),
      ...createdIds,
    };
    final joinedAliases = _joinedMatrixGroupAliases();
    final suggested =
        _suggestedGroups
            .where((group) => !_isSuggestedChannel(group))
            .where(
              (group) =>
                  group.memberCount > 0 &&
                  !MatrixChatService.instance.isPublicGroupDismissed(group) &&
                  !_chat.isConversationDeleted(group.roomId) &&
                  !joinedIds.contains(group.roomId) &&
                  !_suggestedAliasMatchesJoined(group, joinedAliases) &&
                  !_suggestedNameMatchesLocalGroup(group, localGroupNames),
            )
            .toList();

    final diagnostic =
        'all=${allGroups.length} own=${ownGroups.length} joined=${joinedGroups.length} '
        'created_ids=${createdIds.length} suggested=${suggested.length} '
        'promoted=${promotedOwnGroups.length} local_names="${localGroupNames.join(',')}"';
    if (_lastGroupsDiagnostic != diagnostic) {
      _lastGroupsDiagnostic = diagnostic;
      apkLog('Groups.tab', diagnostic);
    }

    if (allGroups.isEmpty && suggested.isEmpty && _initialCacheWarmup) {
      return _buildConversationTab(
        topPadding,
        conversations: const [],
        emptyTitle: 'No groups yet',
        emptySubtitle: 'Tap the menu and create a new group',
        emptyIcon: Icons.groups_2_outlined,
      );
    }

    if (allGroups.isEmpty && suggested.isEmpty && !_loadingSuggestedGroups) {
      return _buildGroupsEmptyState(topPadding);
    }

    return RefreshIndicator(
      color: const Color(0xFF4DA3FF),
      backgroundColor: Colors.transparent,
      onRefresh: () async {
        await _loadSavedContacts();
        await _loadLocalConversations();
        await _chat.fetchConversations();
        await _loadSuggestedGroups(force: true);
      },
      child: ScrollConfiguration(
        behavior: const _ConversationsScrollBehavior(),
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(top: topPadding, bottom: 120),
          children: [
            if (ownGroups.isNotEmpty) ...[
              _groupSectionHeader('Your Groups ${ownGroups.length}'),
              for (final group in ownGroups)
                KeyedSubtree(
                  key: ValueKey('own-${group.id}'),
                  child: _buildTile(group),
                ),
            ],
            if (joinedGroups.isNotEmpty) ...[
              _groupSectionHeader('Joined Groups ${joinedGroups.length}'),
              for (final group in joinedGroups)
                KeyedSubtree(
                  key: ValueKey('joined-${group.id}'),
                  child: _buildTile(group),
                ),
            ],
            if (suggested.isNotEmpty) ...[
              _groupSectionHeader('Suggested'),
              for (final group in suggested)
                KeyedSubtree(
                  key: ValueKey('suggested-${group.roomId}'),
                  child: _suggestedGroupTile(group),
                ),
            ],
            if (_loadingSuggestedGroups)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Center(
                  child: SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF4DA3FF),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Set<String> _joinedMatrixGroupRoomIds() {
    if (!MatrixClientService.instance.isInitialized) return const {};
    return MatrixChatService.instance.rooms
        .where(MatrixChatService.instance.isMatrixGroupRoom)
        .map((room) => room.id)
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Set<String> _joinedMatrixGroupAliases() {
    if (!MatrixClientService.instance.isInitialized) return const {};
    return MatrixChatService.instance.rooms
        .where(MatrixChatService.instance.isMatrixGroupRoom)
        .map((room) => room.canonicalAlias)
        .map((alias) => alias.trim())
        .where((alias) => alias.isNotEmpty)
        .toSet();
  }

  bool _suggestedAliasMatchesJoined(
    MatrixPublicGroup group,
    Set<String> joinedAliases,
  ) {
    final alias = group.canonicalAlias?.trim() ?? '';
    return alias.isNotEmpty && joinedAliases.contains(alias);
  }

  bool _suggestedNameMatchesLocalGroup(
    MatrixPublicGroup group,
    Set<String> localGroupNames,
  ) {
    final name = _normalizedGroupName(group.name);
    return name.isNotEmpty && localGroupNames.contains(name);
  }

  ChatConversation _publicGroupAsOwnedConversation(MatrixPublicGroup group) {
    final now = DateTime.now();
    return ChatConversation(
      id: group.roomId,
      participants: [
        if (_currentUserId.trim().isNotEmpty) _currentUserId.trim(),
      ],
      otherUserId: group.roomId,
      lastMessage: '',
      lastMessageSenderId: _currentUserId,
      lastMessageTime: now,
      unreadCount: 0,
      lastMessageType: 'group',
      otherUserName: group.name,
      otherUserAvatar: group.avatarUrl,
    );
  }

  String _normalizedGroupTitle(ChatConversation conversation) {
    return _normalizedGroupName(_conversationTitle(conversation));
  }

  String _normalizedGroupName(String value) {
    return _cleanHumanName(value).trim().toLowerCase();
  }

  Widget _buildGroupsEmptyState(double topPadding) {
    return ScrollConfiguration(
      behavior: const _ConversationsScrollBehavior(),
      child: ListView(
        padding: EdgeInsets.only(top: topPadding, bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.groups_2_outlined,
                  size: 64,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
                const SizedBox(height: 16),
                Text(
                  'No groups yet',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap the menu and create a new group',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.2),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 24, 6),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.58),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _suggestedGroupTile(MatrixPublicGroup group) {
    final opening = _openingSuggestedGroupIds.contains(group.roomId);
    return InkWell(
      onTap: opening ? null : () => _openSuggestedGroup(group),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            UserAvatar(
              key: ValueKey(
                MatrixChatService.instance.roomProfileCacheIdentity(
                  accountId: _currentUserId,
                  roomId: group.roomId,
                  avatarUrl: group.avatarUrl,
                  profileVersion: group.profileVersionFingerprint,
                ),
              ),
              size: 60,
              imageUrl: group.avatarUrl,
              localImagePath: _localRoomAvatarPaths[group.roomId],
              cacheIdentity: MatrixChatService.instance
                  .roomProfileCacheIdentity(
                    accountId: _currentUserId,
                    roomId: group.roomId,
                    avatarUrl: group.avatarUrl,
                    profileVersion: group.profileVersionFingerprint,
                  ),
              name: group.name,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _memberCountLabel(group.memberCount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 14),
                  Divider(
                    color: Colors.grey.withOpacity(0.3),
                    thickness: 0.5,
                    height: 0,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 36,
              child: FilledButton(
                onPressed: () => _joinSuggestedGroup(group),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF4DA3FF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                child: const Text('Join'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSuggestedGroup(MatrixPublicGroup group) async {
    if (_openingSuggestedGroupIds.contains(group.roomId)) return;
    setState(() => _openingSuggestedGroupIds.add(group.roomId));
    try {
      var fresh = await ChatLocalDb.instance.isSuggestedPreviewFresh(
        group.roomId,
      );
      var previewMessages =
          fresh
              ? await _chat.hydrateConversation(group.roomId)
              : await _chat.fetchPublicGroupPreview(roomId: group.roomId);
      if (fresh &&
          previewMessages.any((message) => message.content.startsWith('> '))) {
        apkLog(
          'SuggestedPreview',
          'repairing cached reply fallback room_id="${group.roomId}"',
        );
        fresh = false;
        previewMessages = await _chat.fetchPublicGroupPreview(
          roomId: group.roomId,
        );
      }
      if (fresh) {
        apkLog(
          'SuggestedPreview',
          'open reused fresh preview room_id="${group.roomId}" '
              'messages=${previewMessages.length}',
        );
      }
      if (!mounted) return;
      final groupResult = await Navigator.push<Object?>(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder:
              (_, __, ___) =>
                  _isSuggestedChannel(group)
                      ? ChannelFeedScreen(
                        conversationId: group.roomId,
                        currentUserId: _currentUserId,
                        title: group.name,
                        avatarUrl: group.avatarUrl,
                        initialPosts: previewMessages,
                        subscriberCount: group.memberCount,
                        readOnlyUntilSubscribe: true,
                        subscribeAlias: group.canonicalAlias,
                      )
                      : ChatScreen(
                        conversationId: group.roomId,
                        receiverId: group.roomId,
                        currentUserId: _currentUserId,
                        title: group.name,
                        avatarUrl: group.avatarUrl,
                        readOnlyUntilJoin: true,
                        initialMessages: previewMessages,
                        initialMemberCount: group.memberCount,
                        groupAlias: group.canonicalAlias,
                        groupDescription: group.topic,
                        conversationKind: ConversationKind.group,
                        initialRoomProfileVersion:
                            group.profileVersionFingerprint,
                      ),
          transitionsBuilder: (_, animation, __, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
        ),
      );
      if (!mounted) return;
      await _loadLocalConversations();
      unawaited(_loadSuggestedGroups(force: true));
      if (groupResult is GroupExitRequest) {
        await _handleGroupExit(groupResult);
      }
    } finally {
      if (mounted) {
        setState(() => _openingSuggestedGroupIds.remove(group.roomId));
      }
    }
  }

  void _showGroupsHomepage() {
    _tabController.animateTo(2);
  }

  void _showChannelsHomepage() {
    _tabController.animateTo(1);
  }

  Future<void> _handleGroupExit(GroupExitRequest request) async {
    if (request.isChannel) {
      _showChannelsHomepage();
    } else {
      _showGroupsHomepage();
    }
    if (mounted) {
      setState(() {
        _conversations =
            _conversations
                .where((conversation) => conversation.id != request.roomId)
                .toList();
        _suggestedGroups =
            _suggestedGroups
                .where((group) => group.roomId != request.roomId)
                .toList();
      });
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _startGroupExitCountdown(request);
  }

  void _startGroupExitCountdown(GroupExitRequest request) {
    final previousRequest = _pendingGroupExit;
    _groupExitTimer?.cancel();
    if (previousRequest != null && previousRequest.roomId != request.roomId) {
      unawaited(_commitGroupExit(previousRequest));
    }
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    setState(() {
      _groupExitHiddenRoomIds.add(request.roomId);
      _pendingGroupExit = request;
      _groupExitDeadline = deadline;
      _groupExitSecondsRemaining = 5;
    });
    _groupExitTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !identical(_pendingGroupExit, request)) return;
      final milliseconds = deadline.difference(DateTime.now()).inMilliseconds;
      if (milliseconds <= 0) {
        _groupExitTimer?.cancel();
        _groupExitTimer = null;
        setState(() {
          _pendingGroupExit = null;
          _groupExitDeadline = null;
        });
        unawaited(_commitGroupExit(request));
        return;
      }
      final seconds = (milliseconds / 1000).ceil().clamp(1, 5);
      setState(() => _groupExitSecondsRemaining = seconds);
    });
  }

  Future<void> _undoGroupExit() async {
    final request = _pendingGroupExit;
    if (request == null) return;
    _groupExitTimer?.cancel();
    _groupExitTimer = null;
    setState(() {
      _groupExitHiddenRoomIds.remove(request.roomId);
      _pendingGroupExit = null;
      _groupExitDeadline = null;
    });
    apkLog('Groups.undo', 'undo tapped room_id="${request.roomId}"');
    await _loadLocalConversations();
    await _loadSuggestedGroups(force: true);
  }

  Future<void> _commitGroupExit(GroupExitRequest request) async {
    try {
      apkLog(
        'Groups.undo',
        'countdown expired; committing ${request.type.name} room_id="${request.roomId}"',
      );
      await request.commit();
      if (!mounted) return;
      await _loadLocalConversations();
      await _loadSuggestedGroups(force: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _groupExitHiddenRoomIds.remove(request.roomId));
      await _loadLocalConversations();
      await _loadSuggestedGroups(force: true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not update ${request.isChannel ? 'channel' : 'group'}: '
            '$error',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _joinSuggestedGroup(MatrixPublicGroup group) async {
    if (_subscribingSuggestedGroupIds.contains(group.roomId)) return;
    setState(() => _subscribingSuggestedGroupIds.add(group.roomId));
    try {
      final room = await MatrixChatService.instance.joinGroup(
        group.canonicalAlias?.trim().isNotEmpty == true
            ? group.canonicalAlias!
            : group.roomId,
      );
      final roomId = room?.id ?? group.roomId;
      final joinedConversation = await _chat.saveJoinedGroupShell(
        roomId: roomId,
        name: group.name,
        avatarUrl: group.avatarUrl,
        conversationKind:
            _isSuggestedChannel(group)
                ? ConversationKind.channel
                : ConversationKind.group,
      );
      if (mounted) {
        setState(() {
          _subscribingSuggestedGroupIds.remove(group.roomId);
          _conversations = [
            ..._conversations.where(
              (conversation) => conversation.id != roomId,
            ),
            joinedConversation,
          ];
          _suggestedGroups =
              _suggestedGroups
                  .where((candidate) => candidate.roomId != group.roomId)
                  .toList();
        });
      }
      unawaited(_finishSuggestedGroupSubscription(roomId));
    } catch (e) {
      if (!mounted) return;
      setState(() => _subscribingSuggestedGroupIds.remove(group.roomId));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not join group: $e')));
    }
  }

  Future<void> _finishSuggestedGroupSubscription(String roomId) async {
    try {
      await _chat.backfillGroupHistory(roomId);
      await _chat.fetchConversations();
      if (!mounted) return;
      await _loadLocalConversations();
      await _loadSuggestedGroups(force: true);
    } catch (error) {
      apkLog(
        'Groups.subscribe',
        'background refresh failed room_id="$roomId" error="$error"',
      );
    }
  }

  bool _isOwnGroupConversation(ChatConversation conv) {
    final room = MatrixChatService.instance.getRoomById(conv.id);
    if (room != null && room.membership == mx.Membership.join) {
      return MatrixChatService.instance.isGroupOwner(room);
    }
    final cachedCategory = _cachedRoomCategories[conv.id];
    if (cachedCategory == 'channel_owned' || cachedCategory == 'group_owned') {
      return true;
    }
    if (cachedCategory == 'channel_subscribed' ||
        cachedCategory == 'group_joined') {
      return false;
    }
    // Compatibility fallback for rooms created before category snapshots.
    return _chat.isCreatedGroupRoom(conv.id);
  }

  String _memberCountLabel(int count) {
    return count == 1 ? '1 member' : '$count members';
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarH = MediaQuery.of(context).padding.top;
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double headerH =
        statusBarH + kToolbarHeight + _kSearchBarHeight + _kTabBarHeight + 8.0;

    final double searchBarOffset = _kSearchBarHeight * _searchBarProgress;
    final double gradientH = headerH - searchBarOffset;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      extendBodyBehindAppBar: true,
      floatingActionButton:
          _isSelectionMode
              ? null
              : Padding(
                padding: EdgeInsets.only(bottom: bottomInset + 80.0),
                child: FloatingActionButton(
                  heroTag: 'conversations_new_chat_fab',
                  // ── FIX: await the push so we can reload contacts on return ──
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const FirebaseNewChatScreen(),
                      ),
                    );
                    // Reload contacts fresh (static cache was busted by
                    // ContactService.invalidateMatrixContactsCache() on save)
                    // then re-enrich so the new contact name shows immediately.
                    if (mounted) {
                      await _loadSavedContacts();
                      final enriched = await _enrichNames(_conversations);
                      await _publishPreparedConversations(enriched);
                    }
                  },
                  backgroundColor: const Color(0xFF4DA3FF),
                  child: const Icon(Icons.edit_square, color: Colors.black),
                ),
              ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: Stack(
        children: [
          // ── Tab content ──────────────────────────────────────────────
          Positioned.fill(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildChatsTab(headerH),
                _buildChannelsTab(headerH),
                _buildGroupsTab(headerH),
              ],
            ),
          ),

          // ── Gradient ─────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: gradientH,
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

          // ── Sticky header ─────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TopBar(
                  isSelectionMode: _isSelectionMode,
                  selectedCount: _selectedIds.length,
                  onEditPressed: _enterSelection,
                  onSelectionClose: _exitSelection,
                  onMarkAsRead: _onMarkAsRead,
                  onPin: _onPin,
                  onMute: _onMute,
                  onArchive: _onArchive,
                  onDelete: _onDelete,
                ),
                Transform.translate(
                  offset: Offset(0, -searchBarOffset),
                  child: Opacity(
                    opacity: (1.0 - _searchBarProgress).clamp(0.0, 1.0),
                    child: SizedBox(
                      height: _kSearchBarHeight,
                      child: local_widgets.SearchBar(),
                    ),
                  ),
                ),
                Transform.translate(
                  offset: Offset(0, -searchBarOffset),
                  child: TabBarSection(controller: _tabController),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          if (_pendingGroupExit != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              child: _GroupExitUndoBanner(
                request: _pendingGroupExit!,
                secondsRemaining: _groupExitSecondsRemaining,
                progress: _groupExitProgress,
                onUndo: _undoGroupExit,
              ),
            ),
        ],
      ),
    );
  }

  double get _groupExitProgress {
    final deadline = _groupExitDeadline;
    if (deadline == null) return 0;
    return (deadline.difference(DateTime.now()).inMilliseconds / 5000).clamp(
      0.0,
      1.0,
    );
  }
}

class _GroupExitUndoBanner extends StatelessWidget {
  final GroupExitRequest request;
  final int secondsRemaining;
  final double progress;
  final VoidCallback onUndo;

  const _GroupExitUndoBanner({
    required this.request,
    required this.secondsRemaining,
    required this.progress,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1D1D21),
      elevation: 12,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              height: 34,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 2,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.white,
                    ),
                  ),
                  Center(
                    child: Text(
                      '$secondsRemaining',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                request.type == GroupExitType.delete
                    ? 'You deleted the ${request.isChannel ? 'channel' : 'group'}.'
                    : 'You left the ${request.isChannel ? 'channel' : 'group'}.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: onUndo,
              child: const Text(
                'Undo',
                style: TextStyle(color: Color(0xFF64B5F6)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationsScrollBehavior extends ScrollBehavior {
  const _ConversationsScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _ConversationLoadingRow extends StatelessWidget {
  const _ConversationLoadingRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF23262C),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 18,
                  width: 120,
                  decoration: BoxDecoration(
                    color: const Color(0xFF23262C),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 14,
                  width: 180,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1D22),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(
                  color: Color(0xFF2A2D34),
                  thickness: 0.5,
                  height: 0,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
