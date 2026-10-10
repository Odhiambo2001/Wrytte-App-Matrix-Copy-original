import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:path/path.dart' as p;
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/attachment_local_store.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/file_upload_limits.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RoomEventPage {
  final List<ChatMessage> messages;
  final bool hasMore;

  const RoomEventPage({required this.messages, required this.hasMore});
}

class ChatService {
  ChatService._internal();
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;

  static const String _hiddenEventsAccountDataType = 'com.wrytte.hidden_events';
  static const String _pinnedForMeAccountDataType =
      'com.wrytte.pinned_events_for_me';
  static const String _mdlAccountDataType = 'com.wrytte.mdl';
  static const String deliveredToDeviceEventType = 'Delivered';
  static const String voiceListenedEventType =
      'com.wrytte.voice_message_listened';
  static const String groupDeletedMessageType = 'group_deleted';
  static const String groupDeletedEventKey = 'wrytte.group_deleted';
  static const String groupDeletedAtKey = 'wrytte.deleted_at';
  static const String groupDeletedNameKey = 'wrytte.group_name';
  static const String groupDeletedByKey = 'wrytte.deleted_by';
  static const String groupDeletedToDeviceType = 'com.wrytte.group.deleted';
  static const String groupDeletedStateType = 'com.wrytte.group.deleted';

  static bool isGroupDeletedPreview(String? value) {
    final text = value?.trim().toLowerCase() ?? '';
    return text.startsWith('this group has been deleted') ||
        text.endsWith('group has been deleted');
  }

  final _messageController = StreamController<ChatMessage>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _conversationsController =
      StreamController<List<ChatConversation>>.broadcast();
  final Map<String, StreamController<List<ChatMessage>>>
  _roomMessagesControllers = {};

  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<List<ChatConversation>> get conversationsStream async* {
    yield _sortedConversations();
    yield* _conversationsController.stream;
  }

  Stream<List<ChatMessage>> messagesStreamFor(String conversationId) {
    final controller = _roomMessagesControllers.putIfAbsent(
      conversationId,
      () => StreamController<List<ChatMessage>>.broadcast(
        onListen: () => _emitRoomMessages(conversationId),
      ),
    );
    return controller.stream;
  }

  String? _currentUserId;
  String? _currentUserPhone;
  String? _currentUserName;
  bool _isConnected = false;
  bool _loginHistoryPrepared = false;
  Future<void>? _connectFuture;
  Future<void>? _loginHistoryPreparationFuture;
  Future<void>? _historyRestoreFuture;
  Future<void>? _fetchConversationsFuture;
  StreamSubscription? _timelineSub;
  StreamSubscription? _syncSub;
  StreamSubscription? _toDeviceSub;
  bool _handlingSync = false;
  int _runtimeGeneration = 0;
  Timer? _roomsRefreshTimer;
  DateTime? _lastRoomsRefreshAt;
  Timer? _mdlAccountDataTimer;
  Future<void> _mdlAccountDataWriteQueue = Future.value();
  String? _pendingDeliveredEventId;
  String? _pendingDeliveredRoomId;

  static const int _matrixHistoryPageSize = MatrixConfig.historyPageSize;
  static const Duration _roomsRefreshMinInterval = Duration(milliseconds: 1200);

  final Map<String, ChatConversation> _conversationsMap = {};
  final Map<String, List<ChatMessage>> _messagesCache = {};
  final Map<String, Set<String>> _hiddenEventIdsByRoom = {};
  final Map<String, List<String>> _pinnedForMeEventIdsByRoom = {};
  final Map<String, List<String>> _pendingPinnedForMeEventIdsByRoom = {};
  final Map<String, DateTime> _groupJoinCutoffsByRoom = {};
  final Set<String> _createdGroupRoomIds = {};
  final Set<String> _dismissedDeletedGroupRoomIds = {};
  final Set<String> _readConversationIds = {};
  final Set<String> _activeReadConversationIds = {};
  final Set<String> _typingRoomIds = {};
  final Set<String> _deliveredToDeviceEventIds = {};
  final Map<String, String> _lastReadReceiptEventByConversation = {};
  final Map<String, DateTime> _lastReadAtByConversation = {};
  final Map<String, Future<void>> _profileRefreshInFlight = {};
  final Map<String, Future<List<ChatMessage>>> _suggestedPreviewInFlight = {};
  final Map<String, String?> _profileRoomEventTokens = {};
  final Set<String> _profileRoomEventHasMore = {};
  final Map<String, List<ChatMessage>> _profileRoomCachedMessages = {};
  final Map<String, int> _profileRoomCachedOffsets = {};
  final Map<String, Future<RoomEventPage>> _profileRoomEventInFlight = {};
  final Map<String, Future<List<ChatMessage>>> _roomHistoryInFlight = {};
  final Map<String, Set<String>> _attachmentCacheExpectedByRoom = {};
  final Map<String, Set<String>> _attachmentCacheCompleteByRoom = {};
  final Map<String, Set<String>> _attachmentCacheFailedByRoom = {};
  final Map<String, Set<String>> _attachmentCachePendingByRoom = {};
  final Set<String> _attachmentPrefetchInFlight = {};
  final Map<String, Timer> _attachmentCacheSummaryTimers = {};
  final Map<String, String> _channelCacheCategoryByRoom = {};
  final Map<String, int> _channelCachedMessageCountByRoom = {};
  final Map<String, bool> _channelHistoryCachedByRoom = {};
  final Map<String, String> _groupCacheCategoryByRoom = {};
  final Map<String, int> _groupCachedMessageCountByRoom = {};
  final Map<String, bool> _groupHistoryCachedByRoom = {};
  final Map<String, String> _directCacheCategoryByRoom = {};
  final Map<String, int> _directCachedMessageCountByRoom = {};
  final Map<String, bool> _directHistoryCachedByRoom = {};
  Future<void> _suggestedPreviewQueue = Future.value();
  Future<void> _matrixPaginationQueue = Future.value();
  DateTime? _lastMatrixPaginationRequestAt;
  bool _suppressRestoredRoomUnread = false;

  bool get isConnected => _isConnected;
  String? get currentUserId => _currentUserId;
  List<ChatConversation> get cachedConversationsSnapshot =>
      _sortedConversations();

  String _expectedMatrixUserId(String userId) =>
      '@$userId:${MatrixConfig.serverName}';

  Future<void> connect() async {
    final activeUserId = await AuthService.instance.getCurrentUserId();
    final expectedMatrixUserId =
        activeUserId == null || activeUserId.isEmpty
            ? null
            : _expectedMatrixUserId(activeUserId);
    final matrixSessionReady =
        expectedMatrixUserId != null &&
        MatrixClientService.instance.isLoggedIn &&
        MatrixClientService.instance.userId == expectedMatrixUserId;
    if (_isConnected && _currentUserId == activeUserId && matrixSessionReady) {
      return;
    }
    if (_isConnected && _currentUserId != activeUserId) {
      await reset();
    }
    if (_connectFuture != null) return _connectFuture;
    _connectFuture = _connect();
    try {
      await _connectFuture;
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _connect({bool retriedLocalStore = false}) async {
    try {
      final user = await AuthService.instance.getCurrentUser();
      _currentUserId = user?.userId;
      _currentUserPhone = _normalizePhone(
        await AuthService.instance.getSavedPhone() ?? '',
      );
      _currentUserName = await AuthService.instance.getCurrentUsername();
      if (_currentUserId == null || _currentUserId!.isEmpty) {
        throw Exception('User not authenticated');
      }
      await ChatLocalDb.instance.bindOwner(_currentUserId);
      await _loadGroupJoinCutoffs();
      await _loadCreatedGroupRoomIds();
      await _loadDismissedDeletedGroupRoomIds();
      _suppressRestoredRoomUnread = true;

      // Local SQLite is the first-paint source of truth. Hydrate it before
      // restoring or validating Matrix so chats, groups, and channel posts
      // remain visible while the network session is being established.
      await hydrateLocalConversations();

      final expectedMatrixUserId = _expectedMatrixUserId(_currentUserId!);
      apkLog(
        'ChatService.connect',
        'restore start user_id="$_currentUserId" expected="$expectedMatrixUserId"',
      );
      var client = await MatrixAuthService.instance.restore().timeout(
        const Duration(seconds: 30),
      );
      apkLog(
        'ChatService.connect',
        'restore done logged=${client.isLogged()} user_id="${client.userID}"',
      );
      client = await _ensureCurrentMatrixSession(
        expectedMatrixUserId: expectedMatrixUserId,
        userId: _currentUserId!,
        nickname: user?.username ?? _currentUserId!,
        client: client,
      );

      if (!client.isLogged() || client.userID != expectedMatrixUserId) {
        apkLog(
          'ChatService.connect',
          'session mismatch logged=${client.isLogged()} user_id="${client.userID}" expected="$expectedMatrixUserId"',
        );
        throw StateError('Matrix session did not match the current user.');
      }
      _timelineSub ??= client.onTimelineEvent.stream.listen((event) {
        if (_applyVoiceListenedEvent(event)) return;
        if (_applyLiveRedactionEvent(event)) {
          return;
        }

        if (ChatMessage.matrixEditTargetId(event)?.isNotEmpty == true) {
          _applyMatrixEditEvent(event);
          return;
        }

        final message = ChatMessage.fromMatrixEvent(event);
        if (message == null) return;
        if (_isBeforeGroupJoinCutoff(message)) return;

        _cacheMessage(message);
        if (!_isOwnMessage(message, client.userID ?? '')) {
          unawaited(_sendDeliveredToDevice(event, message));
        }
        _refreshMessageStatusesForRoom(event.room);

        if (_isGroupDeletedMatrixEvent(event)) {
          unawaited(
            markGroupDeletedLocally(
              roomId: event.room.id,
              name: _groupDeletedNameFromEvent(event),
              avatarUrl: _groupRoomAvatarUrl(event.room),
              participants:
                  event.room
                      .getParticipants()
                      .map((member) => member.id)
                      .toList(),
              deletedAt: _groupDeletedAtFromEvent(event) ?? message.timestamp,
              deletedBy: _groupDeletedByFromEvent(event),
            ),
          );
        }

        unawaited(
          _refreshPeerProfileFromBackendForMessage(message, reason: 'timeline'),
        );

        // Ignore history replay during startup.
        if (_suppressRestoredRoomUnread) {
          apkLog(
            'ChatService.notify',
            'suppressed startup history '
                'event_id="${message.id}" '
                'room_id="${message.conversationId}"',
          );
          return;
        }

        // Ignore Matrix initial sync replay.
        if (!MatrixChatService.instance.initialSyncComplete) {
          apkLog(
            'ChatService.notify',
            'suppressed initial sync '
                'event_id="${message.id}" '
                'room_id="${message.conversationId}"',
          );
          return;
        }

        apkLog(
          'ChatService.notify',
          'LIVE message '
              'event_id="${message.id}" '
              'room_id="${message.conversationId}"',
        );

        _messageController.add(message);
      });
      _toDeviceSub ??= client.onToDeviceEvent.stream.listen(
        _handleToDeviceEvent,
      );
      final pendingGroupDeletionEvents =
          MatrixClientService.instance.takePendingGroupDeletionEvents();
      for (final event in pendingGroupDeletionEvents) {
        _handleToDeviceEvent(event);
      }
      final cachedToDeviceEvent = client.onToDeviceEvent.value;
      if (cachedToDeviceEvent != null) {
        _handleToDeviceEvent(cachedToDeviceEvent);
      }
      _syncSub ??= client.onSync.stream.listen((update) {
        unawaited(_handleLiveSyncUpdate(update));
      });

      _isConnected = true;
      _connectionController.add(true);
      apkLog(
        'ChatService.connect',
        'ready isConnected=true user_id="${client.userID}" rooms=${client.rooms.length}',
      );
      _refreshConversationsFromRooms();
      unawaited(_finishConnectionWarmup());
    } catch (e) {
      if (!retriedLocalStore && _looksLikeMatrixLocalStoreIoError(e)) {
        apkLog(
          'ChatService.connect',
          'Matrix local store I/O error; deleting Matrix SDK store and retrying error="$e"',
        );
        await _recoverMatrixLocalStore();
        return _connect(retriedLocalStore: true);
      }
      _isConnected = false;
      _connectionController.add(false);
      _errorController.add('Connection failed: $e');
      apkLog('ChatService.connect', 'FAILED error="$e"');
      rethrow;
    }
  }

  bool _looksLikeMatrixLocalStoreIoError(Object error) {
    final raw = error.toString().toUpperCase();
    return raw.contains('SQLITE_IOERR') ||
        raw.contains('DISK I/O ERROR') ||
        raw.contains('SQLITE_IOERR_FSTAT') ||
        raw.contains('SQLITE_READONLY_DBMOVED') ||
        raw.contains('READONLY DATABASE');
  }

  void _handleToDeviceEvent(mx.ToDeviceEvent event) {
    if (event.type == deliveredToDeviceEventType) {
      unawaited(_handleDeliveredToDeviceEvent(event));
      return;
    }
    _handleGroupDeletedToDeviceEvent(event);
  }

  Future<void> _sendDeliveredToDevice(
    mx.Event event,
    ChatMessage message,
  ) async {
    final eventId = event.eventId.trim();
    final senderId = message.senderId.trim();
    if (eventId.isEmpty || senderId.isEmpty || senderId.startsWith('!')) return;
    if (!_deliveredToDeviceEventIds.add(eventId)) return;
    try {
      await MatrixChatService.instance.sendDeliveredToUser(
        userId: senderId,
        roomId: event.room.id,
        eventId: eventId,
      );
      apkLog(
        'Matrix.delivery',
        'sent type="Delivered" room_id="${event.room.id}" '
            'event_id="$eventId" recipient="$senderId"',
      );
    } catch (error) {
      _deliveredToDeviceEventIds.remove(eventId);
      apkLog(
        'Matrix.delivery',
        'send failed room_id="${event.room.id}" event_id="$eventId" error=$error',
      );
    }
  }

  Future<void> _handleDeliveredToDeviceEvent(mx.ToDeviceEvent event) async {
    final roomId = event.content['room_id']?.toString().trim() ?? '';
    final eventId = event.content['event_id']?.toString().trim() ?? '';
    final status = event.content['status']?.toString().trim().toLowerCase();
    final currentUser = MatrixClientService.instance.userId;
    if (roomId.isEmpty || eventId.isEmpty || status != 'delivered') return;
    final room = _roomById(roomId);
    if (room == null) {
      apkLog(
        'Matrix.delivery',
        'ignored unknown room_id="$roomId" event_id="$eventId" sender="${event.senderId}"',
      );
      return;
    }
    if (currentUser != null && event.senderId == currentUser) return;

    final messages = _messagesCache[roomId];
    final messageIndex =
        messages?.indexWhere((message) => message.id == eventId) ?? -1;
    if (messageIndex >= 0 &&
        currentUser != null &&
        !_isOwnMessage(messages![messageIndex], currentUser)) {
      return;
    }
    final existingMdl =
        MatrixClientService
            .instance
            .client
            .accountData[_mdlAccountDataType]
            ?.content;
    final existingRoomId = existingMdl?['room_id']?.toString();
    final existingEventId = existingMdl?['last_delivered_event_id']?.toString();
    if (messageIndex >= 0 &&
        existingRoomId == roomId &&
        existingEventId != null) {
      final previousIndex = messages!.indexWhere(
        (message) => message.id == existingEventId,
      );
      if (previousIndex >= messageIndex) return;
    }

    if (messageIndex >= 0) {
      _setCachedMessageStatus(roomId, eventId, MessageStatus.delivered);
    }

    _pendingDeliveredRoomId = roomId;
    _pendingDeliveredEventId = eventId;
    apkLog(
      'Matrix.delivery',
      'received room_id="$roomId" event_id="$eventId" sender="${event.senderId}"',
    );
    _scheduleMdlAccountDataWrite();
  }

  void _setCachedMessageStatus(
    String roomId,
    String eventId,
    MessageStatus status,
  ) {
    final messages = _messagesCache[roomId];
    if (messages == null) return;
    final index = messages.indexWhere((message) => message.id == eventId);
    if (index < 0) return;
    final message = messages[index];
    if (message.status == MessageStatus.read ||
        message.status == MessageStatus.failed ||
        message.status == MessageStatus.sending) {
      return;
    }
    if (message.status == status) return;
    final updated = message.copyWith(status: status);
    messages[index] = updated;
    unawaited(ChatLocalDb.instance.saveMessages(messages));
    _messageController.add(updated);
    _emitRoomMessages(roomId);
    _emitConversations();
  }

  void updateLocalTypingState(String roomId, bool isTyping) {
    final id = roomId.trim();
    if (id.isEmpty) return;
    if (isTyping) {
      _typingRoomIds.add(id);
      _mdlAccountDataTimer?.cancel();
      _mdlAccountDataTimer = null;
      return;
    }
    _typingRoomIds.remove(id);
    if (_typingRoomIds.isEmpty && _pendingDeliveredEventId != null) {
      _scheduleMdlAccountDataWrite();
    }
  }

  void _scheduleMdlAccountDataWrite() {
    _mdlAccountDataTimer?.cancel();
    _mdlAccountDataTimer = null;
    if (_pendingDeliveredEventId == null || _typingRoomIds.isNotEmpty) return;
    unawaited(_writePendingMdlAccountData());
  }

  void _retryMdlAccountDataWrite() {
    _mdlAccountDataTimer?.cancel();
    if (_pendingDeliveredEventId == null || _typingRoomIds.isNotEmpty) return;
    _mdlAccountDataTimer = Timer(const Duration(seconds: 2), () {
      _mdlAccountDataTimer = null;
      _scheduleMdlAccountDataWrite();
    });
  }

  Future<void> _writePendingMdlAccountData() async {
    final eventId = _pendingDeliveredEventId;
    final roomId = _pendingDeliveredRoomId;
    final userId = MatrixClientService.instance.userId;
    if (eventId == null || roomId == null || userId == null) return;
    if (_typingRoomIds.isNotEmpty) return;
    final previous = _mdlAccountDataWriteQueue;
    final write = previous.then((_) async {
      if (_typingRoomIds.isNotEmpty) return;
      await MatrixClientService.instance.client.setAccountData(
        userId,
        _mdlAccountDataType,
        {
          'last_delivered_event_id': eventId,
          'status': 'delivered',
          'room_id': roomId,
        },
      );
      if (_pendingDeliveredEventId == eventId &&
          _pendingDeliveredRoomId == roomId) {
        _pendingDeliveredEventId = null;
        _pendingDeliveredRoomId = null;
      }
      final room = _roomById(roomId);
      if (room != null) _refreshMessageStatusesForRoom(room);
      apkLog(
        'Matrix.delivery',
        'account_data_saved type="MDL" room_id="$roomId" '
            'last_delivered_event_id="$eventId" status="delivered"',
      );
    });
    _mdlAccountDataWriteQueue = write.catchError((Object error) {
      apkLog('Matrix.delivery', 'account data save failed error=$error');
      _retryMdlAccountDataWrite();
    });
    await _mdlAccountDataWriteQueue;
  }

  void _handleGroupDeletedToDeviceEvent(mx.ToDeviceEvent event) {
    if (event.type != groupDeletedToDeviceType) return;
    final roomId = event.content['room_id']?.toString().trim() ?? '';
    final groupName =
        event.content[groupDeletedNameKey]?.toString().trim() ?? '';
    if (roomId.isEmpty || groupName.isEmpty) return;
    final participantValues = event.content['participants'];
    final participants =
        participantValues is List
            ? participantValues
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty)
                .toList()
            : const <String>[];
    final deletedAt = DateTime.tryParse(
      event.content[groupDeletedAtKey]?.toString() ?? '',
    );
    apkLog(
      'ChatService.groupDeleted',
      'to-device received room_id="$roomId" name="$groupName" sender="${event.senderId}"',
    );
    unawaited(
      markGroupDeletedLocally(
        roomId: roomId,
        name: groupName,
        avatarUrl: event.content['avatar_url']?.toString(),
        participants: participants,
        deletedAt: deletedAt,
        deletedBy:
            event.content[groupDeletedByKey]?.toString().trim() ??
            event.senderId,
      ),
    );
  }

  Future<void> _recoverMatrixLocalStore() async {
    _isConnected = false;
    await _timelineSub?.cancel();
    await _syncSub?.cancel();
    await _toDeviceSub?.cancel();
    _timelineSub = null;
    _syncSub = null;
    _toDeviceSub = null;

    // Try SDK delete first
    try {
      await MatrixClientService.instance.deleteLocalStore().timeout(
        const Duration(seconds: 5),
      );
    } catch (_) {}

    // Then manually nuke every possible Matrix DB file
    try {
      final supportDir = await getApplicationSupportDirectory();
      final docsDir = await getApplicationDocumentsDirectory();
      final cacheDir = await getApplicationCacheDirectory();
      final tempDir = await getTemporaryDirectory();

      for (final base in [
        supportDir.path,
        docsDir.path,
        cacheDir.path,
        tempDir.path,
      ]) {
        for (final name in [
          'matrix',
          'matrix_media',
          'matrix_sdk',
          'hive',
          'db',
          'client',
        ]) {
          // Delete directories
          final dir = Directory(p.join(base, name));
          if (await dir.exists()) await dir.delete(recursive: true);

          // Delete flat DB files
          for (final ext in ['.db', '.sqlite', '.sqlite3']) {
            final file = File(p.join(base, '$name$ext'));
            if (await file.exists()) await file.delete();
          }
        }
      }
      apkLog('ChatService.connect', 'Matrix store manually wiped');
    } catch (e) {
      apkLog(
        'ChatService.connect',
        'Matrix store manual wipe failed error="$e"',
      );
    }

    // Critical: wait for OS to release file handles before retrying
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<mx.Client> _ensureCurrentMatrixSession({
    required String expectedMatrixUserId,
    required String userId,
    required String nickname,
    required mx.Client client,
  }) async {
    var current = client;

    if (current.isLogged() && current.userID != expectedMatrixUserId) {
      apkLog(
        'ChatService.connect',
        'clearing wrong Matrix session current="${current.userID}" expected="$expectedMatrixUserId"',
      );
      await MatrixAuthService.instance.clearLocalSession().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      current = MatrixClientService.instance.client;
    }

    if (!current.isLogged() || current.userID != expectedMatrixUserId) {
      current = await _loginCurrentMatrixSession(
        expectedMatrixUserId: expectedMatrixUserId,
        userId: userId,
        nickname: nickname,
        forceFreshSession: false,
      );
    }

    if (current.isLogged() && current.userID == expectedMatrixUserId) {
      final valid = await MatrixAuthService.instance.validateCurrentSession(
        expectedUserId: expectedMatrixUserId,
      );
      if (!valid) {
        apkLog(
          'ChatService.connect',
          'Matrix token invalid; forcing fresh login user_id="$userId" expected="$expectedMatrixUserId"',
        );
        current = await _loginCurrentMatrixSession(
          expectedMatrixUserId: expectedMatrixUserId,
          userId: userId,
          nickname: nickname,
          forceFreshSession: true,
        );
      }
    }

    if (current.isLogged() && current.userID != expectedMatrixUserId) {
      apkLog(
        'ChatService.connect',
        'retry clearing wrong Matrix session current="${current.userID}" expected="$expectedMatrixUserId"',
      );
      await MatrixAuthService.instance.clearLocalSession().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      current = await _loginCurrentMatrixSession(
        expectedMatrixUserId: expectedMatrixUserId,
        userId: userId,
        nickname: nickname,
        forceFreshSession: true,
      );
    }

    return current;
  }

  Future<mx.Client> _loginCurrentMatrixSession({
    required String expectedMatrixUserId,
    required String userId,
    required String nickname,
    required bool forceFreshSession,
  }) async {
    apkLog(
      'ChatService.connect',
      'Matrix login required user_id="$userId" expected="$expectedMatrixUserId"',
    );
    try {
      await AuthService.instance
          .loginToMatrix(
            userId: userId,
            nickname: nickname,
            forceFreshSession: forceFreshSession,
          )
          .timeout(const Duration(seconds: 75));
    } on TimeoutException catch (e) {
      final current = MatrixClientService.instance.client;
      if (current.isLogged() && current.userID == expectedMatrixUserId) {
        apkLog(
          'ChatService.connect',
          'Matrix login timeout after session became ready; continuing user_id="${current.userID}"',
        );
        return current;
      }
      apkLog(
        'ChatService.connect',
        'Matrix login timeout without usable session expected="$expectedMatrixUserId" current="${current.userID}" error="$e"',
      );
      rethrow;
    }

    final current = MatrixClientService.instance.client;
    apkLog(
      'ChatService.connect',
      'Matrix login returned logged=${current.isLogged()} user_id="${current.userID}"',
    );
    return current;
  }

  Future<void> _finishConnectionWarmup() async {
    try {
      await MatrixChatService.instance.ensureSyncedAndAutoJoinInvites();
      _refreshConversationsFromRooms();
      final userId = _currentUserId;
      if (userId != null && userId.isNotEmpty) {
        unawaited(ContactService().syncLocalContactsToBackend(userId));
      }

      // A process restart often restores an existing Matrix session instead
      // of passing through AuthService's fresh-login path. Resume the complete
      // all-room history job here as well, otherwise only DMs are backfilled
      // and joined channels/groups remain history_cached=false indefinitely.
      unawaited(_resumeAllRoomHistoryAfterStartupSettles());
    } catch (e) {
      // ✅ Log the error but DO NOT lift suppression here.
      // Suppression is always lifted in the finally block below,
      // AFTER history work is done (or has failed).
      debugPrint('[ChatService] connection warmup error: $e');
    } finally {
      // ✅ Suppression lifts exactly once, regardless of success or failure,
      // and always AFTER the try block completes.
      _suppressRestoredRoomUnread = false;

      // These always need to run after warmup, success or not.
      _refreshConversationsFromRooms();

      apkLog(
        'ChatService.connect',
        'startup sync complete; notifications enabled',
      );
    }
  }

  Future<void> _resumeAllRoomHistoryAfterStartupSettles() async {
    // Let the SDK finish /sync and any internal last-event gap repair before
    // starting potentially deep pagination across every joined room.
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!_isConnected) return;
    try {
      if (_loginHistoryPrepared) {
        apkLog(
          'Matrix.loginHydration',
          'startup resume full backfill user_id="$_currentUserId"',
        );
        await _backfillAllHistoryAfterLogin();
      } else {
        apkLog(
          'Matrix.loginHydration',
          'startup prepare all-room history user_id="$_currentUserId"',
        );
        await prepareAllHistoryForLogin();
      }
    } catch (error) {
      apkLog(
        'Matrix.loginHydration',
        'startup all-room backfill failed error="$error"; retry on next reconnect',
      );
    }
  }

  Future<void> restoreAllRoomHistoryFromServer() {
    final pending = _historyRestoreFuture;
    if (pending != null) return pending;

    final future = _restoreAllRoomHistoryFromServer();
    _historyRestoreFuture = future;
    return future.whenComplete(() {
      if (identical(_historyRestoreFuture, future)) {
        _historyRestoreFuture = null;
      }
    });
  }

  /// Completes the login-time server-to-local hydration barrier.
  ///
  /// Once this returns, the recent `/sync` timeline for every joined DM,
  /// group, and channel has been written to Wrytte's local SQLite cache.
  /// Conversation screens can render locally while older history continues
  /// backfilling in the background.
  Future<void> prepareAllHistoryForLogin() {
    if (_loginHistoryPrepared) return Future<void>.value();
    final pending = _loginHistoryPreparationFuture;
    if (pending != null) return pending;
    final future = _prepareAllHistoryForLogin();
    _loginHistoryPreparationFuture = future;
    return future.whenComplete(() {
      if (identical(_loginHistoryPreparationFuture, future)) {
        _loginHistoryPreparationFuture = null;
      }
    });
  }

  Future<void> _prepareAllHistoryForLogin() async {
    await connect();
    apkLog(
      'Matrix.loginHydration',
      'start user_id="$_currentUserId" rooms=${MatrixClientService.instance.client.rooms.length}',
    );
    await MatrixChatService.instance.ensureSyncedAndAutoJoinInvites();
    _refreshConversationsFromRooms(force: true);
    final joinedRooms =
        MatrixClientService.instance.client.rooms
            .where((room) => room.membership == mx.Membership.join)
            .toList();
    // Persist the recent timeline already delivered by /sync for every room.
    // Do not paginate to the beginning of large rooms on the login screen.
    for (final room in joinedRooms) {
      await _restoreRoomHistoryFromServer(room, maxHistoryPages: 0);
    }
    _refreshConversationsFromRooms(force: true);
    await ChatLocalDb.instance.replaceConversations(
      _conversationsMap.values.toList(),
    );
    await hydrateLocalConversations();
    _loginHistoryPrepared = true;
    apkLog(
      'Matrix.loginHydration',
      'recent complete user_id="$_currentUserId" '
          'conversations=${_conversationsMap.length}; full backfill queued',
    );
    unawaited(_backfillAllHistoryAfterLogin());
  }

  Future<void> _backfillAllHistoryAfterLogin() async {
    // Give Home and its first local paint priority over deep pagination.
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!_isConnected || !_loginHistoryPrepared) return;
    apkLog('Matrix.loginHydration', 'background full backfill start');
    await restoreAllRoomHistoryFromServer();
    if (!_isConnected) return;
    _refreshConversationsFromRooms(force: true);
    await ChatLocalDb.instance.replaceConversations(
      _conversationsMap.values.toList(),
    );
    apkLog('Matrix.loginHydration', 'background full backfill complete');
  }

  Future<void> _restoreAllRoomHistoryFromServer() async {
    await _withMatrixTokenRetry('restoreAllRoomHistoryFromServer', () async {
      final client = MatrixClientService.instance.client;
      final joinedRooms = client.rooms.where(
        (room) => room.membership == mx.Membership.join,
      );

      for (final room in joinedRooms) {
        await _restoreRoomHistoryFromServer(room);
      }
    });
  }

  Future<List<ChatMessage>> _restoreRoomHistoryFromServer(
    mx.Room room, {
    int? maxHistoryPages,
  }) async {
    final pending = _roomHistoryInFlight[room.id];
    if (pending != null) return pending;
    final future = _restoreRoomHistoryFromServerInternal(
      room,
      maxHistoryPages: maxHistoryPages,
      runtimeGeneration: _runtimeGeneration,
    );
    _roomHistoryInFlight[room.id] = future;
    try {
      return await future;
    } finally {
      if (identical(_roomHistoryInFlight[room.id], future)) {
        _roomHistoryInFlight.remove(room.id);
      }
    }
  }

  Future<List<ChatMessage>> _restoreRoomHistoryFromServerInternal(
    mx.Room room, {
    int? maxHistoryPages,
    required int runtimeGeneration,
  }) async {
    mx.Timeline? timeline;
    try {
      timeline = await room.getTimeline(limit: null);
      if (!_isConnected || runtimeGeneration != _runtimeGeneration) {
        return const <ChatMessage>[];
      }
      final localById = {
        for (final message in await ChatLocalDb.instance.loadMessages(room.id))
          message.id: message,
      };
      final hiddenIds = _hiddenEventIdsForRoom(room.id, room: room);
      final groupJoinCutoff = _groupJoinCutoffForRoom(room);

      Future<List<ChatMessage>> persistCurrentTimeline(String stage) async {
        if (!_isConnected || runtimeGeneration != _runtimeGeneration) {
          return const <ChatMessage>[];
        }
        final messages = _messagesFromMatrixEvents(
          timeline!.events,
          localById: localById,
          hiddenIds: hiddenIds,
          groupJoinCutoff: groupJoinCutoff,
        );

        final restoredReadAt = _lastReadAtByConversation[room.id];
        if (restoredReadAt != null) {
          _readConversationIds.add(room.id);
        }

        for (final message in messages) {
          localById[message.id] = message;
          _cacheMessage(message, countUnread: false, publish: false);
        }
        await ChatLocalDb.instance.saveMessages(messages);
        _refreshMessageStatusesForRoom(room);
        _emitRoomMessages(room.id);
        _emitConversations();
        apkLog(
          'Matrix.history',
          'published room_id="${room.id}" stage="$stage" '
              'messages=${messages.length}',
        );
        return messages;
      }

      // Make the recent /sync timeline visible before requesting any older
      // pages. This is shared by DMs, groups, and channels.
      var messages = await persistCurrentTimeline('recent');
      final historyAlreadyComplete = await ChatLocalDb.instance
          .isRoomHistoryComplete(room.id);
      if (historyAlreadyComplete && maxHistoryPages == null) {
        final completeLocal = await loadCachedMessages(room.id);
        final mediaComplete = await _cacheAllAttachmentsForRoom(
          room.id,
          completeLocal,
        );
        apkLog(
          'Matrix.history',
          'skip pagination room_id="${room.id}" reason="local history complete" '
              'messages=${completeLocal.length} media_complete=$mediaComplete',
        );
        return completeLocal;
      }
      var page = 0;
      var reachedHistoryStart = !timeline.canRequestHistory;

      while (_isConnected &&
          timeline.canRequestHistory &&
          (maxHistoryPages == null || page < maxHistoryPages)) {
        final beforeCount = timeline.events.length;
        final beforeToken = room.prev_batch;
        page += 1;
        await _enqueueMatrixPaginationRequest(
          () => timeline!.requestHistory(
            historyCount: _matrixHistoryPageSize,
            filter: mx.StateFilter(lazyLoadMembers: true),
          ),
        );
        if (!_isConnected || runtimeGeneration != _runtimeGeneration) {
          apkLog(
            'Matrix.history',
            'cancelled room_id="${room.id}" reason="session ended"',
          );
          return messages;
        }
        final afterCount = timeline.events.length;
        final afterToken = room.prev_batch;
        apkLog(
          'Matrix.history',
          'page room_id="${room.id}" page=$page before=$beforeCount '
              'after=$afterCount added=${afterCount - beforeCount} '
              'canMore=${timeline.canRequestHistory}',
        );

        if (afterCount > beforeCount) {
          // Deep history can take minutes for large rooms. Persist and notify
          // after every page so an open conversation updates progressively.
          messages = await persistCurrentTimeline('page_$page');
        }

        if (afterCount <= beforeCount) {
          if (timeline.canRequestHistory &&
              afterToken != null &&
              afterToken.isNotEmpty &&
              afterToken != beforeToken) {
            apkLog(
              'Matrix.history',
              'continue room_id="${room.id}" page=$page '
                  'reason="empty page advanced pagination token"',
            );
            continue;
          }
          apkLog(
            'Matrix.history',
            'stop room_id="${room.id}" page=$page '
                'reason="no events and pagination token did not advance"',
          );
          reachedHistoryStart = true;
          break;
        }
      }
      reachedHistoryStart = reachedHistoryStart || !timeline.canRequestHistory;
      await ChatLocalDb.instance.updateRoomCacheProgress(room.id);
      if (maxHistoryPages == null && reachedHistoryStart && _isConnected) {
        await ChatLocalDb.instance.markRoomHistoryComplete(room.id);
        messages = await loadCachedMessages(room.id);
        // Keep the in-memory audit snapshot in sync with the durable marker.
        // Otherwise MediaCache.room can report history_cached=false directly
        // before Matrix.history reports this same room as offline_ready.
        if (_channelCacheCategoryByRoom.containsKey(room.id)) {
          _channelHistoryCachedByRoom[room.id] = true;
          _channelCachedMessageCountByRoom[room.id] = messages.length;
        }
        if (_groupCacheCategoryByRoom.containsKey(room.id)) {
          _groupHistoryCachedByRoom[room.id] = true;
          _groupCachedMessageCountByRoom[room.id] = messages.length;
        }
        if (_directCacheCategoryByRoom.containsKey(room.id)) {
          _directHistoryCachedByRoom[room.id] = true;
          _directCachedMessageCountByRoom[room.id] = messages.length;
        }
        final mediaComplete = await _cacheAllAttachmentsForRoom(
          room.id,
          messages,
        );
        if (mediaComplete) {
          apkLog(
            'Matrix.history',
            'offline_ready room_id="${room.id}" messages=${messages.length} '
                'history_complete=true media_complete=true',
          );
        } else {
          apkLog(
            'Matrix.history',
            'offline_incomplete room_id="${room.id}" messages=${messages.length} '
                'history_complete=true media_complete=false; retry queued for next online pass',
          );
        }
      }
      apkLog(
        'Matrix.history',
        'restored room_id="${room.id}" messages=${messages.length}',
      );
      return messages;
    } catch (e) {
      debugPrint('[ChatService] restore room history skipped: $e');
      apkLog(
        'Matrix.history',
        'restore failed room_id="${room.id}" error="$e"',
      );
      return const [];
    } finally {
      timeline?.cancelSubscriptions();
    }
  }

  Future<void> _waitForConnection() async {
    if (_isConnected) return;
    await connect();
  }

  List<ChatMessage> _messagesFromMatrixEvents(
    Iterable<mx.Event> events, {
    required Map<String, ChatMessage> localById,
    required Set<String> hiddenIds,
    DateTime? groupJoinCutoff,
  }) {
    final sortedEvents =
        events.toList()
          ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    final byId = <String, ChatMessage>{};

    for (final event in sortedEvents) {
      if (ChatMessage.matrixEditTargetId(event) != null) continue;
      if (groupJoinCutoff != null &&
          event.originServerTs.isBefore(groupJoinCutoff)) {
        continue;
      }
      final message = ChatMessage.fromMatrixEvent(event);
      if (message == null) continue;
      if (_isGroupDeletedMatrixEvent(event)) {
        unawaited(
          markGroupDeletedLocally(
            roomId: event.room.id,
            name: _groupDeletedNameFromEvent(event),
            avatarUrl: _groupRoomAvatarUrl(event.room),
            participants:
                event.room
                    .getParticipants()
                    .map((member) => member.id)
                    .toList(),
            deletedAt: _groupDeletedAtFromEvent(event) ?? message.timestamp,
            deletedBy: _groupDeletedByFromEvent(event),
          ),
        );
      }
      final local = localById[message.id];
      final isHidden =
          hiddenIds.contains(message.id) || local?.isDeletedForMe == true;
      if (isHidden) {
        unawaited(ChatLocalDb.instance.deleteMessageForMe(message.id));
      }
      byId[message.id] =
          local == null
              ? (isHidden ? message.copyWith(isDeletedForMe: true) : message)
              : message.copyWith(
                content:
                    local.isDeletedForEveryone
                        ? (local.content.toLowerCase().startsWith(
                              'this message was deleted',
                            )
                            ? local.content
                            : (_isOwnMessage(
                                  message,
                                  MatrixClientService.instance.client.userID ??
                                      _currentUserId ??
                                      '',
                                )
                                ? 'This message was deleted'
                                : 'This message was deleted by admin'))
                        : message.content,
                isStarred: local.isStarred,
                isDeletedForMe: local.isDeletedForMe || isHidden,
                isDeletedForEveryone:
                    message.isDeletedForEveryone || local.isDeletedForEveryone,
                isEdited: local.isEdited,
                isVoiceListened: local.isVoiceListened,
              );
    }

    for (final event in sortedEvents) {
      _applyMatrixEditEventToMap(event, byId);
      _applyVoiceListenedEventToMap(event, byId);
    }

    final messages =
        byId.values.where((message) => !_isHiddenForMe(message)).toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  void _applyMatrixEditEventToMap(
    mx.Event event,
    Map<String, ChatMessage> messagesById,
  ) {
    final targetId = ChatMessage.matrixEditTargetId(event);
    if (targetId == null || targetId.isEmpty) return;
    final original = messagesById[targetId];
    if (original == null || original.senderId != event.senderId) return;
    final edit = ChatMessage.fromMatrixEvent(event);
    if (edit == null || edit.content.trim().isEmpty) return;
    messagesById[targetId] = original.copyWith(
      content: edit.content,
      isEdited: true,
    );
  }

  void _applyVoiceListenedEventToMap(
    mx.Event event,
    Map<String, ChatMessage> messagesById,
  ) {
    if (event.type != voiceListenedEventType) return;
    final targetId = event.content['voice_event_id']?.toString().trim() ?? '';
    final original = messagesById[targetId];
    if (original == null ||
        !original.isVoiceNote ||
        _isOwnMessage(original, event.senderId)) {
      return;
    }
    messagesById[targetId] = original.copyWith(isVoiceListened: true);
  }

  Future<T> _withMatrixTokenRetry<T>(
    String action,
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } catch (e) {
      if (!MatrixAuthService.isUnknownToken(e)) rethrow;
      apkLog(
        'Matrix.auth',
        '$action got M_UNKNOWN_TOKEN; forcing fresh Matrix login and retrying',
      );
      await _refreshCurrentMatrixSession();
      return operation();
    }
  }

  bool _isMatrixRateLimitError(Object error) =>
      error.toString().contains('M_LIMIT_EXCEEDED');

  Future<T> _enqueueMatrixPaginationRequest<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _matrixPaginationQueue = _matrixPaginationQueue.then((_) async {
      try {
        const minimumGap = Duration(milliseconds: 750);
        final last = _lastMatrixPaginationRequestAt;
        if (last != null) {
          final remaining = minimumGap - DateTime.now().difference(last);
          if (remaining > Duration.zero) {
            await Future<void>.delayed(remaining);
          }
        }

        for (var attempt = 0; ; attempt++) {
          try {
            _lastMatrixPaginationRequestAt = DateTime.now();
            completer.complete(await operation());
            break;
          } catch (error, stackTrace) {
            if (!_isMatrixRateLimitError(error) || attempt >= 3) {
              completer.completeError(error, stackTrace);
              break;
            }
            final delay = Duration(seconds: 2 << attempt);
            apkLog(
              'Matrix.rateLimit',
              'pagination retry=${attempt + 1} delay_ms=${delay.inMilliseconds}',
            );
            await Future<void>.delayed(delay);
          }
        }
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  Future<void> _handleLiveSyncUpdate(mx.SyncUpdate update) async {
    _refreshAllMessageStatuses();
    if (!update.hasRoomUpdate) return;
    if (_handlingSync) return;
    _handlingSync = true;
    try {
      if (update.rooms?.invite?.isNotEmpty ?? false) {
        await MatrixChatService.instance.autoJoinTrustedDirectInvites();
      }
      _refreshConversationsFromRooms();
    } finally {
      _handlingSync = false;
    }
  }

  bool _isDisplayableMessage(ChatMessage? message) {
    if (message == null) return false;
    return message.content.trim().isNotEmpty ||
        (message.attachmentUrl?.trim().isNotEmpty ?? false);
  }

  bool _isHiddenForMe(ChatMessage message) {
    if (message.isDeletedForMe) return true;
    final roomId = message.conversationId.trim();
    final eventId = message.id.trim();
    if (roomId.isEmpty || eventId.isEmpty) return false;
    return _hiddenEventIdsForRoom(roomId).contains(eventId);
  }

  Set<String> _hiddenEventIdsForRoom(String roomId, {mx.Room? room}) {
    final normalizedRoomId = roomId.trim();
    if (normalizedRoomId.isEmpty) return <String>{};
    final matrixRoom = room ?? _roomById(normalizedRoomId);
    if (matrixRoom != null) _syncHiddenEventsFromRoom(matrixRoom);
    return Set<String>.from(_hiddenEventIdsByRoom[normalizedRoomId] ?? {});
  }

  void _syncHiddenEventsFromRoom(mx.Room room) {
    final content = room.roomAccountData[_hiddenEventsAccountDataType]?.content;
    if (content == null) return;
    final rawIds = content['hidden_event_ids'];
    if (rawIds is! Iterable) return;
    final ids =
        rawIds
            .whereType<Object>()
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toSet();
    final existing = _hiddenEventIdsByRoom[room.id] ?? <String>{};
    _hiddenEventIdsByRoom[room.id] = {...existing, ...ids};
  }

  void _syncPinnedForMeFromRoom(mx.Room room) {
    final content = room.roomAccountData[_pinnedForMeAccountDataType]?.content;
    final rawIds = content?['pinned_event_ids'];
    if (rawIds is! Iterable) {
      _pinnedForMeEventIdsByRoom.putIfAbsent(room.id, () => <String>[]);
      return;
    }
    final ids =
        rawIds
            .whereType<Object>()
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList();
    final pending = _pendingPinnedForMeEventIdsByRoom[room.id];
    if (pending != null && !listEquals(pending, ids)) return;
    _pendingPinnedForMeEventIdsByRoom.remove(room.id);
    _pinnedForMeEventIdsByRoom[room.id] = ids;
  }

  Future<ChatMessage> sendMessage(ChatMessage message) async {
    try {
      return await _withMatrixTokenRetry('sendMessage', () async {
        await _waitForConnection();
        final client = MatrixClientService.instance.client;
        final room = _roomForMessage(message);
        if (message.conversationId.trim() != room.id) {
          throw StateError(
            'Message room mismatch: ${message.conversationId} != ${room.id}',
          );
        }
        final isGroupRoom = MatrixChatService.instance.isMatrixGroupRoom(room);
        if (!message.receiverId.trim().startsWith('!')) {
          await MatrixChatService.instance.ensurePeerInvited(
            roomId: room.id,
            matrixUserId: _toMatrixUserId(message.receiverId),
          );
        }
        apkLog(
          'Matrix.send',
          'PUT /_matrix/client/r0/rooms/${room.id}/send/m.room.message user_id="${client.userID}" room_id="${room.id}"',
        );
        final eventId = await room.sendEvent(_buildMessageContent(message));
        apkLog(
          'Matrix.send',
          'Sent event to roomserver event_id="$eventId" room_id="${room.id}" user_id="${client.userID}" type="m.room.message"',
        );
        final sent = message.copyWith(
          id: eventId ?? message.id,
          conversationId: room.id,
          senderId: client.userID ?? _currentUserId ?? '',
          receiverId: isGroupRoom ? room.id : message.receiverId,
          timestamp: DateTime.now(),
          status: MessageStatus.sent,
          senderPhone: _currentUserPhone,
        );
        _cacheMessage(sent);
        unawaited(
          _refreshPeerProfileFromBackendForMessage(sent, reason: 'sendMessage'),
        );
        return sent;
      });
    } catch (e) {
      _errorController.add('Failed to send: $e');
      rethrow;
    }
  }

  Future<void> sendVoiceMessage({
    required String receiverID,
    required String filePath,
    required int durationSeconds,
    String? conversationId,
    String senderName = 'New voice message',
  }) async {
    await _withMatrixTokenRetry('sendVoiceMessage', () async {
      await _waitForConnection();
      final requestedRoomId = conversationId?.trim() ?? '';
      final room =
          requestedRoomId.isNotEmpty
              ? _roomById(requestedRoomId)
              : receiverID.trim().startsWith('!')
              ? _roomById(receiverID.trim())
              : await _directRoom(receiverID);
      if (room == null) {
        throw StateError(
          'Unknown Matrix room: ${conversationId ?? receiverID}',
        );
      }
      final isGroupRoom = MatrixChatService.instance.isMatrixGroupRoom(room);
      await FileUploadLimits.validatePath(
        filePath,
        maxBytes: FileUploadLimits.voiceMessageMaxBytes,
        label: 'Voice message',
      );
      final bytes = await File(filePath).readAsBytes();
      final file = mx.MatrixAudioFile(
        bytes: bytes,
        name: p.basename(filePath),
        // MessageInputField records AAC ADTS data to a `.aac` file.
        mimeType: 'audio/aac',
        duration: durationSeconds * 1000,
      );
      final eventId = await room.sendAudioEvent(
        file,
        durationInMs: durationSeconds * 1000,
      );
      final local = ChatMessage(
        id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: room.id,
        senderId:
            MatrixClientService.instance.client.userID ?? _currentUserId ?? '',
        receiverId: isGroupRoom ? room.id : _toMatrixUserId(receiverID),
        content: 'Voice message',
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        attachmentUrl: filePath,
        attachmentType: 'voice',
        voiceDuration: durationSeconds,
        senderPhone: _currentUserPhone,
      );
      _cacheMessage(local);
      unawaited(
        _refreshPeerProfileFromBackendForMessage(
          local,
          reason: 'sendVoiceMessage',
        ),
      );
      _messageController.add(local);
    });
  }

  Future<void> sendVideoMessage({
    required String receiverID,
    required String filePath,
    required int durationSeconds,
    String? conversationId,
  }) async {
    await _withMatrixTokenRetry('sendVideoMessage', () async {
      await _waitForConnection();
      final requestedRoomId = conversationId?.trim() ?? '';
      final room =
          requestedRoomId.isNotEmpty
              ? _roomById(requestedRoomId)
              : receiverID.trim().startsWith('!')
              ? _roomById(receiverID.trim())
              : await _directRoom(receiverID);
      if (room == null) {
        throw StateError(
          'Unknown Matrix room: ${conversationId ?? receiverID}',
        );
      }
      final isGroupRoom = MatrixChatService.instance.isMatrixGroupRoom(room);
      await FileUploadLimits.validatePath(
        filePath,
        maxBytes: FileUploadLimits.videoMessageMaxBytes,
        label: 'Video message',
      );
      final bytes = await File(filePath).readAsBytes();
      final file = mx.MatrixVideoFile(
        bytes: bytes,
        name: p.basename(filePath),
        mimeType: 'video/mp4',
        duration: durationSeconds * 1000,
      );
      final eventId = await room.sendFileEvent(file);
      final local = ChatMessage(
        id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: room.id,
        senderId:
            MatrixClientService.instance.client.userID ?? _currentUserId ?? '',
        receiverId: isGroupRoom ? room.id : _toMatrixUserId(receiverID),
        content: 'Video message',
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        attachmentUrl: filePath,
        attachmentType: 'video',
        voiceDuration: durationSeconds,
        senderPhone: _currentUserPhone,
      );
      _cacheMessage(local);
      unawaited(
        _refreshPeerProfileFromBackendForMessage(
          local,
          reason: 'sendVideoMessage',
        ),
      );
      _messageController.add(local);
    });
  }

  Future<ChatMessage> sendAttachmentMessage({
    required String receiverID,
    required String filePath,
    required String attachmentType,
    String? conversationId,
    String? caption,
    int? mediaWidth,
    int? mediaHeight,
  }) async {
    return _withMatrixTokenRetry('sendAttachmentMessage', () async {
      await _waitForConnection();
      final existingRoomId = conversationId?.trim() ?? '';
      final room =
          existingRoomId.isNotEmpty
              ? _roomById(existingRoomId) ??
                  (receiverID.trim().startsWith('!')
                      ? null
                      : await _directRoom(receiverID))
              : receiverID.trim().startsWith('!')
              ? _roomById(receiverID.trim())
              : await _directRoom(receiverID);
      if (room == null) {
        throw StateError(
          'Unknown Matrix room: ${conversationId ?? receiverID}',
        );
      }
      if (!receiverID.trim().startsWith('!')) {
        await MatrixChatService.instance.ensurePeerInvited(
          roomId: room.id,
          matrixUserId: _toMatrixUserId(receiverID),
        );
      }
      await FileUploadLimits.validatePath(
        filePath,
        maxBytes: FileUploadLimits.chatFileMaxBytes,
        label:
            attachmentType == 'image'
                ? 'Photo'
                : attachmentType == 'video'
                ? 'Video'
                : 'File',
      );
      final bytes = await File(filePath).readAsBytes();
      final matrixFile = switch (attachmentType) {
        'video' => mx.MatrixVideoFile(
          bytes: bytes,
          name: p.basename(filePath),
          mimeType: 'video/mp4',
        ),
        'image' => mx.MatrixImageFile(
          bytes: bytes,
          name: p.basename(filePath),
          mimeType: _mediaMimeType(filePath, fallback: 'image/jpeg'),
        ),
        'file' => _WrytteDocumentFile(bytes: bytes, name: p.basename(filePath)),
        _ => mx.MatrixFile.fromMimeType(
          bytes: bytes,
          name: p.basename(filePath),
        ),
      };
      final mediaCaption = caption?.trim() ?? '';
      final extraContent = <String, dynamic>{
        if (attachmentType == 'file') 'wrytte.sent_as_file': true,
        // Matrix media captions use `body` while `filename` continues to hold
        // the original upload name. sendFileEvent supplies `filename`.
        if (mediaCaption.isNotEmpty) 'body': mediaCaption,
      };
      final eventId = await room.sendFileEvent(
        matrixFile,
        extraContent: extraContent.isEmpty ? null : extraContent,
      );
      final local = ChatMessage(
        id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: room.id,
        senderId:
            MatrixClientService.instance.client.userID ?? _currentUserId ?? '',
        receiverId: _toMatrixUserId(receiverID),
        content:
            caption?.trim().isNotEmpty == true
                ? caption!.trim()
                : attachmentType == 'file'
                ? p.basename(filePath)
                : _attachmentLabel(attachmentType),
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        attachmentUrl: filePath,
        attachmentType: attachmentType,
        mediaWidth: mediaWidth,
        mediaHeight: mediaHeight,
        senderPhone: _currentUserPhone,
      );
      _cacheMessage(local);
      unawaited(
        _refreshPeerProfileFromBackendForMessage(
          local,
          reason: 'sendAttachmentMessage',
        ),
      );
      return local;
    });
  }

  String _mediaMimeType(String filePath, {required String fallback}) {
    switch (p.extension(filePath).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.heic':
        return 'image/heic';
      default:
        return fallback;
    }
  }

  Future<void> validateAttachmentUpload({
    required String filePath,
    required String attachmentType,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }
    final configuredLimit = FileUploadLimits.chatFileMaxBytes;
    int effectiveLimit = configuredLimit;
    try {
      final serverLimit =
          (await MatrixClientService.instance.client.getConfig()).mUploadSize;
      if (serverLimit != null && serverLimit > 0) {
        effectiveLimit =
            serverLimit < configuredLimit ? serverLimit : configuredLimit;
      }
    } catch (_) {
      // The SDK repeats this check during upload if config is unavailable here.
    }
    final label =
        attachmentType == 'image'
            ? 'Photo'
            : attachmentType == 'video'
            ? 'Video'
            : 'File';
    await FileUploadLimits.validatePath(
      filePath,
      maxBytes: effectiveLimit,
      label: label,
    );
  }

  Future<void> removeFailedAttachmentAttempts({
    required String conversationId,
    required String filePath,
  }) async {
    final fileName = p.basename(filePath);
    final failed = getConversationMessages(conversationId)
        .where(
          (message) =>
              message.status == MessageStatus.failed &&
              message.attachmentType?.trim().isNotEmpty == true &&
              (message.attachmentUrl == filePath ||
                  message.content == fileName),
        )
        .toList(growable: false);
    for (final message in failed) {
      await cancelLocalMessage(message);
    }
  }

  String _attachmentLabel(String type) {
    switch (type) {
      case 'image':
        return 'Photo';
      case 'video':
        return 'Video';
      case 'voice':
        return 'Voice message';
      case 'file':
        return 'File';
      default:
        return 'Attachment';
    }
  }

  Future<List<ChatMessage>> fetchMessageHistory({
    required String conversationID,
    Object? startMsg,
    int count = 40,
  }) async {
    // Always paint a room from Wrytte's SQLite cache first. A restored app
    // process starts with [_loginHistoryPrepared] false, but that must not
    // force a full Matrix pagination every time a group screen is opened.
    final cached = await loadCachedMessages(conversationID);
    if (cached.isNotEmpty || _loginHistoryPrepared) return cached;

    // This is a genuinely uncached room (for example the first time it is
    // opened). Restore it asynchronously; _cacheMessage publishes each saved
    // page through messagesStreamFor so the already-open screen updates.
    unawaited(
      _withMatrixTokenRetry('fetchMessageHistory', () async {
        await _waitForConnection();
        final room = _roomById(conversationID);
        if (room == null) return <ChatMessage>[];
        return _restoreRoomHistoryFromServer(room);
      }).catchError((Object error, StackTrace stackTrace) {
        debugPrint('[ChatService] fetchMessageHistory error: $error');
        return <ChatMessage>[];
      }),
    );
    return cached;
  }

  Future<void> fetchConversations({int offset = 0, int count = 100}) async {
    final pending = _fetchConversationsFuture;
    if (pending != null) return pending;
    final future = _fetchConversations();
    _fetchConversationsFuture = future;
    try {
      await future;
    } finally {
      if (identical(_fetchConversationsFuture, future)) {
        _fetchConversationsFuture = null;
      }
    }
  }

  Future<void> _fetchConversations() async {
    try {
      await _withMatrixTokenRetry('fetchConversations', () async {
        await _waitForConnection();
        await MatrixChatService.instance.ensureSyncedAndAutoJoinInvites(
          forceSync: true,
        );
        _refreshConversationsFromRooms();
      });
    } catch (e) {
      debugPrint('[ChatService] fetchConversations error: $e');
    }
  }

  Future<List<ChatMessage>> fetchPublicGroupPreview({
    required String roomId,
    int? limit,
  }) async {
    final id = roomId.trim();
    if (id.isEmpty) return const [];
    final existing = _suggestedPreviewInFlight[id];
    if (existing != null) return existing;
    final request = _enqueueSuggestedPreview(id, limit: limit);
    _suggestedPreviewInFlight[id] = request;
    try {
      return await request;
    } finally {
      _suggestedPreviewInFlight.remove(id);
    }
  }

  /// Loads one bounded page for a room opened from a user profile. The profile
  /// screen itself only reads room summary metadata; event history is requested
  /// after the user taps the channel/group.
  Future<RoomEventPage> fetchProfileRoomEventPage({
    required String roomId,
    int limit = 15,
    bool initial = false,
  }) async {
    final id = roomId.trim();
    if (id.isEmpty) return const RoomEventPage(messages: [], hasMore: false);
    if (initial) {
      _profileRoomEventTokens.remove(id);
      _profileRoomEventHasMore.remove(id);
      _profileRoomCachedMessages.remove(id);
      _profileRoomCachedOffsets.remove(id);
    } else {
      final cached = _profileRoomCachedMessages[id];
      final offset = _profileRoomCachedOffsets[id] ?? 0;
      if (cached != null && offset > 0) {
        final start = (offset - limit).clamp(0, offset).toInt();
        final page = cached.sublist(start, offset);
        _profileRoomCachedOffsets[id] = start;
        final hasMore = start > 0 || _profileRoomEventTokens[id] != null;
        if (hasMore) {
          _profileRoomEventHasMore.add(id);
        } else {
          _profileRoomEventHasMore.remove(id);
        }
        return RoomEventPage(messages: page, hasMore: hasMore);
      }
      if (!_profileRoomEventHasMore.contains(id)) {
        return const RoomEventPage(messages: [], hasMore: false);
      }
    }
    final pending = _profileRoomEventInFlight[id];
    if (pending != null) return pending;
    final request = _withMatrixTokenRetry(
      'fetchProfileRoomEventPage',
      () async {
        await _waitForConnection();
        final joinedRoom = MatrixChatService.instance.getRoomById(id);
        apkLog(
          'Profile.roomEvents',
          'room route room_id="$id" found=${joinedRoom != null} '
              'membership="${joinedRoom?.membership.name ?? 'missing'}" '
              'created_by_account=${_createdGroupRoomIds.contains(id)} '
              'current_user="${_currentUserId ?? ''}"',
        );
        final client = MatrixClientService.instance.client;
        return _fetchProfileRoomMessagePage(
          roomId: id,
          room:
              joinedRoom?.membership == mx.Membership.join ? joinedRoom : null,
          client: client,
          limit: limit,
          initial: initial,
        );
      },
    ).catchError((Object error, StackTrace stackTrace) async {
      final cached = await loadCachedMessages(id);
      if (cached.isEmpty) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final start = (cached.length - limit).clamp(0, cached.length).toInt();
      final page = cached.sublist(start);
      _profileRoomCachedMessages[id] = cached;
      _profileRoomCachedOffsets[id] = start;
      final hasMore = start > 0;
      if (hasMore) {
        _profileRoomEventHasMore.add(id);
      } else {
        _profileRoomEventHasMore.remove(id);
      }
      apkLog(
        'Profile.roomEvents',
        'local fallback room_id="$id" messages=${page.length} '
            'has_more=$hasMore cause="${error.runtimeType}"',
      );
      return RoomEventPage(messages: page, hasMore: hasMore);
    });
    _profileRoomEventInFlight[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_profileRoomEventInFlight[id], request)) {
        _profileRoomEventInFlight.remove(id);
      }
    }
  }

  Future<RoomEventPage> _fetchProfileRoomMessagePage({
    required String roomId,
    required mx.Room? room,
    required mx.Client client,
    required int limit,
    required bool initial,
  }) async {
    final localMessages =
        _profileRoomCachedMessages[roomId] ?? await loadCachedMessages(roomId);
    final localById = {
      for (final message in localMessages) message.id: message,
    };
    final messagesById = <String, ChatMessage>{...localById};
    final hiddenIds =
        room == null
            ? const <String>{}
            : _hiddenEventIdsForRoom(roomId, room: room);
    final filter = jsonEncode(
      mx.StateFilter(
        types: [mx.EventTypes.Message, mx.EventTypes.Encrypted],
        lazyLoadMembers: true,
      ).toJson(),
    );
    var token = _profileRoomEventTokens[roomId];
    var hasMore = true;
    var eventsFetched = 0;
    var pagesFetched = 0;
    final maxPages = initial ? 1 : 3;

    // Start at the room's newest messages. Matrix's Timeline pagination can
    // walk its entire local event store (including state events) before it
    // reaches the server; a filtered /messages request keeps profile opens
    // bounded to actual message events.
    while (pagesFetched < maxPages && messagesById.length < limit && hasMore) {
      final previousToken = token;
      final response = await _enqueueMatrixPaginationRequest(
        () => client.getRoomEvents(
          roomId,
          mx.Direction.b,
          from: previousToken,
          limit: limit,
          filter: filter,
        ),
      );
      pagesFetched += 1;
      eventsFetched += response.chunk.length;
      final parsed = <ChatMessage>[];
      for (final matrixEvent in response.chunk) {
        if (room == null) {
          final message = _publicGroupPreviewMessage(
            matrixEvent,
            roomId: roomId,
            client: client,
          );
          if (message != null) parsed.add(message);
          continue;
        }
        var event = mx.Event.fromMatrixEvent(matrixEvent, room);
        final encryption = client.encryption;
        if (event.type == mx.EventTypes.Encrypted &&
            room.encrypted &&
            client.encryptionEnabled &&
            encryption != null) {
          try {
            event = await encryption.decryptRoomEvent(event);
          } catch (error) {
            apkLog(
              'Profile.roomEvents',
              'decrypt failed room_id="$roomId" event_id="${event.eventId}" error="$error"',
            );
          }
        }
        parsed.addAll(
          _messagesFromMatrixEvents(
            [event],
            localById: localById,
            hiddenIds: hiddenIds,
            groupJoinCutoff: _groupJoinCutoffForRoom(room),
          ),
        );
      }
      for (final message in parsed) {
        messagesById[message.id] = message;
      }
      token = response.end?.trim();
      hasMore =
          response.chunk.length >= limit &&
          token != null &&
          token.isNotEmpty &&
          token != previousToken;
      _profileRoomEventTokens[roomId] = hasMore ? token : null;
      apkLog(
        'Profile.roomEvents',
        'message page room_id="$roomId" page=$pagesFetched '
            'events=${response.chunk.length} parsed=${parsed.length} '
            'messages=${messagesById.length} has_more=$hasMore',
      );
      if (response.chunk.isEmpty || parsed.isEmpty) break;
    }

    final messages =
        messagesById.values.toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final newlyLoaded = messages
        .where((message) => !localById.containsKey(message.id))
        .toList(growable: false);
    if (newlyLoaded.isNotEmpty) {
      await ChatLocalDb.instance.saveMessages(newlyLoaded);
      for (final message in newlyLoaded) {
        _cacheMessage(message, countUnread: false, publish: false);
      }
    }
    _profileRoomCachedMessages[roomId] = messages;
    final offset =
        initial
            ? (messages.length - limit).clamp(0, messages.length).toInt()
            : 0;
    _profileRoomCachedOffsets[roomId] = offset;
    final page =
        initial ? messages.sublist(offset) : newlyLoaded.take(limit).toList();
    final moreLocal = offset > 0;
    final canLoadMore = moreLocal || hasMore;
    if (canLoadMore) {
      _profileRoomEventHasMore.add(roomId);
    } else {
      _profileRoomEventHasMore.remove(roomId);
    }
    apkLog(
      'Profile.roomEvents',
      '${room == null ? 'public' : 'joined'} page complete room_id="$roomId" '
          'events=$eventsFetched messages=${page.length} '
          'cached=${localMessages.length} pages=$pagesFetched '
          'has_more=$canLoadMore',
    );
    return RoomEventPage(messages: page, hasMore: canLoadMore);
  }

  Future<List<ChatMessage>> _enqueueSuggestedPreview(
    String roomId, {
    int? limit,
  }) {
    final runtimeGeneration = _runtimeGeneration;
    final completer = Completer<List<ChatMessage>>();
    _suggestedPreviewQueue = _suggestedPreviewQueue.then((_) async {
      try {
        completer.complete(
          await _fetchPublicGroupPreview(
            roomId,
            limit: limit,
            runtimeGeneration: runtimeGeneration,
          ),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<List<ChatMessage>> _fetchPublicGroupPreview(
    String id, {
    int? limit,
    required int runtimeGeneration,
  }) async {
    if (!_isConnected || runtimeGeneration != _runtimeGeneration) {
      return const [];
    }
    apkLog('SuggestedPreview', 'fetch started room_id="$id"');
    try {
      return await _withMatrixTokenRetry('fetchPublicGroupPreview', () async {
        await _waitForConnection();
        final client = MatrixClientService.instance.client;
        final messages = <ChatMessage>[];
        final latestMembers = <String, mx.MatrixEvent>{};
        final latestProfileState = <String, mx.MatrixEvent>{};
        String? from;
        var pageCount = 0;

        while (limit == null || messages.length < limit) {
          final remaining = limit == null ? 80 : limit - messages.length;
          final pageLimit = remaining > 80 ? 80 : remaining;
          final response = await _enqueueMatrixPaginationRequest(
            () => client.getRoomEvents(
              id,
              mx.Direction.b,
              from: from,
              limit: pageLimit,
            ),
          );
          if (!_isConnected || runtimeGeneration != _runtimeGeneration) {
            return const <ChatMessage>[];
          }
          pageCount++;
          for (final event in response.chunk) {
            _collectSuggestedPreviewMember(event, latestMembers);
            _collectSuggestedRoomProfileState(event, latestProfileState);
          }
          final pageMessages =
              response.chunk
                  .map(
                    (event) => _publicGroupPreviewMessage(
                      event,
                      roomId: id,
                      client: client,
                    ),
                  )
                  .whereType<ChatMessage>()
                  .toList();
          messages.addAll(pageMessages);

          final next = response.end?.trim();
          apkLog(
            'SuggestedPreview',
            'page fetched room_id="$id" page=$pageCount '
                'events=${response.chunk.length} messages=${pageMessages.length} '
                'next_token=${next != null && next.isNotEmpty && next != from}',
          );
          if (next == null || next.isEmpty || next == from) break;
          from = next;
        }

        messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        if (!_isConnected || runtimeGeneration != _runtimeGeneration) {
          return const <ChatMessage>[];
        }
        final adminIds = _suggestedRoomAdminIds(latestProfileState);
        final memberRows =
            latestMembers.values
                .map(
                  (event) => _suggestedPreviewMemberRow(
                    event,
                    isAdmin: adminIds.contains(event.stateKey?.trim()),
                  ),
                )
                .toList();
        await ChatLocalDb.instance.saveSuggestedPreviewMembers(id, memberRows);
        await ChatLocalDb.instance.saveSuggestedRoomProfile(
          id,
          _suggestedRoomProfileRow(
            latestProfileState,
            memberCount:
                memberRows.where((row) => row['membership'] == 'join').length,
          ),
        );
        if (messages.isNotEmpty) {
          _messagesCache[id] = messages;
          await ChatLocalDb.instance.saveSuggestedPreviewMessages(id, messages);
        }
        await ChatLocalDb.instance.saveSuggestedPreviewSync(
          roomId: id,
          status: 'complete',
          messageCount: messages.length,
          pageCount: pageCount,
          isComplete: true,
        );
        apkLog(
          'SuggestedPreview',
          'fetch complete room_id="$id" messages=${messages.length} '
              'members=${memberRows.where((row) => row['membership'] == 'join').length} '
              'pages=$pageCount sqlite_saved=true',
        );
        return messages;
      });
    } catch (e) {
      if (!_isConnected || runtimeGeneration != _runtimeGeneration) {
        return const [];
      }
      await ChatLocalDb.instance.saveSuggestedPreviewSync(
        roomId: id,
        status: 'failed',
        messageCount: 0,
        pageCount: 0,
        isComplete: false,
        lastError: e.toString(),
      );
      apkLog(
        'SuggestedPreview',
        'fetch failed room_id="$id" '
            'reason="server refused history or request failed" error="$e"',
      );
      return const [];
    }
  }

  void _collectSuggestedPreviewMember(
    mx.MatrixEvent event,
    Map<String, mx.MatrixEvent> latestMembers,
  ) {
    if (event.type != mx.EventTypes.RoomMember) return;
    final userId = event.stateKey?.trim() ?? '';
    if (userId.isEmpty) return;
    final existing = latestMembers[userId];
    if (existing == null ||
        event.originServerTs.isAfter(existing.originServerTs)) {
      latestMembers[userId] = event;
    }
  }

  void _collectSuggestedRoomProfileState(
    mx.MatrixEvent event,
    Map<String, mx.MatrixEvent> latest,
  ) {
    const supported = {
      mx.EventTypes.RoomAvatar,
      mx.EventTypes.RoomName,
      mx.EventTypes.RoomTopic,
      mx.EventTypes.RoomCanonicalAlias,
      mx.EventTypes.RoomCreate,
      mx.EventTypes.RoomPowerLevels,
      'com.wrytte.group.info',
    };
    if (!supported.contains(event.type) || (event.stateKey ?? '').isNotEmpty) {
      return;
    }
    final existing = latest[event.type];
    if (existing == null ||
        event.originServerTs.isAfter(existing.originServerTs)) {
      latest[event.type] = event;
    }
  }

  Set<String> _suggestedRoomAdminIds(Map<String, mx.MatrixEvent> state) {
    final admins = <String>{};
    final explicitOwner =
        state['com.wrytte.group.info']?.content['owner_user_id']
            ?.toString()
            .trim() ??
        '';
    if (explicitOwner.isNotEmpty) admins.add(explicitOwner);
    final creator =
        state[mx.EventTypes.RoomCreate]?.content['creator']
            ?.toString()
            .trim() ??
        '';
    if (creator.isNotEmpty) admins.add(creator);

    final users = state[mx.EventTypes.RoomPowerLevels]?.content['users'];
    if (users is Map) {
      for (final entry in users.entries) {
        final userId = entry.key.toString().trim();
        final level = num.tryParse(entry.value.toString())?.toInt() ?? 0;
        if (userId.isNotEmpty && level >= mx.PowerLevel.defaultAdminLevel) {
          admins.add(userId);
        }
      }
    }
    return admins;
  }

  Map<String, dynamic> _suggestedRoomProfileRow(
    Map<String, mx.MatrixEvent> state, {
    int memberCount = 0,
  }) {
    final info = state['com.wrytte.group.info']?.content ?? const {};
    int version(String key) => int.tryParse(info[key]?.toString() ?? '') ?? 0;
    return {
      'name': state[mx.EventTypes.RoomName]?.content['name']?.toString(),
      'avatarUrl': state[mx.EventTypes.RoomAvatar]?.content['url']?.toString(),
      'canonicalAlias':
          state[mx.EventTypes.RoomCanonicalAlias]?.content['alias']?.toString(),
      'description':
          state[mx.EventTypes.RoomTopic]?.content['topic']?.toString(),
      'memberCount': memberCount,
      'link': info['link']?.toString(),
      'avatarVersion': version('avatar_version'),
      'nameVersion': version('name_version'),
      'descriptionVersion': version('description_version'),
      'linkVersion': version('link_version'),
      'aliasVersion': version('alias_version'),
    };
  }

  Future<Map<String, dynamic>?> loadSuggestedRoomProfile(String roomId) =>
      ChatLocalDb.instance.loadSuggestedRoomProfile(roomId);

  Future<void> cacheSuggestedRoomProfile(
    String roomId,
    Map<String, dynamic> profile,
  ) => ChatLocalDb.instance.saveSuggestedRoomProfile(roomId, profile);

  Map<String, dynamic> _suggestedPreviewMemberRow(
    mx.MatrixEvent event, {
    required bool isAdmin,
  }) {
    return {
      'userId': event.stateKey,
      'membership': event.content['membership']?.toString() ?? 'leave',
      'displayName': event.content['displayname']?.toString(),
      'avatarUrl': event.content['avatar_url']?.toString(),
      'isAdmin': isAdmin ? 1 : 0,
      'eventTimestamp': event.originServerTs.millisecondsSinceEpoch,
    };
  }

  Future<List<Map<String, dynamic>>> loadSuggestedPreviewMembers(
    String roomId,
  ) => ChatLocalDb.instance.loadSuggestedPreviewMembers(roomId);

  /// Refresh current public-room state without replaying message history.
  /// Suggested profiles need the creator/power-level events before joining,
  /// and older preview rows may only contain membership events.
  Future<List<Map<String, dynamic>>> refreshSuggestedPreviewRoomState(
    String roomId,
  ) async {
    final id = roomId.trim();
    if (id.isEmpty) return const [];
    try {
      return await _withMatrixTokenRetry(
        'refreshSuggestedPreviewRoomState',
        () async {
          await _waitForConnection();
          final client = MatrixClientService.instance.client;
          final events = await _enqueueMatrixPaginationRequest(
            () => client.getRoomState(id),
          );
          final members = <String, mx.MatrixEvent>{};
          final profileState = <String, mx.MatrixEvent>{};
          for (final event in events) {
            _collectSuggestedPreviewMember(event, members);
            _collectSuggestedRoomProfileState(event, profileState);
          }
          final adminIds = _suggestedRoomAdminIds(profileState);
          final rows =
              members.values
                  .map(
                    (event) => _suggestedPreviewMemberRow(
                      event,
                      isAdmin: adminIds.contains(event.stateKey?.trim()),
                    ),
                  )
                  .toList();
          if (rows.isNotEmpty) {
            await ChatLocalDb.instance.saveSuggestedPreviewMembers(id, rows);
          }
          if (profileState.isNotEmpty) {
            await ChatLocalDb.instance.saveSuggestedRoomProfile(
              id,
              _suggestedRoomProfileRow(
                profileState,
                memberCount:
                    rows.where((row) => row['membership'] == 'join').length,
              ),
            );
          }
          apkLog(
            'SuggestedPreview',
            'state refreshed room_id="$id" events=${events.length} '
                'members=${rows.where((row) => row['membership'] == 'join').length} '
                'admins=${adminIds.length}',
          );
          return ChatLocalDb.instance.loadSuggestedPreviewMembers(id);
        },
      );
    } catch (error) {
      apkLog(
        'SuggestedPreview',
        'state refresh unavailable room_id="$id" error="$error"',
      );
      // Some homeservers restrict /state to joined users even when history is
      // world-readable. In that case, replay the public history once so the
      // original create/power-level events can repair the legacy cache.
      await fetchPublicGroupPreview(roomId: id);
      return loadSuggestedPreviewMembers(id);
    }
  }

  ChatMessage? _publicGroupPreviewMessage(
    mx.MatrixEvent event, {
    required String roomId,
    required mx.Client client,
  }) {
    if (event.type != mx.EventTypes.Message) return null;
    final content = event.content;
    final rawBody = content['body']?.toString() ?? '';
    final body = _stripSuggestedReplyFallback(rawBody).trim();
    final url = content['url']?.toString().trim();
    if (body.isEmpty && (url == null || url.isEmpty)) return null;
    final msgType = content['msgtype']?.toString() ?? '';
    final attachmentType =
        content['wrytte.sent_as_file'] == true
            ? 'file'
            : _attachmentTypeFromMatrixMessageType(msgType);
    return ChatMessage(
      id: event.eventId,
      conversationId: roomId,
      senderId: event.senderId,
      receiverId: roomId,
      content: body,
      timestamp: event.originServerTs,
      status: MessageStatus.sent,
      attachmentUrl: _matrixMediaDownloadUrl(url, client),
      attachmentType: attachmentType,
      replyToMessageId: _suggestedReplyEventId(content),
      replyToSenderId: _suggestedReplySender(rawBody),
      replyPreview: _suggestedReplyPreview(rawBody),
      senderName: content['wrytte.sender_name']?.toString(),
      senderPhone: content['wrytte.sender_phone']?.toString(),
      isForwarded: content['wrytte.forwarded'] == true,
    );
  }

  String? _suggestedReplyEventId(Map<String, dynamic> content) {
    final relatesTo = content['m.relates_to'];
    if (relatesTo is! Map) return null;
    final inReplyTo = relatesTo['m.in_reply_to'];
    if (inReplyTo is! Map) return null;
    final eventId = inReplyTo['event_id']?.toString().trim() ?? '';
    return eventId.isEmpty ? null : eventId;
  }

  String _stripSuggestedReplyFallback(String body) {
    final split = body.split('\n\n');
    if (body.startsWith('> ') && split.length > 1) {
      return split.sublist(1).join('\n\n');
    }
    return body;
  }

  String? _suggestedReplySender(String body) {
    if (!body.startsWith('> ')) return null;
    final firstLine = body
        .split('\n\n')
        .first
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'^> ?'), '').trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return RegExp(r'^<([^>]+)>').firstMatch(firstLine)?.group(1);
  }

  String? _suggestedReplyPreview(String body) {
    if (!body.startsWith('> ')) return null;
    final lines =
        body
            .split('\n\n')
            .first
            .split('\n')
            .map((line) => line.replaceFirst(RegExp(r'^> ?'), '').trim())
            .where((line) => line.isNotEmpty)
            .toList();
    if (lines.isEmpty) return null;
    final preview = lines.join(' ').replaceFirst(RegExp(r'^<[^>]+>\s*'), '');
    if (preview.trim().isEmpty) return null;
    return preview.length > 120 ? '${preview.substring(0, 120)}...' : preview;
  }

  String? _attachmentTypeFromMatrixMessageType(String msgType) {
    switch (msgType) {
      case mx.MessageTypes.Audio:
        return 'voice';
      case mx.MessageTypes.Image:
        return 'image';
      case mx.MessageTypes.Video:
        return 'video';
      case mx.MessageTypes.File:
        return 'file';
      default:
        return null;
    }
  }

  String? _matrixMediaDownloadUrl(String? rawUrl, mx.Client client) {
    final value = rawUrl?.trim() ?? '';
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.isScheme('mxc')) return value;
    final homeserver = client.homeserver;
    if (homeserver == null) return null;
    return homeserver
        .resolve(
          '_matrix/client/v1/media/download/${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path}',
        )
        .toString();
  }

  Future<void> markConversationAsRead(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    await _markConversationReadLocally(id);
    final eventId = _latestKnownMessageId(id);
    if (eventId == null ||
        eventId.isEmpty ||
        _lastReadReceiptEventByConversation[id] == eventId) {
      return;
    }
    _lastReadReceiptEventByConversation[id] = eventId;
    try {
      await _withMatrixTokenRetry('markConversationAsRead', () async {
        await MatrixChatService.instance.markRead(id, eventId: eventId);
      });
      apkLog(
        'Matrix.receipt',
        'sent type="m.read" room_id="$id" event_id="$eventId"',
      );
    } catch (error) {
      _lastReadReceiptEventByConversation.remove(id);
      apkLog(
        'Matrix.receipt',
        'send failed type="m.read" room_id="$id" event_id="$eventId" error=$error',
      );
    }
  }

  Future<void> _markConversationReadLocally(String conversationId) async {
    final current = _conversationsMap[conversationId];
    if (current != null) {
      final readAt = _latestKnownMessageTime(conversationId);
      _lastReadAtByConversation[conversationId] = readAt;
      _readConversationIds.add(conversationId);
      _conversationsMap[conversationId] = current.copyWith(unreadCount: 0);
      _emitConversations();
      await ChatLocalDb.instance.markConversationReadAt(conversationId, readAt);
    } else {
      await ChatLocalDb.instance.markConversationRead(conversationId);
    }
  }

  void activateConversationRead(String conversationId) {
    final id = conversationId.trim();
    if (id.isEmpty) return;

    _activeReadConversationIds.add(id);
    _readConversationIds.add(id);

    final readAt = DateTime.now();
    _lastReadAtByConversation[id] = readAt;

    final current = _conversationsMap[id];
    if (current == null) {
      unawaited(ChatLocalDb.instance.markConversationReadAt(id, readAt));
      return;
    }

    if (current.unreadCount != 0) {
      _conversationsMap[id] = current.copyWith(unreadCount: 0);
      _emitConversations();
    }
    unawaited(ChatLocalDb.instance.markConversationReadAt(id, readAt));
  }

  void deactivateConversationRead(String conversationId) {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    _activeReadConversationIds.remove(id);
  }

  List<ChatMessage> getConversationMessages(String conversationId) {
    final messages =
        List<ChatMessage>.from(_messagesCache[conversationId] ?? [])
            .where(
              (message) =>
                  !_isHiddenForMe(message) &&
                  !_isBeforeGroupJoinCutoff(message),
            )
            .toList();
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  List<ChatMessage> cachedMessagesFor(String conversationId) {
    return getConversationMessages(conversationId);
  }

  Future<List<ChatMessage>> loadCachedMessages(String conversationId) async {
    final cached = await ChatLocalDb.instance.loadMessages(conversationId);
    final hiddenIds = _hiddenEventIdsForRoom(conversationId);
    final visible =
        cached
            .map((message) {
              if (!hiddenIds.contains(message.id)) return message;
              unawaited(ChatLocalDb.instance.deleteMessageForMe(message.id));
              return message.copyWith(isDeletedForMe: true);
            })
            .where(
              (message) =>
                  !_isHiddenForMe(message) &&
                  !_isBeforeGroupJoinCutoff(message),
            )
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final message in visible) {
      _upsertCachedMessage(message.copyWith(conversationId: conversationId));
    }
    final room = _roomById(conversationId);
    if (room != null) _refreshMessageStatusesForRoom(room);
    _emitRoomMessages(conversationId);
    return visible;
  }

  Future<List<ChatMessage>> hydrateConversation(String conversationId) async {
    final memory = getConversationMessages(conversationId);
    if (memory.isNotEmpty) {
      _emitRoomMessages(conversationId);
      return memory;
    }
    final cached = await loadCachedMessages(conversationId);
    if (cached.isNotEmpty) return cached;

    // Only a genuinely uncached room needs Matrix history. Do this in the
    // background so the screen is never held behind network pagination.
    final room = _roomById(conversationId);
    if (room != null) {
      unawaited(
        _restoreRoomHistoryFromServer(room).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint('[ChatService] background room hydration error: $error');
          return <ChatMessage>[];
        }),
      );
    }

    // Conversation rows deliberately duplicate the latest message so the
    // inbox can paint cheaply. Older installations may have that row without
    // any corresponding timeline rows. While the one-time Matrix backfill
    // repairs the full cache, expose the persisted latest DM instead of an
    // incorrectly empty conversation. Do not insert this synthetic row into
    // the message cache/database: real Matrix events will replace it.
    final conversation = await ChatLocalDb.instance.loadConversation(
      conversationId,
    );
    if (conversation == null ||
        conversation.isGroupKind ||
        conversation.isChannelKind ||
        conversation.lastMessage.trim().isEmpty) {
      return const <ChatMessage>[];
    }
    apkLog(
      'ChatService.local',
      'timeline fallback conversation_id="$conversationId" source="conversation_preview"',
    );
    return <ChatMessage>[
      ChatMessage(
        id:
            'local-preview-${conversation.id}-'
            '${conversation.lastMessageTime.millisecondsSinceEpoch}',
        conversationId: conversation.id,
        senderId: conversation.lastMessageSenderId,
        receiverId: conversation.otherUserId,
        content: conversation.lastMessage,
        timestamp: conversation.lastMessageTime,
        status: MessageStatus.sent,
      ),
    ];
  }

  Future<void> hydrateLocalConversations() async {
    _lastReadAtByConversation
      ..clear()
      ..addAll(await ChatLocalDb.instance.loadConversationReadMarkers());
    final conversations = await ChatLocalDb.instance.loadConversations();
    apkLog(
      'ChatService.local',
      'hydrated local conversations=${conversations.length}',
    );
    for (final conversation in conversations) {
      // A permanent room-id tombstone always wins over stale SQLite
      // metadata. Older rows are not guaranteed to contain the deleted-group
      // message/state, so conditioning this on their shape lets them return
      // after logout/login.
      if (_dismissedDeletedGroupRoomIds.contains(conversation.id)) {
        await _purgeLocalConversationContent(conversation.id);
        await ChatLocalDb.instance.deleteConversation(conversation.id);
        continue;
      }
      final restoredRead = conversation.copyWith(unreadCount: 0);
      _readConversationIds.add(restoredRead.id);
      _lastReadAtByConversation[restoredRead.id] = restoredRead.lastMessageTime;
      _conversationsMap.putIfAbsent(restoredRead.id, () => restoredRead);
      unawaited(
        ChatLocalDb.instance.markConversationReadAt(
          restoredRead.id,
          restoredRead.lastMessageTime,
        ),
      );
    }
    await _backfillConversationKinds();
    await _scrubDirectAvatarsMatchingGroups();
    await _applySavedContactsToHydratedConversations();
    unawaited(
      MatrixChatService.instance.upgradeOwnedPublicGroupsHistoryVisibility(),
    );
    unawaited(
      MatrixChatService.instance.upgradeCreatedGroupOwnershipProfiles(),
    );
    _emitConversations();
    for (final conversation in conversations) {
      final cachedMessages = await loadCachedMessages(conversation.id);
      // Audit every locally known attachment on cold start. Completed files
      // resolve from disk without a network request; missing/incomplete files
      // are downloaded and reflected in the per-room MediaCache summary.
      for (final message in cachedMessages) {
        _prefetchPersistentAttachment(message);
      }
    }
    await auditDirectChatCacheCoverage();
    _emitConversations();
  }

  Future<void> _backfillConversationKinds() async {
    final upgraded = <ChatConversation>[];
    for (final entry in _conversationsMap.entries.toList()) {
      final conv = entry.value;
      final room = _roomById(conv.id);
      final tombstoned =
          room
              ?.getState(groupDeletedStateType)
              ?.content[groupDeletedEventKey] ==
          true;
      final deletedGroup = tombstoned || _isDeletedGroupConversationRow(conv);
      final roomKind =
          room != null && MatrixChatService.instance.isMatrixGroupRoom(room)
              ? _kindForGroupRoom(room)
              : ConversationKind.unknown;
      // Matrix room state/alias is authoritative for group rooms. This also
      // repairs rows cached as groups before channel classification existed.
      if (roomKind == ConversationKind.channel &&
          conv.conversationKind != ConversationKind.channel) {
        final stamped = conv.copyWith(
          conversationKind: ConversationKind.channel,
          otherUserId: conv.id,
          otherUserAvatar:
              room != null ? (_groupRoomAvatarUrl(room) ?? '') : '',
          otherUserName: room != null ? _groupDisplayName(room, conv) : null,
        );
        _conversationsMap[entry.key] = stamped;
        upgraded.add(stamped);
        continue;
      }
      if (conv.hasExplicitKind &&
          !(deletedGroup && !conv.isGroupKind && !conv.isChannelKind)) {
        continue;
      }

      String kind = ConversationKind.unknown;
      final storedAsGroup =
          (conv.lastMessageType == 'group' ||
              conv.lastMessageType == groupDeletedMessageType) &&
          conv.id.startsWith('!') &&
          conv.otherUserId == conv.id;
      final inRegistry = _createdGroupRoomIds.contains(conv.id.trim());
      final liveGroup =
          room != null && MatrixChatService.instance.isMatrixGroupRoom(room);

      if (deletedGroup || storedAsGroup || inRegistry || liveGroup) {
        kind = ConversationKind.group;
      } else if (room != null && room.isDirectChat) {
        kind = ConversationKind.direct;
      } else if (!conv.id.startsWith('!') &&
          conv.otherUserId.startsWith('@') &&
          !conv.otherUserId.startsWith('@!') &&
          conv.otherUserId != conv.id &&
          conv.lastMessageType != 'group' &&
          conv.lastMessageType != groupDeletedMessageType) {
        kind = ConversationKind.direct;
      }

      if (kind == ConversationKind.unknown) continue;
      final stamped = conv.copyWith(
        conversationKind: kind,
        otherUserId: kind == ConversationKind.group ? conv.id : null,
        otherUserAvatar:
            kind == ConversationKind.group
                ? (room != null ? (_groupRoomAvatarUrl(room) ?? '') : '')
                : null,
        otherUserName:
            kind == ConversationKind.group && room != null
                ? _groupDisplayName(room, conv)
                : null,
      );
      _conversationsMap[entry.key] = stamped;
      upgraded.add(stamped);
      if (kind == ConversationKind.group) {
        final ownedByCurrentUser =
            inRegistry ||
            (room != null && MatrixChatService.instance.isGroupOwner(room));
        if (ownedByCurrentUser) {
          unawaited(markGroupCreated(conv.id));
        } else {
          unawaited(markGroupJoined(conv.id));
        }
      }
    }
    if (upgraded.isEmpty) return;
    await ChatLocalDb.instance.saveConversations(upgraded);
    apkLog(
      'ChatService.kindMigration',
      'stamped conversationKind on ${upgraded.length} legacy rows',
    );
  }

  Future<void> _scrubDirectAvatarsMatchingGroups() async {
    final changed = _scrubDirectAvatarsMatchingGroupsInMemory();
    if (changed.isEmpty) return;
    await ChatLocalDb.instance.saveConversations(changed);
    apkLog(
      'ChatService.avatarScrub',
      'cleared group avatars from ${changed.length} direct conversations',
    );
  }

  List<ChatConversation> _scrubDirectAvatarsMatchingGroupsInMemory() {
    final groupAvatars = _knownGroupAvatarIdentities();
    if (groupAvatars.isEmpty) return const <ChatConversation>[];

    final changed = <ChatConversation>[];
    for (final entry in _conversationsMap.entries.toList()) {
      final conversation = entry.value;
      if (_isGroupConversationRow(conversation)) continue;
      final avatarKey = _normaliseAvatarIdentity(conversation.otherUserAvatar);
      if (avatarKey.isEmpty || !groupAvatars.contains(avatarKey)) continue;

      final scrubbed = conversation.copyWith(otherUserAvatar: '');
      _conversationsMap[entry.key] = scrubbed;
      changed.add(scrubbed);
    }
    return changed;
  }

  Set<String> _knownGroupAvatarIdentities() {
    final values = <String>{};
    for (final conversation in _conversationsMap.values) {
      if (!_isGroupConversationRow(conversation)) continue;
      values.add(_normaliseAvatarIdentity(conversation.otherUserAvatar));
      final room = _roomById(conversation.id);
      if (room != null) {
        values.add(_normaliseAvatarIdentity(_groupRoomAvatarUrl(room)));
      }
    }
    if (MatrixClientService.instance.isInitialized) {
      for (final room in MatrixChatService.instance.rooms) {
        if (!_isGroupRoom(room, _conversationsMap[room.id])) continue;
        values.add(_normaliseAvatarIdentity(_groupRoomAvatarUrl(room)));
      }
    }
    values.removeWhere((value) => value.isEmpty);
    return values;
  }

  bool _isKnownGroupAvatar(String? avatarUrl) {
    final key = _normaliseAvatarIdentity(avatarUrl);
    return key.isNotEmpty && _knownGroupAvatarIdentities().contains(key);
  }

  String? _safePersonAvatar(String? avatarUrl) {
    final clean = avatarUrl?.trim() ?? '';
    if (clean.isEmpty || _isKnownGroupAvatar(clean)) return null;
    return clean;
  }

  Future<void> starMessage(ChatMessage message, bool starred) async {
    final updated = message.copyWith(isStarred: starred);
    _replaceCachedMessage(updated);
    await ChatLocalDb.instance.setMessageStarred(message.id, starred);
    _messageController.add(updated);
  }

  Future<void> markVoiceMessageListened(ChatMessage message) async {
    if (!message.isVoiceNote || message.id.trim().isEmpty) return;
    await _withMatrixTokenRetry('markVoiceMessageListened', () async {
      await _waitForConnection();
      final room = _roomById(message.conversationId.trim());
      if (room == null || MatrixChatService.instance.isMatrixGroupRoom(room)) {
        return;
      }
      final listenerId = room.client.userID;
      if (listenerId == null || listenerId.isEmpty) return;
      if (_isOwnMessage(message, listenerId)) return;

      _markVoiceListenedLocally(room.id, message.id, listenerId: listenerId);
      await room.sendEvent(
        {
          'voice_event_id': message.id,
          'listener_user_id': listenerId,
          'listened_at': DateTime.now().toUtc().toIso8601String(),
        },
        type: voiceListenedEventType,
        displayPendingEvent: false,
      );
      apkLog(
        'ChatService.voiceListened',
        'receipt sent room_id="${room.id}" event_id="${message.id}"',
      );
    });
  }

  bool _applyVoiceListenedEvent(mx.Event event) {
    if (event.type != voiceListenedEventType) return false;
    final targetId = event.content['voice_event_id']?.toString().trim() ?? '';
    if (targetId.isEmpty) return true;
    _markVoiceListenedLocally(
      event.room.id,
      targetId,
      listenerId: event.senderId,
    );
    return true;
  }

  void _markVoiceListenedLocally(
    String roomId,
    String eventId, {
    required String listenerId,
  }) {
    final messages = _messagesCache[roomId];
    if (messages == null) return;
    final index = messages.indexWhere((message) => message.id == eventId);
    if (index < 0) return;
    final message = messages[index];
    if (!message.isVoiceNote ||
        message.isVoiceListened ||
        _isOwnMessage(message, listenerId)) {
      return;
    }
    final updated = message.copyWith(isVoiceListened: true);
    messages[index] = updated;
    unawaited(ChatLocalDb.instance.saveMessage(updated));
    _messageController.add(updated);
    _emitRoomMessages(roomId);
  }

  List<String> pinnedEventIdsForRoom(String roomId) {
    final room = _roomById(roomId.trim());
    if (room == null) return <String>[];
    return room.pinnedEventIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
  }

  List<String> pinnedForMeEventIdsForRoom(String roomId) {
    final normalizedRoomId = roomId.trim();
    if (normalizedRoomId.isEmpty) return <String>[];
    final room = _roomById(normalizedRoomId);
    if (room != null) _syncPinnedForMeFromRoom(room);
    return List<String>.from(
      _pinnedForMeEventIdsByRoom[normalizedRoomId] ?? const <String>[],
    );
  }

  Future<List<String>> setMessagePinnedForMe(
    ChatMessage message, {
    required bool pinned,
  }) async {
    final roomId = message.conversationId.trim();
    final eventId = message.id.trim();
    if (!roomId.startsWith('!') || !eventId.startsWith(r'$')) {
      throw StateError(
        'Wait for this message to finish sending before pinning it.',
      );
    }

    return _withMatrixTokenRetry('setMessagePinnedForMe', () async {
      await _waitForConnection();
      final room = _roomById(roomId);
      if (room == null) throw StateError('Unknown Matrix room: $roomId');
      if (MatrixChatService.instance.isMatrixGroupRoom(room)) {
        throw StateError('Pin for me is only available in direct messages.');
      }
      final client = MatrixClientService.instance.client;
      final userId = client.userID;
      if (userId == null || userId.isEmpty) {
        throw StateError('Matrix user is not logged in');
      }

      var ids = pinnedForMeEventIdsForRoom(roomId);
      try {
        final latest = await client.getAccountDataPerRoom(
          userId,
          roomId,
          _pinnedForMeAccountDataType,
        );
        final rawIds = latest['pinned_event_ids'];
        if (rawIds is Iterable) {
          ids =
              rawIds
                  .map((id) => id.toString().trim())
                  .where((id) => id.isNotEmpty)
                  .toSet()
                  .toList();
        }
      } catch (_) {
        // This account-data entry does not exist until the first private pin.
      }
      ids.removeWhere((id) => id == eventId);
      if (pinned) ids.insert(0, eventId);
      await client
          .setAccountDataPerRoom(userId, roomId, _pinnedForMeAccountDataType, {
            'pinned_event_ids': ids,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          });
      _pinnedForMeEventIdsByRoom[roomId] = List<String>.from(ids);
      _pendingPinnedForMeEventIdsByRoom[roomId] = List<String>.from(ids);
      apkLog(
        'ChatService.pinForMe',
        '${pinned ? 'pinned' : 'unpinned'} private event '
            'room_id="$roomId" event_id="$eventId"',
      );
      return ids;
    });
  }

  Future<List<String>> setMessagePinnedForEveryone(
    ChatMessage message, {
    required bool pinned,
  }) async {
    final roomId = message.conversationId.trim();
    final eventId = message.id.trim();
    if (!roomId.startsWith('!') || !eventId.startsWith(r'$')) {
      throw StateError(
        'Wait for this message to finish sending before pinning it.',
      );
    }

    return _withMatrixTokenRetry('setMessagePinnedForEveryone', () async {
      await _waitForConnection();
      final room = _roomById(roomId);
      if (room == null) {
        throw StateError('Unknown Matrix room: $roomId');
      }
      if (!room.canChangeStateEvent(mx.EventTypes.RoomPinnedEvents)) {
        throw StateError(
          'You do not have permission to change pinned messages.',
        );
      }

      // This is one shared state event, so preserve its complete ordered list.
      var currentIds = room.pinnedEventIds;
      try {
        final latest = await room.client.getRoomStateWithKey(
          roomId,
          mx.EventTypes.RoomPinnedEvents,
          '',
        );
        final rawPinned = latest['pinned'];
        if (rawPinned is Iterable) {
          currentIds = rawPinned.map((id) => id.toString()).toList();
        }
      } catch (_) {
        // A room with no m.room.pinned_events state yet legitimately returns
        // M_NOT_FOUND. The synced room value is also the best offline fallback.
      }
      final ids =
          currentIds
              .map((id) => id.trim())
              .where((id) => id.isNotEmpty)
              .toList();
      ids.removeWhere((id) => id == eventId);
      if (pinned) ids.insert(0, eventId);
      await room.setPinnedEvents(ids);
      apkLog(
        'ChatService.pinForEveryone',
        '${pinned ? 'pinned' : 'unpinned'} event '
            'room_id="$roomId" event_id="$eventId"',
      );
      return ids;
    });
  }

  Future<ChatMessage> editMessage({
    required ChatMessage message,
    required String newContent,
  }) async {
    final text = newContent.trim();
    if (text.isEmpty) throw ArgumentError('Edited message cannot be empty');
    if (message.hasAttachment || message.isVoiceNote) {
      throw StateError('Only text messages can be edited');
    }

    return _withMatrixTokenRetry('editMessage', () async {
      await _waitForConnection();
      final client = MatrixClientService.instance.client;
      final currentUser = client.userID ?? _currentUserId ?? '';
      if (!_isOwnMessage(message, currentUser)) {
        throw StateError('You can only edit your own messages');
      }
      final room = _roomById(message.conversationId);
      if (room == null) {
        throw StateError('Unknown Matrix room: ${message.conversationId}');
      }
      await room.sendEvent(
        _buildMessageContent(message.copyWith(content: text)),
        editEventId: message.id,
      );
      final updated = message.copyWith(
        content: text,
        status: MessageStatus.sent,
        isEdited: true,
      );
      _replaceCachedMessage(updated);
      await ChatLocalDb.instance.saveMessage(updated);
      _messageController.add(updated);
      _emitConversations();
      return updated;
    });
  }

  Future<void> deleteMessageForMe(ChatMessage message) async {
    final room = _roomById(message.conversationId);
    if (room != null && MatrixChatService.instance.isMatrixGroupRoom(room)) {
      throw StateError('Delete for me is not available in group chats');
    }
    final roomId = message.conversationId.trim();
    final eventId = message.id.trim();
    if (roomId.isNotEmpty && eventId.isNotEmpty) {
      final hiddenIds = _hiddenEventIdsForRoom(roomId)..add(eventId);
      _hiddenEventIdsByRoom[roomId] = hiddenIds;
    }
    final updated = message.copyWith(isDeletedForMe: true);
    _replaceCachedMessage(updated);
    await ChatLocalDb.instance.deleteMessageForMe(message.id);
    await _repairConversationPreviewFromVisibleMessages(message.conversationId);
    _emitRoomMessages(message.conversationId);
    _emitConversations();
    unawaited(_hideMessageForMeOnMatrix(message));
  }

  Future<void> _hideMessageForMeOnMatrix(ChatMessage message) async {
    final roomId = message.conversationId.trim();
    final eventId = message.id.trim();
    if (roomId.isEmpty || eventId.isEmpty || !roomId.startsWith('!')) {
      return;
    }

    final hiddenIds = _hiddenEventIdsForRoom(roomId)..add(eventId);
    _hiddenEventIdsByRoom[roomId] = hiddenIds;

    try {
      await _withMatrixTokenRetry('hideMessageForMe', () async {
        await _waitForConnection();
        final client = MatrixClientService.instance.client;
        final userId = client.userID;
        if (userId == null || userId.isEmpty) {
          throw StateError('Matrix user is not logged in');
        }
        final latestHiddenIds = _hiddenEventIdsForRoom(
          roomId,
          room: _roomById(roomId),
        )..add(eventId);
        _hiddenEventIdsByRoom[roomId] = latestHiddenIds;
        final sortedHiddenIds = latestHiddenIds.toList()..sort();
        await client.setAccountDataPerRoom(
          userId,
          roomId,
          _hiddenEventsAccountDataType,
          {
            'hidden_event_ids': sortedHiddenIds,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        );
        apkLog(
          'ChatService.deleteForMe',
          'hidden event persisted room_id="$roomId" event_id="$eventId"',
        );
      });
    } catch (e) {
      apkLog(
        'ChatService.deleteForMe',
        'hidden event server sync failed room_id="$roomId" event_id="$eventId" error="$e"',
      );
    }
  }

  Future<void> deleteMessageForEveryone(ChatMessage message) async {
    await _withMatrixTokenRetry('deleteMessageForEveryone', () async {
      await _waitForConnection();
      final room = _roomById(message.conversationId);
      if (room == null) {
        throw StateError('Unknown Matrix room: ${message.conversationId}');
      }
      final currentUser = room.client.userID ?? _currentUserId ?? '';
      final isOwnMessage = _isOwnMessage(message, currentUser);
      if (MatrixChatService.instance.isMatrixGroupRoom(room) &&
          !isOwnMessage &&
          (!MatrixChatService.instance.isGroupAdmin(room, currentUser) ||
              !room.canRedact)) {
        throw StateError(
          'Only a group admin can delete another member\'s message',
        );
      }
      apkLog(
        'ChatService.redaction',
        'delete requested room_id="${message.conversationId}" '
            'event_id="${message.id}" sender_id="${message.senderId}" '
            'by_admin=${!isOwnMessage}',
      );
      await room.redactEvent(
        message.id,
        reason: isOwnMessage ? 'Deleted by sender' : 'Deleted by admin',
      );
    });
    final currentUser =
        MatrixClientService.instance.client.userID ?? _currentUserId ?? '';
    final deletedContent =
        _isOwnMessage(message, currentUser)
            ? 'This message was deleted'
            : 'This message was deleted by admin';
    final updated = message.copyWith(
      content: deletedContent,
      isDeletedForEveryone: true,
    );
    final cached = _messagesCache[message.conversationId];
    final cachedIndex =
        cached?.indexWhere((item) => item.id == message.id) ?? -1;
    final alreadyApplied =
        cachedIndex != -1 &&
        cached![cachedIndex].isDeletedForEveryone &&
        cached[cachedIndex].content == deletedContent;
    if (!alreadyApplied) {
      _replaceCachedMessage(updated);
      _messageController.add(updated);
    }
    await ChatLocalDb.instance.markMessageDeletedForEveryone(
      message.id,
      content: deletedContent,
    );
    _emitConversations();
    apkLog(
      'ChatService.redaction',
      'delete completed room_id="${message.conversationId}" '
          'event_id="${message.id}" text="$deletedContent" '
          'already_applied=$alreadyApplied',
    );
  }

  Future<void> cancelLocalMessage(ChatMessage message) async {
    _messagesCache[message.conversationId]?.removeWhere(
      (m) => m.id == message.id,
    );
    await ChatLocalDb.instance.deleteMessageForMe(message.id);
    _emitRoomMessages(message.conversationId);
    _emitConversations();
  }

  Future<ChatMessage> forwardMessage({
    required ChatMessage original,
    required String receiverId,
    String? conversationId,
  }) async {
    final existingRoomId = conversationId?.trim() ?? '';
    final room =
        existingRoomId.isNotEmpty
            ? _roomById(existingRoomId)
            : await _directRoom(receiverId);
    if (room == null) {
      throw StateError('Existing forward room is not loaded: $existingRoomId');
    }
    await _validateOwnedGroupForwardTarget(
      original: original,
      targetRoom: room,
      receiverId: receiverId,
    );
    final inferredAttachmentType = _forwardedAttachmentType(original);
    if (inferredAttachmentType != null) {
      return _forwardAttachmentMessage(
        original: original,
        attachmentType: inferredAttachmentType,
        receiverId: receiverId,
        targetRoom: room,
      );
    }
    final message = ChatMessage(
      id: 'fwd_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: room.id,
      senderId:
          MatrixClientService.instance.client.userID ?? _currentUserId ?? '',
      receiverId: _toMatrixUserId(receiverId),
      content: original.content,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      attachmentUrl: original.attachmentUrl,
      attachmentType: original.attachmentType,
      voiceDuration: original.voiceDuration,
      isForwarded: true,
    );
    return sendMessage(message);
  }

  Future<void> _validateOwnedGroupForwardTarget({
    required ChatMessage original,
    required mx.Room targetRoom,
    required String receiverId,
  }) async {
    final sourceRoom = _roomById(original.conversationId);
    if (sourceRoom == null ||
        !MatrixChatService.instance.isMatrixGroupRoom(sourceRoom) ||
        !MatrixChatService.instance.isGroupOwner(sourceRoom)) {
      return;
    }
    if (MatrixChatService.instance.isMatrixGroupRoom(targetRoom)) {
      throw StateError('Group messages can only be forwarded to people');
    }

    final ownerUserId =
        (await AuthService.instance.getCurrentUserId())?.trim() ?? '';
    final peerId = _toMatrixUserId(receiverId);
    final savedContact =
        ownerUserId.isEmpty
            ? null
            : await _savedContactForPeer(
              ownerUserId: ownerUserId,
              peerId: peerId,
              phone: _normalizePhone(receiverId),
            );
    if (savedContact != null) return;

    final currentUser =
        MatrixClientService.instance.client.userID ?? _currentUserId ?? '';
    final history = await ChatLocalDb.instance.loadMessages(targetRoom.id);
    final hasIncomingMessage = history.any(
      (message) =>
          !message.isDeleted &&
          !_isOwnMessage(message, currentUser) &&
          _matrixLocalpart(message.senderId) == _matrixLocalpart(peerId),
    );
    if (!hasIncomingMessage) {
      throw StateError(
        'You can only forward to saved contacts or people who messaged you',
      );
    }
  }

  Future<ChatMessage> _forwardAttachmentMessage({
    required ChatMessage original,
    required String attachmentType,
    required String receiverId,
    required mx.Room targetRoom,
  }) async {
    return _withMatrixTokenRetry('forwardAttachmentMessage', () async {
      await _waitForConnection();
      await MatrixChatService.instance.ensurePeerInvited(
        roomId: targetRoom.id,
        matrixUserId: _toMatrixUserId(receiverId),
      );

      final sourceRoom = _roomById(original.conversationId);
      final sourceEvent = await sourceRoom?.getEventById(original.id);
      String? forwardedAttachmentUrl = original.attachmentUrl;
      String forwardedContent = original.content;
      String? eventId;

      if (sourceEvent != null && sourceEvent.hasAttachment) {
        final sourceMessage = ChatMessage.fromMatrixEvent(sourceEvent);
        forwardedAttachmentUrl =
            sourceMessage?.attachmentUrl ?? forwardedAttachmentUrl;
        if (forwardedContent.trim().isEmpty && sourceMessage != null) {
          forwardedContent = sourceMessage.content;
        }
        final content =
            Map<String, dynamic>.from(sourceEvent.content)
              ..remove('m.relates_to')
              ..remove('m.new_content')
              ..['wrytte.forwarded'] = true;
        eventId = await targetRoom.sendEvent(content);
      } else {
        final path = original.attachmentUrl?.trim() ?? '';
        if (path.isEmpty) {
          throw StateError('The original attachment is not available');
        }
        final bytes =
            _isHttpUrl(path)
                ? await _downloadForwardAttachmentBytes(path)
                : await File(path).readAsBytes();
        final name = _forwardAttachmentFileName(original, path);
        forwardedContent =
            forwardedContent.trim().isEmpty ? name : forwardedContent;
        final matrixFile = mx.MatrixFile.fromMimeType(bytes: bytes, name: name);
        eventId = await targetRoom.sendFileEvent(
          matrixFile,
          extraContent:
              attachmentType == 'file'
                  ? const {
                    'wrytte.forwarded': true,
                    'wrytte.sent_as_file': true,
                  }
                  : const {'wrytte.forwarded': true},
        );
      }

      final sent = ChatMessage(
        id: eventId ?? 'fwd_${DateTime.now().millisecondsSinceEpoch}',
        conversationId: targetRoom.id,
        senderId:
            MatrixClientService.instance.client.userID ?? _currentUserId ?? '',
        receiverId: _toMatrixUserId(receiverId),
        content: forwardedContent,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        attachmentUrl: forwardedAttachmentUrl,
        attachmentType: attachmentType,
        voiceDuration: original.voiceDuration,
        senderPhone: _currentUserPhone,
        isForwarded: true,
      );
      _cacheMessage(sent);
      unawaited(
        _refreshPeerProfileFromBackendForMessage(
          sent,
          reason: 'forwardAttachmentMessage',
        ),
      );
      return sent;
    });
  }

  String? _forwardedAttachmentType(ChatMessage message) {
    final explicit = message.attachmentType?.trim().toLowerCase();
    if (explicit?.isNotEmpty == true) return explicit;

    final value =
        [
          message.attachmentUrl,
          message.content,
        ].whereType<String>().join(' ').toLowerCase();
    if (value.isEmpty) return null;

    if (RegExp(
      r'\.(png|jpe?g|gif|webp|bmp|heic|heif)(?:$|[?#\s])',
    ).hasMatch(value)) {
      return 'image';
    }
    if (RegExp(r'\.(mp4|mov|m4v|webm|mkv|3gp)(?:$|[?#\s])').hasMatch(value)) {
      return 'video';
    }
    if (RegExp(
      r'\.(pdf|docx?|pptx?|xlsx?|txt|csv|zip|rar|7z|apk)(?:$|[?#\s])',
    ).hasMatch(value)) {
      return 'file';
    }
    return null;
  }

  bool _isHttpUrl(String value) =>
      value.startsWith('http://') || value.startsWith('https://');

  Future<Uint8List> _downloadForwardAttachmentBytes(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Could not download original attachment: HTTP ${response.statusCode}',
        );
      }
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }
      return Uint8List.fromList(chunks);
    } finally {
      client.close(force: true);
    }
  }

  String _forwardAttachmentFileName(ChatMessage message, String source) {
    final contentName = message.content.trim();
    if (contentName.isNotEmpty && !contentName.contains('\n')) {
      return contentName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    }
    final uri = Uri.tryParse(source);
    final uriName = uri == null ? '' : p.basename(uri.path);
    if (uriName.isNotEmpty) return uriName;
    return p.basename(source);
  }

  Future<String?> getMatrixConversationId(String otherUserId) async {
    try {
      await _waitForConnection();
      final room = await _directRoom(otherUserId);
      apkLog(
        'ChatService',
        'Matrix direct room ready room_id="${room.id}" otherUserId="$otherUserId"',
      );
      return room.id;
    } catch (e) {
      if (MatrixAuthService.isUnknownToken(e)) {
        try {
          apkLog(
            'ChatService',
            'Matrix direct room got M_UNKNOWN_TOKEN; refreshing session and retrying otherUserId="$otherUserId"',
          );
          await _refreshCurrentMatrixSession();
          final room = await _directRoom(otherUserId);
          apkLog(
            'ChatService',
            'Matrix direct room ready after token refresh room_id="${room.id}" otherUserId="$otherUserId"',
          );
          return room.id;
        } catch (retryError) {
          debugPrint(
            '[ChatService] get conversation id retry error: $retryError',
          );
        }
      }
      debugPrint('[ChatService] get conversation id error: $e');
      return null;
    }
  }

  Future<void> _refreshCurrentMatrixSession() async {
    final user = await AuthService.instance.getCurrentUser();
    final userId = user?.userId ?? _currentUserId;
    if (userId == null || userId.isEmpty) {
      throw StateError('User not authenticated');
    }
    final expectedMatrixUserId = _expectedMatrixUserId(userId);
    await MatrixAuthService.instance.clearLocalSession();
    final client = await _loginCurrentMatrixSession(
      expectedMatrixUserId: expectedMatrixUserId,
      userId: userId,
      nickname: user?.username ?? userId,
      forceFreshSession: true,
    );
    if (!client.isLogged() || client.userID != expectedMatrixUserId) {
      throw StateError('Matrix token refresh failed.');
    }
    _isConnected = false;
    await connect();
  }

  Future<String?> findMatrixConversationId(String otherUserId) async {
    try {
      await _waitForConnection();
      final room = await MatrixChatService.instance.findDirectRoom(
        _toMatrixUserId(otherUserId),
      );
      return room?.id;
    } catch (e) {
      debugPrint('[ChatService] find conversation id error: $e');
      return null;
    }
  }

  bool isVerifiedDirectConversation(String roomId, String otherUserId) =>
      MatrixChatService.instance.isVerifiedDirectRoomFor(
        roomId,
        _toMatrixUserId(otherUserId),
      );

  Future<void> disconnect() async {
    if (!_isConnected) return;
    await reset();
  }

  Future<void> reset() async {
    _isConnected = false;
    _runtimeGeneration++;
    final pendingWork = <Future<dynamic>>{
      if (_historyRestoreFuture != null) _historyRestoreFuture!,
      ..._roomHistoryInFlight.values,
      ..._suggestedPreviewInFlight.values,
    };
    // Cancel event sources before clearing credentials or local storage.
    // In-flight HTTP requests cannot always be interrupted, so the generation
    // guard above prevents their late responses from writing after logout.
    await _timelineSub?.cancel();
    await _syncSub?.cancel();
    await _toDeviceSub?.cancel();
    _timelineSub = null;
    _syncSub = null;
    _toDeviceSub = null;
    // Give an operation that is already inside a local SQLite write a brief
    // chance to finish before logout closes and deletes the database. Network
    // work is not awaited; its generation is now stale and cannot write.
    if (pendingWork.isNotEmpty) {
      await Future.wait(
        pendingWork.map((future) => future.catchError((_) => null)),
      ).timeout(const Duration(seconds: 1), onTimeout: () => const []);
    }
    _loginHistoryPrepared = false;
    _connectFuture = null;
    _loginHistoryPreparationFuture = null;
    _historyRestoreFuture = null;
    _roomHistoryInFlight.clear();
    _suggestedPreviewInFlight.clear();
    _attachmentPrefetchInFlight.clear();
    for (final timer in _attachmentCacheSummaryTimers.values) {
      timer.cancel();
    }
    _attachmentCacheSummaryTimers.clear();
    _attachmentCacheExpectedByRoom.clear();
    _attachmentCacheCompleteByRoom.clear();
    _attachmentCacheFailedByRoom.clear();
    _attachmentCachePendingByRoom.clear();
    _channelCacheCategoryByRoom.clear();
    _channelCachedMessageCountByRoom.clear();
    _channelHistoryCachedByRoom.clear();
    _groupCacheCategoryByRoom.clear();
    _groupCachedMessageCountByRoom.clear();
    _groupHistoryCachedByRoom.clear();
    _directCacheCategoryByRoom.clear();
    _directCachedMessageCountByRoom.clear();
    _directHistoryCachedByRoom.clear();
    _roomsRefreshTimer?.cancel();
    _roomsRefreshTimer = null;
    _lastRoomsRefreshAt = null;
    _currentUserId = null;
    _currentUserPhone = null;
    _currentUserName = null;
    _conversationsMap.clear();
    _messagesCache.clear();
    _hiddenEventIdsByRoom.clear();
    _pinnedForMeEventIdsByRoom.clear();
    _pendingPinnedForMeEventIdsByRoom.clear();
    _mdlAccountDataTimer?.cancel();
    _mdlAccountDataTimer = null;
    _pendingDeliveredEventId = null;
    _pendingDeliveredRoomId = null;
    _typingRoomIds.clear();
    _deliveredToDeviceEventIds.clear();
    _lastReadReceiptEventByConversation.clear();
    _dismissedDeletedGroupRoomIds.clear();
    _readConversationIds.clear();
    _activeReadConversationIds.clear();
    _lastReadAtByConversation.clear();
    _profileRefreshInFlight.clear();
    MatrixChatService.instance.resetRuntimeState();
    for (final controller in _roomMessagesControllers.values) {
      if (!controller.isClosed) controller.add(const []);
    }
    _connectionController.add(false);
  }

  void dispose() {
    disconnect();
    for (final controller in _roomMessagesControllers.values) {
      controller.close();
    }
    _roomMessagesControllers.clear();
    _messageController.close();
    _errorController.close();
    _connectionController.close();
    _conversationsController.close();
  }

  mx.Room _roomForMessage(ChatMessage message) {
    final byConversation = _roomById(message.conversationId);
    if (byConversation != null) return byConversation;
    throw StateError(
      'Conversation ${message.conversationId} is not loaded. '
      'Call getMatrixConversationId(receiverId) before sending.',
    );
  }

  Future<mx.Room> _directRoom(String otherUserId) async => MatrixChatService
      .instance
      .getOrCreateDirectRoom(_toMatrixUserId(otherUserId));

  Future<bool> isGroupAliasAvailable(String aliasLocalpart) {
    return MatrixChatService.instance.isRoomAliasAvailable(aliasLocalpart);
  }

  Future<ChatConversation> createGroupConversation({
    required String name,
    required bool isPublic,
    String? aliasLocalpart,
    List<String> memberIds = const [],
    String conversationKind = ConversationKind.group,
    String link = '',
  }) async {
    final kind = ConversationKind.normalize(conversationKind);
    if (kind != ConversationKind.group && kind != ConversationKind.channel) {
      throw ArgumentError('Conversation kind must be a group or channel.');
    }
    await connect();
    final invites =
        memberIds
            .map((id) => _toMatrixUserId(id))
            .where((id) => id != MatrixClientService.instance.client.userID)
            .toSet()
            .toList();
    final createdRoom = await MatrixChatService.instance.createGroupRoom(
      name: name,
      isPublic: isPublic,
      aliasLocalpart: aliasLocalpart,
      invite: invites,
      conversationKind: kind,
      link: link,
    );
    final room = createdRoom.room;
    final roomId = createdRoom.roomId;
    final now = DateTime.now();
    final conversation = ChatConversation(
      id: roomId,
      participants: [
        if (MatrixClientService.instance.client.userID != null)
          MatrixClientService.instance.client.userID!,
        ...invites,
      ],
      otherUserId: roomId,
      lastMessage: '',
      lastMessageSenderId: MatrixClientService.instance.client.userID ?? '',
      lastMessageTime: now,
      unreadCount: 0,
      lastMessageType: 'group',
      otherUserName: name.trim(),
      otherUserAvatar: room == null ? null : _groupRoomAvatarUrl(room),
      conversationKind: kind,
    );
    _conversationsMap[roomId] = conversation;
    await markGroupCreated(roomId);
    await ChatLocalDb.instance.saveConversations([conversation]);
    _emitConversations();
    apkLog(
      'ChatService.groupCreate',
      'saved local $kind room_id="$roomId" name="${name.trim()}" participants=${conversation.participants.length}',
    );
    return conversation;
  }

  Future<ChatConversation> saveJoinedGroupShell({
    required String roomId,
    required String name,
    String? avatarUrl,
    String conversationKind = ConversationKind.group,
  }) async {
    final id = roomId.trim();
    if (id.isEmpty) {
      throw ArgumentError('Group room id is required.');
    }
    final now = DateTime.now();
    final conversation = ChatConversation(
      id: id,
      participants: [
        if (MatrixClientService.instance.client.userID != null)
          MatrixClientService.instance.client.userID!,
      ],
      otherUserId: id,
      lastMessage: '',
      lastMessageSenderId: MatrixClientService.instance.client.userID ?? '',
      lastMessageTime: now,
      unreadCount: 0,
      lastMessageType: 'group',
      otherUserName: name.trim().isEmpty ? 'Group' : name.trim(),
      otherUserAvatar: avatarUrl,
      conversationKind: conversationKind,
    );
    await markGroupJoined(id);
    await clearGroupJoinCutoff(id);
    final existing = _conversationsMap[id];
    _conversationsMap[id] =
        existing == null
            ? conversation
            : _preferImmediateConversation(
              existing,
              conversation,
            ).copyWith(conversationKind: conversationKind);
    await ChatLocalDb.instance.saveConversations([_conversationsMap[id]!]);
    _emitConversations();
    return _conversationsMap[id]!;
  }

  Future<ChatConversation?> markGroupDeletedLocally({
    required String roomId,
    required String name,
    String? avatarUrl,
    List<String> participants = const [],
    DateTime? deletedAt,
    String? deletedBy,
  }) async {
    final id = roomId.trim();
    if (id.isEmpty) {
      throw ArgumentError('Group room id is required.');
    }
    if (_dismissedDeletedGroupRoomIds.contains(id)) {
      await _purgeLocalConversationContent(id);
      _conversationsMap.remove(id);
      await ChatLocalDb.instance.deleteConversation(id);
      _emitConversations();
      return null;
    }
    await _purgeLocalConversationContent(id);
    final now = deletedAt ?? DateTime.now();
    final existing = _conversationsMap[id];
    final currentUser = MatrixClientService.instance.client.userID;
    final memberIds =
        <String>{
          if (currentUser != null && currentUser.trim().isNotEmpty) currentUser,
          if (existing != null) ...existing.participants,
          ...participants,
        }.where((memberId) => memberId.trim().isNotEmpty).toList();
    final deletedByIds =
        <String>{
          if (existing != null) ...existing.deletedBy,
          if (deletedBy != null && deletedBy.trim().isNotEmpty) deletedBy,
        }.toList();
    final title = _cleanHumanName(name);
    final conversation = ChatConversation(
      id: id,
      participants: memberIds,
      otherUserId: id,
      lastMessage: 'This group has been deleted',
      lastMessageSenderId: deletedBy?.trim() ?? currentUser ?? '',
      lastMessageTime: now,
      unreadCount: existing?.unreadCount ?? 0,
      lastMessageType: groupDeletedMessageType,
      isArchived: existing?.isArchived ?? false,
      isMuted: existing?.isMuted ?? false,
      isPinned: existing?.isPinned ?? false,
      mutedUntil: existing?.mutedUntil,
      lastSeen: existing?.lastSeen ?? const {},
      createdAt: existing?.createdAt,
      deletedAt: now,
      deletedBy: deletedByIds,
      otherUserName:
          title.isNotEmpty
              ? title
              : _cleanHumanName(existing?.otherUserName).isNotEmpty
              ? existing!.otherUserName
              : 'Deleted Group',
      otherUserAvatar: avatarUrl ?? existing?.otherUserAvatar,
      conversationKind: ConversationKind.group,
    );
    _conversationsMap[id] = conversation;
    await ChatLocalDb.instance.saveConversations([conversation]);
    _emitRoomMessages(id);
    _emitConversations();
    return conversation;
  }

  mx.Room? _roomById(String roomId) {
    for (final room in MatrixClientService.instance.client.rooms) {
      if (room.id == roomId) return room;
    }
    return null;
  }

  String _kindForGroupRoom(mx.Room room) {
    final roomType =
        room
            .getState(mx.EventTypes.RoomCreate)
            ?.content['type']
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';
    if (roomType == MatrixPublicGroup.channelRoomType) {
      return ConversationKind.channel;
    }

    final stateKind = ConversationKind.normalize(
      room
              .getState('com.wrytte.group.info')
              ?.content['conversation_kind']
              ?.toString() ??
          '',
    );
    if (stateKind == ConversationKind.channel ||
        stateKind == ConversationKind.group) {
      return stateKind;
    }

    final alias = room.canonicalAlias.trim();
    final localpart = alias.startsWith('#') ? alias.substring(1) : alias;
    if (localpart.startsWith('gr.@')) return ConversationKind.group;
    if (localpart.startsWith('@') || localpart.startsWith('.@')) {
      return ConversationKind.channel;
    }
    return ConversationKind.group;
  }

  ChatConversation _toConversation(mx.Room room) {
    final client = MatrixClientService.instance.client;
    final existing = _conversationsMap[room.id];
    final isGroupRoom = _isGroupRoom(room, existing);
    final cleanRoomName = _cleanHumanName(room.name);
    if (isGroupRoom) {
      final last = room.lastEvent;
      final deletedState = room.getState(groupDeletedStateType);
      final lastMessage =
          last == null ? null : ChatMessage.fromMatrixEvent(last);
      final visibleLastMessage =
          lastMessage != null &&
                  _isDisplayableMessage(lastMessage) &&
                  !_isHiddenForMe(lastMessage) &&
                  !_isBeforeGroupJoinCutoff(lastMessage)
              ? lastMessage
              : null;
      final groupName = _groupDisplayName(room, existing);
      final participants =
          <String>{
            if (client.userID != null) client.userID!,
            if (existing != null) ...existing.participants,
            ...room.getParticipants().map((user) => user.id),
          }.where((id) => id.trim().isNotEmpty).toList();
      final deletedAt =
          deletedState?.content[groupDeletedEventKey] == true
              ? _groupDeletedAtFromContent(deletedState!.content) ??
                  DateTime.now()
              : last != null && _isGroupDeletedMatrixEvent(last)
              ? _groupDeletedAtFromEvent(last) ?? last.originServerTs
              : existing?.deletedAt;
      return ChatConversation(
        id: room.id,
        participants: participants,
        otherUserId: room.id,
        lastMessage: deletedAt == null ? visibleLastMessage?.content ?? '' : '',
        lastMessageSenderId:
            visibleLastMessage?.senderId ?? existing?.lastMessageSenderId ?? '',
        lastMessageTime:
            visibleLastMessage?.timestamp ??
            existing?.lastMessageTime ??
            DateTime.now(),
        unreadCount: _displayableUnreadCountForRoom(room, client.userID),
        lastMessageType: deletedAt == null ? 'group' : groupDeletedMessageType,
        conversationKind: () {
          final derived = _kindForGroupRoom(room);
          if (derived == ConversationKind.channel) return derived;
          return existing?.hasExplicitKind == true
              ? existing!.conversationKind
              : derived;
        }(),
        deletedAt: deletedAt,
        deletedBy:
            deletedState?.content[groupDeletedEventKey] == true
                ? [
                  if (_groupDeletedByFromContent(
                    deletedState!.content,
                    deletedState.senderId,
                  ).trim().isNotEmpty)
                    _groupDeletedByFromContent(
                      deletedState.content,
                      deletedState.senderId,
                    ),
                ]
                : last != null && _isGroupDeletedMatrixEvent(last)
                ? [
                  if (_groupDeletedByFromEvent(last).trim().isNotEmpty)
                    _groupDeletedByFromEvent(last),
                ]
                : existing?.deletedBy ?? const [],
        otherUserName: groupName,
        otherUserAvatar: _groupRoomAvatarUrl(room),
      );
    }
    final otherId =
        _roomPeerMatrixId(room, client.userID) ??
        _usableConversationPeer(existing, client.userID) ??
        _fallbackPeerFromCachedMessages(room.id, client.userID) ??
        room.id;
    final last = room.lastEvent;
    final lastMessage = last == null ? null : ChatMessage.fromMatrixEvent(last);
    final incomingSenderPhone =
        lastMessage == null ||
                client.userID == null ||
                _isOwnMessage(lastMessage, client.userID!)
            ? ''
            : _normalizePhone(lastMessage.senderPhone ?? '');
    final cachedName =
        existing == null ? '' : _cleanHumanName(existing.otherUserName);
    final roomName = room.getLocalizedDisplayname();
    final shouldUseRoomName =
        cleanRoomName.isNotEmpty && !_isOwnMatrixId(roomName, client.userID);
    return ChatConversation(
      id: room.id,
      participants: [if (client.userID != null) client.userID!, otherId],
      otherUserId: otherId,
      lastMessage: last?.body ?? '',
      lastMessageSenderId: last?.senderId ?? '',
      lastMessageTime: last?.originServerTs ?? DateTime.now(),
      unreadCount: _displayableUnreadCountForRoom(room, client.userID),
      otherUserName:
          incomingSenderPhone.isNotEmpty
              ? incomingSenderPhone
              : cachedName.isNotEmpty
              ? cachedName
              : shouldUseRoomName
              ? cleanRoomName
              : existing?.otherUserName,
      otherUserAvatar: existing?.otherUserAvatar ?? room.avatar?.toString(),
      conversationKind:
          existing?.hasExplicitKind == true
              ? existing!.conversationKind
              : (room.isDirectChat
                  ? ConversationKind.direct
                  : ConversationKind.unknown),
    );
  }

  bool _isGroupRoom(mx.Room room, ChatConversation? existing) {
    // The room tombstone is authoritative and must be checked before cached
    // kind or Matrix DM heuristics. A deleted group can temporarily have only
    // one visible participant, which otherwise makes it look like a 1:1 room.
    if (room.getState(groupDeletedStateType)?.content[groupDeletedEventKey] ==
        true) {
      return true;
    }
    if (existing != null && existing.hasExplicitKind) {
      return existing.isGroupKind || existing.isChannelKind;
    }
    if (room.isDirectChat) return false;
    if (existing?.lastMessageType == groupDeletedMessageType) return true;
    if (existing?.lastMessageType == 'group' &&
        existing?.id.startsWith('!') == true &&
        existing?.otherUserId == existing?.id) {
      return true;
    }
    if (MatrixChatService.instance.isMatrixGroupRoom(room)) return true;
    if (existing?.id.startsWith('!') == true &&
        existing?.otherUserId == existing?.id &&
        !MatrixChatService.instance.looksLikeUnmarkedDirectRoom(room)) {
      return true;
    }
    return false;
  }

  String _groupDisplayName(mx.Room room, ChatConversation? existing) {
    final deletedName =
        room
            .getState(groupDeletedStateType)
            ?.content[groupDeletedNameKey]
            ?.toString()
            .trim() ??
        '';
    final cleanDeletedName = _cleanHumanName(deletedName);
    if (cleanDeletedName.isNotEmpty) return cleanDeletedName;
    for (final candidate in [
      room.name,
      _displayAlias(room.canonicalAlias),
      _createdGroupRoomIds.contains(room.id) ? existing?.otherUserName : null,
    ]) {
      final name = _cleanHumanName(candidate);
      if (name.isEmpty) continue;
      if (name.startsWith('gr.@')) continue;
      if (_looksLikeDirectMemberNameForGroup(room, name)) continue;
      return name;
    }
    return 'Group';
  }

  String? _groupRoomAvatarUrl(mx.Room room) {
    final raw = room.getState(mx.EventTypes.RoomAvatar)?.content['url'];
    final avatar = raw is String ? raw.trim() : '';
    if (avatar.isEmpty || _matchesGroupParticipantAvatar(room, avatar)) {
      return null;
    }
    return avatar;
  }

  bool _matchesGroupParticipantAvatar(mx.Room room, String avatarUrl) {
    final normalizedAvatar = _normaliseAvatarIdentity(avatarUrl);
    if (normalizedAvatar.isEmpty) return false;
    for (final member in room.getParticipants([
      mx.Membership.join,
      mx.Membership.invite,
    ])) {
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
    final isLegacyMedia =
        mediaIndex >= 1 &&
        mediaIndex + 4 < segments.length &&
        segments[mediaIndex - 1] == '_matrix' &&
        segments[mediaIndex + 1] == 'v3' &&
        (segments[mediaIndex + 2] == 'download' ||
            segments[mediaIndex + 2] == 'thumbnail');
    final isAuthenticatedMedia =
        mediaIndex >= 2 &&
        mediaIndex + 3 < segments.length &&
        segments[mediaIndex - 2] == '_matrix' &&
        segments[mediaIndex - 1] == 'client' &&
        segments[mediaIndex + 1] == 'download';
    if (isLegacyMedia || isAuthenticatedMedia) {
      final serverIndex = isLegacyMedia ? mediaIndex + 3 : mediaIndex + 2;
      final serverName = segments[serverIndex];
      final mediaId = segments.sublist(serverIndex + 1).join('/');
      if (serverName.isNotEmpty && mediaId.isNotEmpty) {
        return 'mxc://$serverName/$mediaId';
      }
    }
    return trimmed;
  }

  String _displayAlias(String? alias) {
    final raw = alias?.trim() ?? '';
    if (raw.isEmpty) return '';
    final withoutHash = raw.startsWith('#') ? raw.substring(1) : raw;
    return withoutHash.split(':').first.trim();
  }

  bool _looksLikeDirectMemberNameForGroup(mx.Room room, String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    for (final user in room.getParticipants([mx.Membership.join])) {
      if (user.id == MatrixClientService.instance.client.userID) continue;
      final memberName = _cleanHumanName(user.calcDisplayname()).toLowerCase();
      if (memberName.isNotEmpty && memberName == normalized) return true;
    }
    return false;
  }

  String? _usableConversationPeer(ChatConversation? conversation, String? me) {
    final peer = conversation?.otherUserId.trim() ?? '';
    if (peer.isEmpty || peer.startsWith('!') || peer.startsWith('@!')) {
      return null;
    }
    if (_isOwnMatrixId(peer, me)) return null;
    return peer;
  }

  String? _fallbackPeerFromCachedMessages(String roomId, String? me) {
    final cached = _messagesCache[roomId];
    if (cached == null || cached.isEmpty) return null;
    for (final message in cached.reversed) {
      final sender = message.senderId.trim();
      if (_isValidMatrixUserId(sender) && !_isOwnMatrixId(sender, me)) {
        return sender;
      }
      final receiver = message.receiverId.trim();
      if (_isValidMatrixUserId(receiver) && !_isOwnMatrixId(receiver, me)) {
        return receiver;
      }
      final phone = _normalizePhone(message.senderPhone ?? '');
      if (phone.isNotEmpty && !_isOwnMatrixId(message.senderId, me)) {
        return phone;
      }
    }
    return null;
  }

  int _displayableUnreadCountForRoom(mx.Room room, String? currentUser) {
    if (currentUser == null || currentUser.isEmpty) return 0;
    if (_activeReadConversationIds.contains(room.id)) return 0;
    final readAt = _lastReadAtByConversation[room.id];
    if (_suppressRestoredRoomUnread && readAt == null) return 0;

    final cached = _messagesCache[room.id];
    if (cached != null && cached.isNotEmpty) {
      return cached
          .where(
            (message) =>
                !_isHiddenForMe(message) &&
                _isDisplayableMessage(message) &&
                !_isOwnMessage(message, currentUser) &&
                _isAfterReadMarker(message, room.id),
          )
          .length;
    }

    if (_readConversationIds.contains(room.id)) return 0;

    final last = room.lastEvent;
    final lastMessage = last == null ? null : ChatMessage.fromMatrixEvent(last);
    if (!_isDisplayableMessage(lastMessage) || _isHiddenForMe(lastMessage!)) {
      return 0;
    }
    if (_isOwnMessage(lastMessage, currentUser)) return 0;
    if (readAt != null && !lastMessage.timestamp.isAfter(readAt)) return 0;
    return 1;
  }

  void _refreshConversationsFromRooms({bool force = false}) {
    final now = DateTime.now();
    final lastRefresh = _lastRoomsRefreshAt;
    if (!force && lastRefresh != null) {
      final elapsed = now.difference(lastRefresh);
      if (elapsed < _roomsRefreshMinInterval) {
        _roomsRefreshTimer ??= Timer(_roomsRefreshMinInterval - elapsed, () {
          _roomsRefreshTimer = null;
          _refreshConversationsFromRooms(force: true);
        });
        return;
      }
    }

    _roomsRefreshTimer?.cancel();
    _roomsRefreshTimer = null;
    _lastRoomsRefreshAt = now;
    _refreshConversationsFromRoomsNow();
  }

  void _refreshConversationsFromRoomsNow() {
    // ✅ Snapshot to avoid ConcurrentModificationError when sync
    // updates arrive while we're iterating.
    final rooms = List<mx.Room>.from(MatrixClientService.instance.client.rooms);

    final previousFingerprint = _conversationsFingerprint(_conversationsMap);

    for (final room in rooms) {
      // was: for (final room in client.rooms)
      _syncHiddenEventsFromRoom(room);
      _syncPinnedForMeFromRoom(room);
      _cacheRoomIdentity(room);
    }

    final merged = Map<String, ChatConversation>.from(_conversationsMap);
    var restoredFromCache = 0;
    var refreshedFromMatrix = 0;
    for (final room in rooms) {
      // Leave/forget can remain visible in an in-flight or stale /sync. Never
      // recreate a room which this account has permanently dismissed.
      if (_dismissedDeletedGroupRoomIds.contains(room.id)) {
        merged.remove(room.id);
        _conversationsMap.remove(room.id);
        _messagesCache.remove(room.id);
        unawaited(removeConversationLocally(room.id));
        continue;
      }
      final existing = _conversationWithVisiblePreview(merged[room.id]);
      final deletedState = room.getState(groupDeletedStateType);
      if (deletedState?.content[groupDeletedEventKey] == true) {
        // Clear memory immediately so the UI can never briefly render the old
        // timeline while the SQLite purge completes.
        _messagesCache[room.id] = <ChatMessage>[];
        final deletedName =
            deletedState!.content[groupDeletedNameKey]?.toString().trim() ?? '';
        unawaited(
          markGroupDeletedLocally(
            roomId: room.id,
            name: deletedName,
            avatarUrl: _groupRoomAvatarUrl(room),
            participants:
                room.getParticipants().map((member) => member.id).toList(),
            deletedAt:
                _groupDeletedAtFromContent(deletedState.content) ??
                DateTime.now(),
            deletedBy: _groupDeletedByFromContent(
              deletedState.content,
              deletedState.senderId,
            ),
          ),
        );
      }
      final lastMessage =
          room.lastEvent == null
              ? null
              : ChatMessage.fromMatrixEvent(room.lastEvent!);
      final hasDisplayableMatrixLast =
          lastMessage != null &&
          _isDisplayableMessage(lastMessage) &&
          !_isHiddenForMe(lastMessage) &&
          !_isBeforeGroupJoinCutoff(lastMessage);
      final hasCachedPreview = existing?.lastMessage.trim().isNotEmpty == true;
      final hasCachedMessages = (_messagesCache[room.id] ??
              const <ChatMessage>[])
          .where(
            (message) =>
                !_isHiddenForMe(message) && !_isBeforeGroupJoinCutoff(message),
          )
          .any(_isDisplayableMessage);
      final isGroupRoom = _isGroupRoom(room, existing);

      if (!hasDisplayableMatrixLast &&
          !hasCachedPreview &&
          !hasCachedMessages &&
          !isGroupRoom) {
        continue;
      }

      final matrixConversation = _toConversation(room);
      merged.removeWhere(
        (id, conversation) =>
            id != room.id &&
            !id.startsWith('!') &&
            _matrixLocalpart(conversation.otherUserId) ==
                _matrixLocalpart(matrixConversation.otherUserId),
      );
      merged[room.id] =
          existing == null
              ? matrixConversation
              : _preferImmediateConversation(existing, matrixConversation);
      if (hasDisplayableMatrixLast) {
        refreshedFromMatrix += 1;
      } else {
        restoredFromCache += 1;
      }
    }

    _conversationsMap
      ..clear()
      ..addAll(merged);
    final scrubbed = _scrubDirectAvatarsMatchingGroupsInMemory();
    final nextFingerprint = _conversationsFingerprint(_conversationsMap);
    if (previousFingerprint == nextFingerprint && scrubbed.isEmpty) {
      return;
    }
    apkLog(
      'ChatService.rooms',
      'merged conversations total=${_conversationsMap.length} matrix=$refreshedFromMatrix cached=$restoredFromCache',
    );
    if (scrubbed.isNotEmpty) {
      apkLog(
        'ChatService.avatarScrub',
        'cleared group avatars from ${scrubbed.length} direct conversations',
      );
    }
    unawaited(
      ChatLocalDb.instance.replaceConversations(
        _conversationsMap.values.toList(),
      ),
    );
    _emitConversations();
  }

  String _conversationsFingerprint(
    Map<String, ChatConversation> conversations,
  ) {
    final ids = conversations.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final id in ids) {
      final conversation = conversations[id]!;
      final participants = conversation.participants.toList()..sort();
      buffer
        ..write(id)
        ..write('|${conversation.conversationKind}')
        ..write('|${conversation.otherUserId}')
        ..write('|${conversation.otherUserName ?? ''}')
        ..write('|${conversation.otherUserAvatar ?? ''}')
        ..write('|${conversation.lastMessage}')
        ..write('|${conversation.lastMessageSenderId}')
        ..write('|${conversation.lastMessageTime.millisecondsSinceEpoch}')
        ..write('|${conversation.lastMessageType}')
        ..write('|${conversation.unreadCount}')
        ..write('|${conversation.isArchived}')
        ..write('|${conversation.isMuted}')
        ..write('|${conversation.isPinned}')
        ..write('|${conversation.deletedAt?.millisecondsSinceEpoch ?? ''}')
        ..write('|${participants.join(',')};');
    }
    return buffer.toString();
  }

  ChatConversation? _conversationWithVisiblePreview(
    ChatConversation? conversation,
  ) {
    if (conversation == null) return null;
    if (conversation.lastMessageType == groupDeletedMessageType ||
        conversation.deletedAt != null) {
      return conversation;
    }
    final visible = getConversationMessages(conversation.id);
    if (visible.isEmpty) {
      if (conversation.lastMessage.trim().isEmpty &&
          conversation.lastMessageSenderId.trim().isEmpty) {
        return conversation;
      }
      return conversation.copyWith(lastMessage: '', lastMessageSenderId: '');
    }

    final last = visible.last;
    if (conversation.lastMessage == last.content &&
        conversation.lastMessageSenderId == last.senderId &&
        conversation.lastMessageTime == last.timestamp) {
      return conversation;
    }
    return conversation.copyWith(
      lastMessage: last.content,
      lastMessageSenderId: last.senderId,
      lastMessageTime: last.timestamp,
      lastMessageType:
          conversation.lastMessageType == 'group'
              ? 'group'
              : last.attachmentType ?? conversation.lastMessageType,
    );
  }

  ChatConversation _preferImmediateConversation(
    ChatConversation cached,
    ChatConversation incoming,
  ) {
    // A persistent room tombstone is authoritative over every cached preview.
    // Never allow an old message to turn a deleted group back into a live one.
    if (incoming.deletedAt != null) {
      return incoming.copyWith(
        unreadCount: 0,
        lastMessage: '',
        lastMessageSenderId: '',
        lastMessageType: groupDeletedMessageType,
        conversationKind: ConversationKind.group,
      );
    }
    if (cached.lastMessageType == groupDeletedMessageType ||
        cached.deletedAt != null) {
      return cached.copyWith(
        unreadCount: _mergedUnreadCount(cached, incoming),
        participants:
            cached.participants.isNotEmpty
                ? cached.participants
                : incoming.participants,
        otherUserName:
            _cleanHumanName(cached.otherUserName).isNotEmpty
                ? cached.otherUserName
                : incoming.otherUserName,
        otherUserAvatar: cached.otherUserAvatar ?? incoming.otherUserAvatar,
      );
    }
    final incomingHasMessage = incoming.lastMessage.trim().isNotEmpty;
    final cachedHasMessage = cached.lastMessage.trim().isNotEmpty;
    final unreadCount = _mergedUnreadCount(cached, incoming);
    final incomingIsDirect =
        incoming.lastMessageType != 'group' &&
        incoming.otherUserId.trim().isNotEmpty &&
        !incoming.otherUserId.startsWith('!');
    final room = _roomById(incoming.id) ?? _roomById(cached.id);
    final looksDirect =
        room != null &&
        (room.isDirectChat ||
            MatrixChatService.instance.looksLikeUnmarkedDirectRoom(room));
    final explicitKind =
        cached.hasExplicitKind
            ? cached.conversationKind
            : incoming.hasExplicitKind
            ? incoming.conversationKind
            : ConversationKind.unknown;
    final cachedIsGroup =
        explicitKind != ConversationKind.unknown
            ? explicitKind == ConversationKind.group ||
                explicitKind == ConversationKind.channel
            : !incomingIsDirect &&
                !looksDirect &&
                (cached.lastMessageType == 'group' ||
                    (cached.id.startsWith('!') &&
                        cached.otherUserId == cached.id &&
                        cached.participants.length > 2));
    if (!incomingHasMessage && cachedHasMessage) {
      if (cachedIsGroup) {
        final groupName = _groupConversationName(room, incoming, cached);
        final groupAvatar = _groupConversationAvatar(room, incoming, cached);
        return cached.copyWith(
          unreadCount: unreadCount,
          otherUserId: cached.id,
          lastMessageType: 'group',
          otherUserName: groupName,
          otherUserAvatar: groupAvatar,
          conversationKind:
              explicitKind != ConversationKind.unknown
                  ? explicitKind
                  : ConversationKind.group,
        );
      }
      return cached.copyWith(
        unreadCount: unreadCount,
        otherUserId:
            incoming.otherUserId.startsWith('!')
                ? cached.otherUserId
                : incoming.otherUserId,
        participants:
            incoming.otherUserId.startsWith('!')
                ? cached.participants
                : incoming.participants,
        otherUserName: _preferCachedDisplayValue(
          cached.otherUserName,
          incoming.otherUserName,
        ),
        otherUserAvatar: cached.otherUserAvatar ?? incoming.otherUserAvatar,
        conversationKind: explicitKind,
      );
    }
    if (cachedIsGroup) {
      return incoming.copyWith(
        unreadCount: unreadCount,
        otherUserId: incoming.id,
        lastMessageType: 'group',
        otherUserName: _groupConversationName(room, incoming, cached),
        otherUserAvatar: _groupConversationAvatar(room, incoming, cached),
        conversationKind:
            explicitKind != ConversationKind.unknown
                ? explicitKind
                : ConversationKind.group,
      );
    }
    return incoming.copyWith(
      unreadCount: unreadCount,
      otherUserId: incoming.otherUserId,
      lastMessageType: incoming.lastMessageType,
      otherUserName: _preferCachedDisplayValue(
        cached.otherUserName,
        incoming.otherUserName,
      ),
      otherUserAvatar: cached.otherUserAvatar ?? incoming.otherUserAvatar,
      conversationKind: explicitKind,
    );
  }

  String _groupConversationName(
    mx.Room? room,
    ChatConversation incoming,
    ChatConversation cached,
  ) {
    if (room != null) return _groupDisplayName(room, cached);
    for (final candidate in [incoming.otherUserName, cached.otherUserName]) {
      final name = _cleanHumanName(candidate);
      if (name.isNotEmpty && name != 'Group') return name;
    }
    return 'Group';
  }

  String? _groupConversationAvatar(
    mx.Room? room,
    ChatConversation incoming,
    ChatConversation cached,
  ) {
    final roomAvatar = room == null ? '' : _groupRoomAvatarUrl(room) ?? '';
    if (roomAvatar.isNotEmpty) return roomAvatar;
    // Only trust a stored avatar if it actually came from a group room event.
    // Do NOT fall back to cached.otherUserAvatar — it may be a member's avatar
    // that leaked in through contact enrichment.
    return null;
  }

  String? _preferCachedDisplayValue(String? cached, String? incoming) {
    final cachedName = _cleanHumanName(cached);
    if (cachedName.isNotEmpty) return cachedName;
    final incomingName = _cleanHumanName(incoming);
    return incomingName.isEmpty ? cached : incomingName;
  }

  int _mergedUnreadCount(ChatConversation cached, ChatConversation incoming) {
    if (_activeReadConversationIds.contains(cached.id) ||
        _activeReadConversationIds.contains(incoming.id) ||
        cached.unreadCount == 0 ||
        _readConversationIds.contains(cached.id)) {
      return 0;
    }
    final readAt = _lastReadAtByConversation[cached.id];
    if (readAt != null && !incoming.lastMessageTime.isAfter(readAt)) {
      return 0;
    }
    return incoming.unreadCount;
  }

  void _cacheRoomIdentity(mx.Room room) {
    if (_isGroupRoom(room, _conversationsMap[room.id])) return;
    final ownerUserId = _currentUserId;
    final peerId = _roomPeerMatrixId(room, MatrixClientService.instance.userId);
    if (ownerUserId == null ||
        ownerUserId.isEmpty ||
        peerId == null ||
        peerId.isEmpty) {
      return;
    }
    final cleanRoomName = _cleanHumanName(room.getLocalizedDisplayname());
    unawaited(
      ContactIdentityCache.instance.upsert(
        ownerUserId: ownerUserId,
        matrixUserId: peerId,
        profileName: cleanRoomName.isEmpty ? null : cleanRoomName,
        avatarUrl: room.avatar?.toString(),
      ),
    );
  }

  String? _roomPeerMatrixId(mx.Room room, String? currentUser) {
    final directUserId = room.directChatMatrixID?.trim();
    if (_isValidMatrixUserId(directUserId) &&
        !_isOwnMatrixId(directUserId!, currentUser)) {
      return directUserId;
    }

    final lastSender = room.lastEvent?.senderId.trim();
    if (_isValidMatrixUserId(lastSender) &&
        !_isOwnMatrixId(lastSender!, currentUser)) {
      return lastSender;
    }

    final cached = _messagesCache[room.id];
    if (cached != null) {
      for (final message in cached.reversed) {
        final sender = message.senderId.trim();
        if (_isValidMatrixUserId(sender) &&
            !_isOwnMatrixId(sender, currentUser)) {
          return sender;
        }
        final receiver = message.receiverId.trim();
        if (_isValidMatrixUserId(receiver) &&
            !_isOwnMatrixId(receiver, currentUser)) {
          return receiver;
        }
      }
    }

    for (final user in room.getParticipants([
      mx.Membership.join,
      mx.Membership.invite,
    ])) {
      final userId = user.id.trim();
      if (_isValidMatrixUserId(userId) &&
          !_isOwnMatrixId(userId, currentUser)) {
        return userId;
      }
    }

    return null;
  }

  bool _isValidMatrixUserId(String? value) {
    final trimmed = value?.trim() ?? '';
    if (!trimmed.startsWith('@')) return false;
    if (!trimmed.contains(':')) return false;
    if (trimmed.startsWith('@!')) return false;
    return trimmed.split(':').length == 2;
  }

  bool _isOwnMatrixId(String value, String? currentUser) =>
      currentUser != null &&
      currentUser.isNotEmpty &&
      _matrixLocalpart(value) == _matrixLocalpart(currentUser);

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  void _cacheMessage(
    ChatMessage message, {
    bool countUnread = true,
    bool publish = true,
  }) {
    if (!_isDisplayableMessage(message)) return;
    if (_isHiddenForMe(message)) return;
    _prefetchPersistentAttachment(message);
    final convId = message.conversationId;
    final currentUser =
        MatrixClientService.instance.client.userID ?? _currentUserId ?? '';
    final incomingSenderPhone =
        !_isOwnMessage(message, currentUser)
            ? _normalizePhone(message.senderPhone ?? '')
            : '';
    final incomingSenderName =
        !_isOwnMessage(message, currentUser)
            ? _cleanHumanName(message.senderName)
            : '';
    if (_currentUserId != null &&
        (incomingSenderPhone.isNotEmpty || incomingSenderName.isNotEmpty)) {
      unawaited(
        ContactIdentityCache.instance.upsert(
          ownerUserId: _currentUserId!,
          matrixUserId: message.senderId,
          phone: incomingSenderPhone.isNotEmpty ? incomingSenderPhone : null,
          profileName:
              incomingSenderName.isNotEmpty ? incomingSenderName : null,
        ),
      );
    }
    final isNewMessage = _upsertCachedMessage(message);
    final shouldCountUnread =
        isNewMessage &&
        countUnread &&
        !_activeReadConversationIds.contains(convId) &&
        !_isOwnMessage(message, currentUser) &&
        _isAfterReadMarker(message, convId);
    if (shouldCountUnread) {
      _readConversationIds.remove(convId);
    }
    final existing = _conversationsMap[convId];
    final room = _roomById(convId);
    final isMatrixDirectRoom =
        room != null &&
        (room.isDirectChat ||
            MatrixChatService.instance.looksLikeUnmarkedDirectRoom(room));
    final explicitlyStoredGroup =
        existing?.lastMessageType == 'group' &&
        existing?.id.startsWith('!') == true &&
        existing?.otherUserId == existing?.id;
    final bool isGroupConversation;
    if (existing != null && existing.hasExplicitKind) {
      isGroupConversation = existing.isGroupKind || existing.isChannelKind;
    } else {
      isGroupConversation =
          explicitlyStoredGroup ||
          (!isMatrixDirectRoom &&
              (message.receiverId.trim().startsWith('!') ||
                  (room != null && _isGroupRoom(room, existing))));
    }
    if (isGroupConversation) {
      final groupName =
          room == null
              ? _cleanHumanName(existing?.otherUserName)
              : _groupDisplayName(room, existing);
      final participants =
          <String>{
            if (MatrixClientService.instance.client.userID != null)
              MatrixClientService.instance.client.userID!,
            if (existing != null) ...existing.participants,
            if (room != null) ...room.getParticipants().map((user) => user.id),
            message.senderId,
          }.where((id) => id.trim().isNotEmpty).toList();
      final isNewer =
          existing == null ||
          message.timestamp.isAfter(existing.lastMessageTime);
      _conversationsMap[convId] = ChatConversation(
        id: convId,
        participants: participants,
        otherUserId: convId,
        lastMessage: isNewer ? message.content : existing.lastMessage,
        lastMessageSenderId:
            isNewer ? message.senderId : existing.lastMessageSenderId,
        lastMessageTime: isNewer ? message.timestamp : existing.lastMessageTime,
        unreadCount:
            shouldCountUnread
                ? (existing?.unreadCount ?? 0) + 1
                : existing?.unreadCount ?? 0,
        lastMessageType: 'group',
        conversationKind: () {
          final authoritative =
              room == null ? ConversationKind.unknown : _kindForGroupRoom(room);
          if (authoritative == ConversationKind.channel) {
            return ConversationKind.channel;
          }
          return existing?.hasExplicitKind == true
              ? existing!.conversationKind
              : ConversationKind.group;
        }(),
        isArchived: existing?.isArchived ?? false,
        isMuted: existing?.isMuted ?? false,
        isPinned: existing?.isPinned ?? false,
        mutedUntil: existing?.mutedUntil,
        lastSeen: existing?.lastSeen ?? const {},
        createdAt: existing?.createdAt,
        deletedAt: existing?.deletedAt,
        deletedBy: existing?.deletedBy ?? const [],
        otherUserName: groupName.isNotEmpty ? groupName : 'Group',
        otherUserAvatar: room == null ? null : _groupRoomAvatarUrl(room),
      );
      unawaited(_persistCachedMessage(message, _conversationsMap[convId]!));
      if (publish) {
        _emitRoomMessages(convId);
        _emitConversations();
      }
      return;
    }
    _conversationsMap[convId] =
        existing == null
            ? ChatConversation.fromMessage(message, currentUser).copyWith(
              unreadCount: shouldCountUnread ? 1 : 0,
              otherUserName:
                  incomingSenderPhone.isNotEmpty ? incomingSenderPhone : null,
            )
            : shouldCountUnread
            ? existing
                .updateWithMessage(message, currentUser)
                .copyWith(
                  otherUserName:
                      incomingSenderPhone.isNotEmpty
                          ? incomingSenderPhone
                          : existing.otherUserName,
                )
            : existing.copyWith(
              lastMessage:
                  message.timestamp.isAfter(existing.lastMessageTime)
                      ? message.content
                      : existing.lastMessage,
              lastMessageSenderId:
                  message.timestamp.isAfter(existing.lastMessageTime)
                      ? message.senderId
                      : existing.lastMessageSenderId,
              lastMessageTime:
                  message.timestamp.isAfter(existing.lastMessageTime)
                      ? message.timestamp
                      : existing.lastMessageTime,
              otherUserName:
                  incomingSenderPhone.isNotEmpty
                      ? incomingSenderPhone
                      : existing.otherUserName,
            );
    unawaited(_persistCachedMessage(message, _conversationsMap[convId]!));
    if (publish) {
      _emitRoomMessages(convId);
      _emitConversations();
    }
  }

  void _prefetchPersistentAttachment(ChatMessage message) {
    unawaited(_prefetchPersistentAttachmentAsync(message));
  }

  Future<void> _prefetchPersistentAttachmentAsync(ChatMessage message) async {
    final type = message.attachmentType?.trim();
    final source = message.attachmentUrl?.trim() ?? '';
    const persistentTypes = {'image', 'video', 'file', 'voice'};
    if (source.isEmpty || !persistentTypes.contains(type)) return;
    final roomId = message.conversationId;
    final prefetchKey = '$roomId|${message.id}';
    if (!_attachmentPrefetchInFlight.add(prefetchKey)) return;
    try {
      await _prefetchPersistentAttachmentOnce(
        message: message,
        roomId: roomId,
        source: source,
        type: type!,
      );
    } finally {
      _attachmentPrefetchInFlight.remove(prefetchKey);
    }
  }

  Future<void> _prefetchPersistentAttachmentOnce({
    required ChatMessage message,
    required String roomId,
    required String source,
    required String type,
  }) async {
    _attachmentCacheExpectedByRoom
        .putIfAbsent(roomId, () => <String>{})
        .add(message.id);

    final existing = await AttachmentLocalStore.instance.existingComplete(
      source: source,
      fileName: message.content,
    );
    if (existing != null) {
      _attachmentCachePendingByRoom[roomId]?.remove(message.id);
      _attachmentCacheFailedByRoom[roomId]?.remove(message.id);
      _attachmentCacheCompleteByRoom
          .putIfAbsent(roomId, () => <String>{})
          .add(message.id);
      apkLog(
        'MediaCache.item',
        'state="already_cached" room_kind="${_mediaCacheRoomKind(roomId)}" '
            'room_id="$roomId" event_id="${message.id}" media_type="$type" '
            'bytes=${await existing.length()} local_path="${existing.path}"',
      );
      _scheduleAttachmentCacheSummary(roomId);
      return;
    }

    _attachmentCachePendingByRoom
        .putIfAbsent(roomId, () => <String>{})
        .add(message.id);
    _attachmentCacheFailedByRoom[roomId]?.remove(message.id);
    apkLog(
      'MediaCache.item',
      'state="checking" room_kind="${_mediaCacheRoomKind(roomId)}" '
          'room_id="$roomId" event_id="${message.id}" '
          'media_type="$type"',
    );
    await _prefetchAttachment(message, source, type == 'file');
  }

  Future<bool> _cacheAllAttachmentsForRoom(
    String roomId,
    List<ChatMessage> messages,
  ) async {
    const persistentTypes = {'image', 'video', 'file', 'voice'};
    final media = messages
        .where(
          (message) =>
              persistentTypes.contains(message.attachmentType?.trim()) &&
              (message.attachmentUrl?.trim().isNotEmpty ?? false),
        )
        .toList(growable: false);
    var completed = 0;
    for (var offset = 0; offset < media.length; offset += 3) {
      final end = math.min(offset + 3, media.length);
      final results = await Future.wait(
        media.sublist(offset, end).map((message) {
          _attachmentCacheExpectedByRoom
              .putIfAbsent(roomId, () => <String>{})
              .add(message.id);
          _attachmentCachePendingByRoom
              .putIfAbsent(roomId, () => <String>{})
              .add(message.id);
          return _downloadAttachmentFullyWithRetry(message);
        }),
      );
      completed += results.where((result) => result).length;
    }
    await ChatLocalDb.instance.markRoomMediaCoverage(
      roomId: roomId,
      expected: media.length,
      complete: completed,
    );
    _logAttachmentCacheSummary(roomId);
    return completed == media.length;
  }

  Future<bool> _downloadAttachmentFullyWithRetry(ChatMessage message) async {
    final source = message.attachmentUrl!.trim();
    Object? lastError;
    for (var attempt = 1; attempt <= 8 && _isConnected; attempt += 1) {
      try {
        final copy = await AttachmentLocalStore.instance.ensureComplete(
          source: source,
          fileName: message.content,
        );
        final bytes = await copy.file.length();
        final verified =
            copy.isComplete &&
            bytes > 0 &&
            (copy.totalBytes == null || bytes >= copy.totalBytes!);
        if (!verified) {
          throw StateError(
            'Downloaded attachment did not pass size/completion verification',
          );
        }
        final roomId = message.conversationId;
        _attachmentCachePendingByRoom[roomId]?.remove(message.id);
        _attachmentCacheFailedByRoom[roomId]?.remove(message.id);
        _attachmentCacheCompleteByRoom
            .putIfAbsent(roomId, () => <String>{})
            .add(message.id);
        apkLog(
          'MediaCache.item',
          'state="complete_verified" room_id="$roomId" '
              'event_id="${message.id}" attempt=$attempt bytes=$bytes '
              'total_bytes=${copy.totalBytes ?? bytes} local_path="${copy.file.path}"',
        );
        return true;
      } catch (error) {
        lastError = error;
        apkLog(
          'MediaCache.item',
          'state="retry" room_id="${message.conversationId}" '
              'event_id="${message.id}" attempt=$attempt error="$error"',
        );
        if (attempt < 8 && _isConnected) {
          final seconds = math.min(30, 1 << (attempt - 1));
          await Future<void>.delayed(Duration(seconds: seconds));
        }
      }
    }
    final roomId = message.conversationId;
    _attachmentCachePendingByRoom[roomId]?.remove(message.id);
    _attachmentCacheCompleteByRoom[roomId]?.remove(message.id);
    _attachmentCacheFailedByRoom
        .putIfAbsent(roomId, () => <String>{})
        .add(message.id);
    apkLog(
      'MediaCache.item',
      'state="incomplete_after_retries" room_id="$roomId" '
          'event_id="${message.id}" error="$lastError"',
    );
    return false;
  }

  /// Logs cache coverage for every channel shown by channel discovery,
  /// including channels with no media. Categories intentionally mirror the
  /// Channels tab: joined owner rooms, joined subscriptions, then unjoined
  /// public suggestions.
  Future<void> auditDiscoveredChannelCacheCoverage(
    List<MatrixPublicGroup> discovered,
  ) async {
    final discoveredChannels = {
      for (final channel in discovered.where((room) => room.isChannel))
        channel.roomId: channel,
    };
    final channelIds = <String>{
      ..._conversationsMap.values
          .where((conversation) => conversation.isChannelKind)
          .map((conversation) => conversation.id),
      ...discoveredChannels.keys,
    };

    for (final roomId in channelIds) {
      final conversation = _conversationsMap[roomId];
      final room = _roomById(roomId);
      final joinedChannel = conversation?.isChannelKind == true;
      final owned =
          joinedChannel &&
          ((room != null &&
                  room.membership == mx.Membership.join &&
                  MatrixChatService.instance.isGroupOwner(room)) ||
              _createdGroupRoomIds.contains(roomId));
      final category =
          owned ? 'owned' : (joinedChannel ? 'subscribed' : 'suggested');
      final messages = await ChatLocalDb.instance.loadMessages(roomId);
      final visibleMessages = messages
          .where(
            (message) =>
                !_isHiddenForMe(message) && !_isBeforeGroupJoinCutoff(message),
          )
          .toList(growable: false);
      const persistentTypes = {'image', 'video', 'file', 'voice'};
      final media = visibleMessages
          .where(
            (message) =>
                persistentTypes.contains(message.attachmentType?.trim()) &&
                (message.attachmentUrl?.trim().isNotEmpty ?? false),
          )
          .toList(growable: false);
      final historyCached =
          category == 'suggested'
              ? await ChatLocalDb.instance.isSuggestedPreviewComplete(roomId)
              : await ChatLocalDb.instance.isRoomHistoryComplete(roomId);

      _channelCacheCategoryByRoom[roomId] = category;
      _channelCachedMessageCountByRoom[roomId] = visibleMessages.length;
      _channelHistoryCachedByRoom[roomId] = historyCached;

      for (final message in media) {
        _prefetchPersistentAttachment(message);
      }
      _logAttachmentCacheSummary(roomId);
    }
  }

  /// Group equivalent of [auditDiscoveredChannelCacheCoverage]. Categories
  /// mirror the Groups tab: rooms owned by the current user, other joined
  /// rooms, and unjoined public suggestions.
  Future<void> auditDiscoveredGroupCacheCoverage(
    List<MatrixPublicGroup> discovered,
  ) async {
    final discoveredGroups = {
      for (final group in discovered.where((room) => !room.isChannel))
        group.roomId: group,
    };
    final groupIds = <String>{
      ..._conversationsMap.values
          .where((conversation) => conversation.isGroupKind)
          .map((conversation) => conversation.id),
      ...discoveredGroups.keys,
    };

    for (final roomId in groupIds) {
      final conversation = _conversationsMap[roomId];
      final room = _roomById(roomId);
      final joinedGroup = conversation?.isGroupKind == true;
      final owned =
          joinedGroup &&
          ((room != null &&
                  room.membership == mx.Membership.join &&
                  MatrixChatService.instance.isGroupOwner(room)) ||
              _createdGroupRoomIds.contains(roomId));
      final category = owned ? 'owned' : (joinedGroup ? 'joined' : 'suggested');
      final messages = await ChatLocalDb.instance.loadMessages(roomId);
      final visibleMessages = messages
          .where(
            (message) =>
                !_isHiddenForMe(message) && !_isBeforeGroupJoinCutoff(message),
          )
          .toList(growable: false);
      const persistentTypes = {'image', 'video', 'file', 'voice'};
      final media = visibleMessages
          .where(
            (message) =>
                persistentTypes.contains(message.attachmentType?.trim()) &&
                (message.attachmentUrl?.trim().isNotEmpty ?? false),
          )
          .toList(growable: false);
      final historyCached =
          category == 'suggested'
              ? await ChatLocalDb.instance.isSuggestedPreviewComplete(roomId)
              : await ChatLocalDb.instance.isRoomHistoryComplete(roomId);

      _groupCacheCategoryByRoom[roomId] = category;
      _groupCachedMessageCountByRoom[roomId] = visibleMessages.length;
      _groupHistoryCachedByRoom[roomId] = historyCached;

      for (final message in media) {
        _prefetchPersistentAttachment(message);
      }
      _logAttachmentCacheSummary(roomId);
    }
  }

  /// Logs SQLite message and persistent attachment coverage for every direct
  /// chat, including conversations that contain no media.
  Future<void> auditDirectChatCacheCoverage() async {
    final directIds = <String>{
      ..._conversationsMap.values
          .where((conversation) => conversation.isDirectKind)
          .map((conversation) => conversation.id),
      ...MatrixClientService.instance.client.rooms
          .where((room) => room.membership == mx.Membership.join)
          .where((room) => room.isDirectChat)
          .map((room) => room.id),
    };

    for (final roomId in directIds) {
      final messages = await ChatLocalDb.instance.loadMessages(roomId);
      final visibleMessages = messages
          .where((message) => !_isHiddenForMe(message))
          .toList(growable: false);
      const persistentTypes = {'image', 'video', 'file', 'voice'};
      final media = visibleMessages
          .where(
            (message) =>
                persistentTypes.contains(message.attachmentType?.trim()) &&
                (message.attachmentUrl?.trim().isNotEmpty ?? false),
          )
          .toList(growable: false);

      _directCacheCategoryByRoom[roomId] = 'direct';
      _directCachedMessageCountByRoom[roomId] = visibleMessages.length;
      _directHistoryCachedByRoom[roomId] = await ChatLocalDb.instance
          .isRoomHistoryComplete(roomId);

      for (final message in media) {
        _attachmentCacheExpectedByRoom
            .putIfAbsent(roomId, () => <String>{})
            .add(message.id);
      }
      _logAttachmentCacheSummary(roomId);
    }
  }

  Future<void> _prefetchAttachment(
    ChatMessage message,
    String source,
    bool allowPartial,
  ) async {
    try {
      final copy = await AttachmentLocalStore.instance.ensureInitial(
        source: source,
        fileName: message.content,
        allowPartial: allowPartial,
      );
      final bytes = await copy.file.length();
      final roomId = message.conversationId;
      _attachmentCachePendingByRoom[roomId]?.remove(message.id);
      if (copy.isComplete) {
        _attachmentCacheCompleteByRoom
            .putIfAbsent(roomId, () => <String>{})
            .add(message.id);
        _attachmentCacheFailedByRoom[roomId]?.remove(message.id);
      } else {
        _attachmentCacheCompleteByRoom[roomId]?.remove(message.id);
        _attachmentCacheFailedByRoom
            .putIfAbsent(roomId, () => <String>{})
            .add(message.id);
      }
      apkLog(
        'MediaCache.item',
        'state="${copy.isComplete ? 'complete' : 'partial'}" '
            'room_kind="${_mediaCacheRoomKind(roomId)}" room_id="$roomId" '
            'event_id="${message.id}" media_type="${message.attachmentType}" '
            'bytes=$bytes total_bytes=${copy.totalBytes ?? -1} '
            'local_path="${copy.file.path}"',
      );
      _scheduleAttachmentCacheSummary(roomId);
    } catch (error) {
      final roomId = message.conversationId;
      _attachmentCachePendingByRoom[roomId]?.remove(message.id);
      _attachmentCacheCompleteByRoom[roomId]?.remove(message.id);
      _attachmentCacheFailedByRoom
          .putIfAbsent(roomId, () => <String>{})
          .add(message.id);
      apkLog(
        'MediaCache.item',
        'state="failed" room_kind="${_mediaCacheRoomKind(roomId)}" '
            'room_id="$roomId" event_id="${message.id}" '
            'media_type="${message.attachmentType}" error="$error"',
      );
      _scheduleAttachmentCacheSummary(roomId);
    }
  }

  String _mediaCacheRoomKind(String roomId) {
    if (_channelCacheCategoryByRoom.containsKey(roomId)) return 'channel';
    if (_groupCacheCategoryByRoom.containsKey(roomId)) return 'group';
    if (_directCacheCategoryByRoom.containsKey(roomId)) return 'direct';
    final room = _roomById(roomId);
    if (room == null) return 'unknown';
    if (room.isDirectChat) return 'direct';
    return _kindForGroupRoom(room);
  }

  void _scheduleAttachmentCacheSummary(String roomId) {
    _attachmentCacheSummaryTimers[roomId]?.cancel();
    _attachmentCacheSummaryTimers[roomId] = Timer(
      const Duration(milliseconds: 500),
      () {
        _attachmentCacheSummaryTimers.remove(roomId);
        _logAttachmentCacheSummary(roomId);
      },
    );
  }

  void _logAttachmentCacheSummary(String roomId) {
    final expected = _attachmentCacheExpectedByRoom[roomId] ?? const <String>{};
    final complete = _attachmentCacheCompleteByRoom[roomId] ?? const <String>{};
    final pending = _attachmentCachePendingByRoom[roomId] ?? const <String>{};
    final failed = _attachmentCacheFailedByRoom[roomId] ?? const <String>{};
    final category = _channelCacheCategoryByRoom[roomId];
    final groupCategory = _groupCacheCategoryByRoom[roomId];
    final directCategory = _directCacheCategoryByRoom[roomId];
    final historyCached =
        category != null
            ? (_channelHistoryCachedByRoom[roomId] ?? false)
            : groupCategory != null
            ? (_groupHistoryCachedByRoom[roomId] ?? false)
            : directCategory != null
            ? (_directHistoryCachedByRoom[roomId] ?? false)
            : true;
    final fullyCached =
        complete.length == expected.length &&
        pending.isEmpty &&
        failed.isEmpty &&
        historyCached;
    final channelFields =
        category == null
            ? ''
            : ' channel_category="$category" '
                'messages=${_channelCachedMessageCountByRoom[roomId] ?? 0} '
                'history_cached=${_channelHistoryCachedByRoom[roomId] ?? false}';
    final groupFields =
        groupCategory == null
            ? ''
            : ' group_category="$groupCategory" '
                'messages=${_groupCachedMessageCountByRoom[roomId] ?? 0} '
                'history_cached=${_groupHistoryCachedByRoom[roomId] ?? false}';
    final directFields =
        directCategory == null
            ? ''
            : ' direct_category="$directCategory" '
                'messages=${_directCachedMessageCountByRoom[roomId] ?? 0} '
                'history_cached=${_directHistoryCachedByRoom[roomId] ?? false}';
    apkLog(
      'MediaCache.room',
      'state="${fullyCached ? 'fully_cached' : 'incomplete'}" '
          'room_kind="${_mediaCacheRoomKind(roomId)}" room_id="$roomId" '
          '$channelFields$groupFields$directFields media=${expected.length} '
          'expected=${expected.length} complete=${complete.length} '
          'pending=${pending.length} failed=${failed.length}',
    );
  }

  void _applyMatrixEditEvent(mx.Event event) {
    final targetId = ChatMessage.matrixEditTargetId(event);
    if (targetId == null || targetId.isEmpty) return;
    final edit = ChatMessage.fromMatrixEvent(event);
    if (edit == null || edit.content.trim().isEmpty) return;
    final roomId = event.room.id;
    final messages = _messagesCache[roomId];
    if (messages == null) return;
    final index = messages.indexWhere((message) => message.id == targetId);
    if (index == -1) return;
    final original = messages[index];
    if (original.senderId != event.senderId) return;

    final updated = original.copyWith(content: edit.content, isEdited: true);
    messages[index] = updated;
    unawaited(ChatLocalDb.instance.saveMessage(updated));

    final latestVisibleId = _latestKnownMessageId(roomId);
    final existing = _conversationsMap[roomId];
    if (existing != null && latestVisibleId == targetId) {
      _conversationsMap[roomId] = existing.copyWith(lastMessage: edit.content);
    }

    _emitRoomMessages(roomId);
    _emitConversations();
  }

  bool _upsertCachedMessage(ChatMessage message) {
    final convId = message.conversationId;
    final messages = _messagesCache.putIfAbsent(convId, () => []);
    final existingIndex = messages.indexWhere((m) => m.id == message.id);
    if (existingIndex == -1) {
      messages.add(message);
      _removeDuplicateOutgoingEchoes(messages, canonical: message);
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return true;
    }
    messages[existingIndex] = message;
    _removeDuplicateOutgoingEchoes(messages, canonical: message);
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return false;
  }

  void _removeDuplicateOutgoingEchoes(
    List<ChatMessage> messages, {
    required ChatMessage canonical,
  }) {
    if (_isLocalOutgoingEchoId(canonical.id)) return;
    final currentUser =
        MatrixClientService.instance.isInitialized
            ? MatrixClientService.instance.userId ?? _currentUserId ?? ''
            : _currentUserId ?? '';
    if (!_isOwnMessage(canonical, currentUser)) return;
    messages.removeWhere((candidate) {
      if (candidate.id == canonical.id) return false;
      if (!_isOwnMessage(candidate, currentUser)) return false;
      if (!_isLocalOutgoingEchoId(candidate.id)) return false;
      if (candidate.content != canonical.content) return false;
      final sameConversation =
          candidate.conversationId == canonical.conversationId;
      if (!sameConversation) return false;
      final closeInTime =
          candidate.timestamp.difference(canonical.timestamp).inSeconds.abs() <
          60;
      return closeInTime;
    });
  }

  bool _isLocalOutgoingEchoId(String id) {
    return id.startsWith('opt_') || id.startsWith('Wrytte-');
  }

  DateTime _latestKnownMessageTime(String conversationId) {
    final cached = _messagesCache[conversationId];
    if (cached != null && cached.isNotEmpty) {
      final visible = cached.where((message) => !_isHiddenForMe(message));
      var latest = DateTime.fromMillisecondsSinceEpoch(0);
      for (final message in visible) {
        if (message.timestamp.isAfter(latest)) latest = message.timestamp;
      }
      if (latest.millisecondsSinceEpoch > 0) return latest;
    }
    final conversation = _conversationsMap[conversationId];
    return conversation?.lastMessageTime ?? DateTime.now();
  }

  String? _latestKnownMessageId(String conversationId) {
    final cached = _messagesCache[conversationId];
    if (cached == null || cached.isEmpty) return null;
    for (final message in cached.reversed) {
      if (!_isHiddenForMe(message) && _isDisplayableMessage(message)) {
        return message.id;
      }
    }
    return null;
  }

  bool _isAfterReadMarker(ChatMessage message, String conversationId) {
    final readAt = _lastReadAtByConversation[conversationId];
    if (readAt == null) return true;
    return message.timestamp.isAfter(readAt);
  }

  String _groupJoinCutoffsKey(String ownerUserId) =>
      'wrytte.group_join_cutoffs.$ownerUserId';

  String _createdGroupRoomIdsKey(String ownerUserId) =>
      'wrytte.created_group_room_ids.$ownerUserId';

  String _dismissedDeletedGroupRoomIdsKey(String ownerUserId) =>
      'wrytte.dismissed_deleted_group_room_ids.$ownerUserId';

  /// Reads deleted-group shells dismissed by [ownerUserId] without requiring
  /// Matrix startup to finish first.
  ///
  /// The conversations screen uses this before its first SQLite paint so a
  /// tombstoned room cannot briefly reappear while [connect] is still loading
  /// the same account-scoped preference into memory.
  Future<Set<String>> dismissedDeletedGroupRoomIdsForOwner(
    String ownerUserId,
  ) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return const <String>{};
    final prefs = await SharedPreferences.getInstance();
    final ids =
        prefs.getStringList(_dismissedDeletedGroupRoomIdsKey(owner)) ??
        const <String>[];
    return ids.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
  }

  Future<void> _loadGroupJoinCutoffs() async {
    final owner = _currentUserId;
    if (owner == null || owner.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        prefs.getStringList(_groupJoinCutoffsKey(owner)) ?? const [];
    _groupJoinCutoffsByRoom.clear();
    for (final item in encoded) {
      final separator = item.indexOf('|');
      if (separator <= 0) continue;
      final roomId = item.substring(0, separator).trim();
      final millis = int.tryParse(item.substring(separator + 1).trim());
      if (roomId.isEmpty || millis == null) continue;
      _groupJoinCutoffsByRoom[roomId] = DateTime.fromMillisecondsSinceEpoch(
        millis,
      );
    }
  }

  Future<void> _saveGroupJoinCutoffs() async {
    final owner = _currentUserId;
    if (owner == null || owner.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final encoded = _groupJoinCutoffsByRoom.entries
        .map((entry) => '${entry.key}|${entry.value.millisecondsSinceEpoch}')
        .toList(growable: false);
    await prefs.setStringList(_groupJoinCutoffsKey(owner), encoded);
  }

  Future<void> _loadCreatedGroupRoomIds() async {
    final owner = _currentUserId;
    if (owner == null || owner.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_createdGroupRoomIdsKey(owner)) ?? const [];
    _createdGroupRoomIds
      ..clear()
      ..addAll(ids.map((id) => id.trim()).where((id) => id.isNotEmpty));
    MatrixChatService.instance.registerCreatedGroupRooms(
      _createdGroupRoomIds,
    ); // add
  }

  /// Restores the account-scoped ownership registry without requiring Matrix
  /// connectivity, so channel/group tabs classify their first local paint.
  Future<Set<String>> restoreCreatedGroupRoomIdsForOwner(
    String ownerUserId,
  ) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return const <String>{};
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_createdGroupRoomIdsKey(owner)) ?? const [];
    _createdGroupRoomIds
      ..clear()
      ..addAll(ids.map((id) => id.trim()).where((id) => id.isNotEmpty));
    MatrixChatService.instance.registerCreatedGroupRooms(_createdGroupRoomIds);
    apkLog(
      'ChatService.local',
      'restored ownership owner="$owner" rooms=${_createdGroupRoomIds.length}',
    );
    return Set<String>.unmodifiable(_createdGroupRoomIds);
  }

  Future<void> _saveCreatedGroupRoomIds() async {
    final owner = _currentUserId;
    if (owner == null || owner.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _createdGroupRoomIdsKey(owner),
      _createdGroupRoomIds.toList(growable: false),
    );
  }

  Future<void> _loadDismissedDeletedGroupRoomIds() async {
    final owner = _currentUserId;
    if (owner == null || owner.isEmpty) return;
    final ids = await dismissedDeletedGroupRoomIdsForOwner(owner);
    _dismissedDeletedGroupRoomIds
      ..clear()
      ..addAll(ids);
  }

  Future<void> _saveDismissedDeletedGroupRoomIds() async {
    final owner = _currentUserId;
    if (owner == null || owner.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _dismissedDeletedGroupRoomIdsKey(owner),
      _dismissedDeletedGroupRoomIds.toList(growable: false),
    );
  }

  Future<void> markGroupCreated(String roomId) async {
    final id = roomId.trim();
    if (id.isEmpty) return;
    if (_createdGroupRoomIds.add(id)) {
      await _saveCreatedGroupRoomIds();
      MatrixChatService.instance.registerCreatedGroupRoom(id); // add
    }
  }

  /// Marks a group as joined but not created by this account.
  ///
  /// Older builds incorrectly registered joined suggestions as created rooms;
  /// removing the ID here also repairs that persisted classification.
  Future<void> markGroupJoined(String roomId) async {
    final id = roomId.trim();
    if (id.isEmpty) return;
    if (_createdGroupRoomIds.remove(id)) {
      await _saveCreatedGroupRoomIds();
    }
    MatrixChatService.instance.unregisterCreatedGroupRoom(id);
  }

  bool isCreatedGroupRoom(String roomId) =>
      _createdGroupRoomIds.contains(roomId.trim());

  bool isConversationDeleted(String conversationId) {
    final conv = _conversationsMap[conversationId.trim()];
    if (conv == null) return false;
    return conv.deletedAt != null ||
        conv.lastMessageType == groupDeletedMessageType ||
        isGroupDeletedPreview(conv.lastMessage);
  }

  Set<String> get createdGroupRoomIds =>
      Set<String>.unmodifiable(_createdGroupRoomIds);
  // A conversation is a group if we created it, it's explicitly typed 'group',
  // or its live Matrix room classifies as a group. Contact/member enrichment
  // must never touch these — group name/avatar come only from room state.
  bool _isGroupConversationRow(ChatConversation conversation) {
    // A room tombstone is stronger than stale cached kind metadata. Older
    // builds could persist a deleted group as `direct` after matching one of
    // its members; that value must never win here.
    if (_isDeletedGroupConversationRow(conversation)) return true;
    if (conversation.hasExplicitKind) {
      return conversation.isGroupKind || conversation.isChannelKind;
    }
    if (_createdGroupRoomIds.contains(conversation.id)) return true;
    if (conversation.lastMessageType == groupDeletedMessageType) return true;
    if (conversation.deletedAt != null && conversation.id.startsWith('!')) {
      return true;
    }
    if (conversation.lastMessageType == 'group') return true;
    final room = _roomById(conversation.id);
    if (room != null && _isGroupRoom(room, conversation)) return true;
    return false;
  }

  bool _isDeletedGroupConversationRow(ChatConversation conversation) {
    if (!conversation.id.startsWith('!')) return false;
    return conversation.lastMessageType == groupDeletedMessageType ||
        isGroupDeletedPreview(conversation.lastMessage) ||
        conversation.deletedAt != null;
  }

  /// Like [_isGroupConversationRow], but works even when the conversation
  /// isn't currently loaded in [_conversationsMap] — e.g. a joined (not
  /// created) group that was left, deleted, or simply hasn't been refreshed
  /// back into memory since app start. Without this, contact/profile
  /// enrichment can stamp a 1:1 contact's name/avatar onto a group's DB row,
  /// because every earlier check silently defaults to "not a group" when it
  /// has no in-memory conversation to inspect.
  Future<bool> _isGroupConversationId(
    String conversationId,
    ChatConversation? loaded,
  ) async {
    if (loaded != null && _isDeletedGroupConversationRow(loaded)) return true;
    if (loaded != null && loaded.hasExplicitKind) {
      return loaded.isGroupKind || loaded.isChannelKind;
    }
    if (_createdGroupRoomIds.contains(conversationId)) return true;
    if (loaded != null && _isGroupConversationRow(loaded)) return true;

    final room = _roomById(conversationId);
    if (room != null && MatrixChatService.instance.isMatrixGroupRoom(room)) {
      return true;
    }

    // Room object is gone too (left/deleted) — fall back to what's actually
    // persisted, since that's the only remaining source of truth.
    if (loaded == null) {
      final persisted = await ChatLocalDb.instance.loadConversation(
        conversationId,
      );
      if (persisted != null && _isDeletedGroupConversationRow(persisted)) {
        return true;
      }
      if (persisted != null && persisted.hasExplicitKind) {
        return persisted.isGroupKind || persisted.isChannelKind;
      }
      if (persisted != null && _isGroupConversationRow(persisted)) {
        return true;
      }
    }

    return false;
  }

  bool _isGroupDeletedMatrixEvent(mx.Event event) {
    if (event.type != mx.EventTypes.Message) return false;
    return event.content[groupDeletedEventKey] == true ||
        isGroupDeletedPreview(event.content['body']?.toString() ?? event.body);
  }

  DateTime? _groupDeletedAtFromEvent(mx.Event event) {
    return _groupDeletedAtFromContent(event.content);
  }

  DateTime? _groupDeletedAtFromContent(Map<String, dynamic> content) {
    final raw = content[groupDeletedAtKey]?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  String _groupDeletedByFromEvent(mx.Event event) =>
      _groupDeletedByFromContent(event.content, event.senderId);

  String _groupDeletedByFromContent(
    Map<String, dynamic> content,
    String fallbackSender,
  ) => content[groupDeletedByKey]?.toString().trim() ?? fallbackSender;

  String _groupDeletedNameFromEvent(mx.Event event) {
    final name = event.content[groupDeletedNameKey]?.toString().trim() ?? '';
    return name.isNotEmpty ? name : event.room.getLocalizedDisplayname();
  }

  Future<void> removeConversationLocally(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    await _purgeLocalConversationContent(id);
    _conversationsMap.remove(id);
    _messagesCache.remove(id);
    _groupJoinCutoffsByRoom.remove(id);
    _readConversationIds.remove(id);
    _activeReadConversationIds.remove(id);
    _lastReadAtByConversation.remove(id);
    if (_createdGroupRoomIds.remove(id)) {
      await _saveCreatedGroupRoomIds();
      MatrixChatService.instance.unregisterCreatedGroupRoom(id);
    }
    await ChatLocalDb.instance.deleteConversation(id);
    await _saveGroupJoinCutoffs();
    _emitConversations();
  }

  /// Permanently hides a deleted-group shell for the current account.
  ///
  /// Matrix keeps the room tombstone in synced state, so deleting only the
  /// SQLite row is insufficient: the next room refresh would recreate it.
  Future<void> dismissDeletedGroupLocally(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    _dismissedDeletedGroupRoomIds.add(id);
    await _saveDismissedDeletedGroupRoomIds();
    await removeConversationLocally(id);
  }

  Future<void> _purgeLocalConversationContent(String conversationId) async {
    final persisted = await ChatLocalDb.instance.loadMessages(conversationId);
    final cached = _messagesCache[conversationId] ?? const <ChatMessage>[];
    final messages =
        <String, ChatMessage>{
          for (final message in persisted) message.id: message,
          for (final message in cached) message.id: message,
        }.values;
    for (final message in messages) {
      final source = message.attachmentUrl?.trim() ?? '';
      if (source.isEmpty) continue;
      await AttachmentLocalStore.instance.deleteLocalCopy(
        source: source,
        fileName: message.content,
      );
    }
    _messagesCache[conversationId] = <ChatMessage>[];
    await ChatLocalDb.instance.deleteConversationMessages(conversationId);
  }

  Future<void> markGroupJoinedFrom(String roomId, DateTime joinedFrom) async {
    final id = roomId.trim();
    if (id.isEmpty) return;
    final existing = _groupJoinCutoffsByRoom[id];
    if (existing == null || joinedFrom.isAfter(existing)) {
      _groupJoinCutoffsByRoom[id] = joinedFrom;
      await _saveGroupJoinCutoffs();
    }
    final cached = _messagesCache[id];
    if (cached != null) {
      final kept = <ChatMessage>[];
      for (final message in cached) {
        if (message.timestamp.isBefore(joinedFrom)) {
          unawaited(ChatLocalDb.instance.deleteMessageForMe(message.id));
        } else {
          kept.add(message);
        }
      }
      _messagesCache[id] = kept;
      _emitRoomMessages(id);
    }
  }

  /// Suggested public groups deliberately expose their available history, so
  /// an old join cutoff must not hide or delete previewed/pre-join messages.
  Future<void> clearGroupJoinCutoff(String roomId) async {
    final id = roomId.trim();
    if (id.isEmpty) return;
    if (_groupJoinCutoffsByRoom.remove(id) != null) {
      await _saveGroupJoinCutoffs();
    }
  }

  /// Restores all server-available history after joining a suggested group.
  Future<void> backfillGroupHistory(String roomId) async {
    final id = roomId.trim();
    if (id.isEmpty) return;
    await clearGroupJoinCutoff(id);
    final room = _roomById(id);
    if (room == null) {
      apkLog(
        'Matrix.history',
        'backfill skipped room_id="$id" reason="room not available after join"',
      );
      return;
    }
    await _restoreRoomHistoryFromServer(room);
  }

  DateTime? _groupJoinCutoffForRoom(mx.Room room) {
    if (!MatrixChatService.instance.isMatrixGroupRoom(room)) return null;
    return _groupJoinCutoffsByRoom[room.id];
  }

  bool _isBeforeGroupJoinCutoff(ChatMessage message) {
    final cutoff = _groupJoinCutoffsByRoom[message.conversationId];
    return cutoff != null && message.timestamp.isBefore(cutoff);
  }

  void _emitRoomMessages(String conversationId) {
    final controller = _roomMessagesControllers[conversationId];
    if (controller == null || controller.isClosed) return;
    controller.add(List.unmodifiable(getConversationMessages(conversationId)));
  }

  Future<void> _persistCachedMessage(
    ChatMessage message,
    ChatConversation conversation,
  ) async {
    await ChatLocalDb.instance.deleteDuplicateOutgoingEchoesFor(message);
    await ChatLocalDb.instance.saveMessage(message);
    await ChatLocalDb.instance.saveConversations([conversation]);
  }

  void _replaceCachedMessage(ChatMessage message) {
    final messages = _messagesCache[message.conversationId];
    if (messages == null) return;
    final index = messages.indexWhere((m) => m.id == message.id);
    if (index == -1) return;
    messages[index] = message;
    _emitRoomMessages(message.conversationId);
  }

  bool _applyLiveRedactionEvent(mx.Event event) {
    if (event.type != mx.EventTypes.Redaction) return false;

    final targetEventId =
        event.redacts ?? event.content['redacts']?.toString().trim() ?? '';
    if (targetEventId.isEmpty) return true;

    final roomId = event.room.id;
    final messages = _messagesCache[roomId];
    final index = messages?.indexWhere((m) => m.id == targetEventId) ?? -1;

    if (messages != null && index != -1) {
      final current = messages[index];
      final reason = event.content['reason']?.toString().trim() ?? '';
      final deletedContent =
          reason == 'Deleted by admin' ||
                  (event.senderId.trim().isNotEmpty &&
                      event.senderId.trim() != current.senderId.trim())
              ? 'This message was deleted by admin'
              : 'This message was deleted';
      if (current.isDeletedForEveryone && current.content == deletedContent) {
        apkLog(
          'ChatService.redaction',
          'duplicate redaction ignored room_id="$roomId" event_id="$targetEventId"',
        );
        return true;
      }
      final updated = current.copyWith(
        content: deletedContent,
        isDeletedForEveryone: true,
      );
      messages[index] = updated;
      _messageController.add(updated);
      _emitRoomMessages(roomId);
      unawaited(
        ChatLocalDb.instance.markMessageDeletedForEveryone(
          targetEventId,
          content: deletedContent,
        ),
      );
      _emitConversations();
      apkLog(
        'ChatService.redaction',
        'live redaction applied room_id="$roomId" event_id="$targetEventId"',
      );
      return true;
    }

    final deletedContent =
        event.content['reason']?.toString().trim() == 'Deleted by admin'
            ? 'This message was deleted by admin'
            : 'This message was deleted';
    unawaited(
      ChatLocalDb.instance.markMessageDeletedForEveryone(
        targetEventId,
        content: deletedContent,
      ),
    );
    apkLog(
      'ChatService.redaction',
      'live redaction stored room_id="$roomId" event_id="$targetEventId" '
          'text="$deletedContent"',
    );
    return true;
  }

  void _refreshAllMessageStatuses() {
    for (final room in MatrixClientService.instance.client.rooms) {
      _refreshMessageStatusesForRoom(room);
    }
  }

  void _refreshMessageStatusesForRoom(mx.Room room) {
    final messages = _messagesCache[room.id];
    if (messages == null || messages.isEmpty) return;
    final currentUser = MatrixClientService.instance.client.userID;
    if (currentUser == null || currentUser.isEmpty) return;

    final receiptEventIds = <String>{};
    void collectReceipts(Map<String, dynamic> receiptsByUser) {
      for (final entry in receiptsByUser.entries) {
        if (entry.key == currentUser) continue;
        final id = entry.value.eventId;
        if (id is String && id.isNotEmpty) receiptEventIds.add(id);
      }
    }

    collectReceipts(room.receiptState.global.otherUsers);
    final mainThread = room.receiptState.mainThread?.otherUsers;
    if (mainThread != null) collectReceipts(mainThread);
    final readIndex = messages.lastIndexWhere(
      (message) => receiptEventIds.contains(message.id),
    );

    final mdl =
        MatrixClientService
            .instance
            .client
            .accountData[_mdlAccountDataType]
            ?.content;
    final persistedRoomId = mdl?['room_id']?.toString();
    final persistedEventId = mdl?['last_delivered_event_id']?.toString();
    final markerRoomId = _pendingDeliveredRoomId ?? persistedRoomId;
    final deliveredEventId = _pendingDeliveredEventId ?? persistedEventId;
    final deliveredIndex =
        markerRoomId == room.id &&
                (_pendingDeliveredEventId != null ||
                    mdl?['status'] == 'delivered')
            ? messages.indexWhere((message) => message.id == deliveredEventId)
            : -1;

    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (!_isOwnMessage(message, currentUser) ||
          message.status == MessageStatus.failed ||
          message.status == MessageStatus.sending) {
        continue;
      }
      final next =
          readIndex >= i
              ? MessageStatus.read
              : deliveredIndex >= i
              ? MessageStatus.delivered
              : MessageStatus.sent;
      if (message.status == next ||
          message.status == MessageStatus.read ||
          (message.status == MessageStatus.delivered &&
              next == MessageStatus.sent)) {
        continue;
      }
      messages[i] = message.copyWith(status: next);
      _messageController.add(messages[i]);
      changed = true;
    }
    if (!changed) return;
    unawaited(ChatLocalDb.instance.saveMessages(messages));
    _emitRoomMessages(room.id);
    _emitConversations();
  }

  bool _isOwnMessage(ChatMessage message, String currentMatrixUserId) {
    final sender = message.senderId.trim();
    if (sender == currentMatrixUserId) return true;
    final localUserId = _currentUserId;
    if (localUserId == null || localUserId.isEmpty) return false;
    if (sender == localUserId) return true;
    if (sender.startsWith('@') && sender.contains(':')) {
      return sender.substring(1, sender.indexOf(':')) == localUserId;
    }
    return false;
  }

  Map<String, dynamic> _buildMessageContent(ChatMessage message) {
    final content = <String, dynamic>{
      'msgtype': mx.MessageTypes.Text,
      'body': message.content,
      if (message.isForwarded) 'wrytte.forwarded': true,
      if (_currentUserPhone?.isNotEmpty == true)
        'wrytte.sender_phone': _currentUserPhone,
      if (_cleanHumanName(_currentUserName).isNotEmpty)
        'wrytte.sender_name': _cleanHumanName(_currentUserName),
    };

    if (message.replyToMessageId != null) {
      final fallbackSender = message.replyToSenderId ?? message.senderId;
      final fallback = message.replyPreview ?? 'Message';
      content['body'] = '> <$fallbackSender> $fallback\n\n${message.content}';
      content['m.relates_to'] = {
        'm.in_reply_to': {'event_id': message.replyToMessageId},
      };
    }

    return content;
  }

  void _emitConversations() {
    _conversationsController.add(_sortedConversations());
  }

  Future<void> _repairConversationPreviewFromVisibleMessages(
    String conversationId,
  ) async {
    final existing = _conversationsMap[conversationId];
    if (existing == null) return;

    final visible = getConversationMessages(conversationId);
    if (visible.isEmpty) {
      final repaired = existing.copyWith(
        lastMessage: '',
        lastMessageSenderId: '',
      );
      _conversationsMap[conversationId] = repaired;
      await ChatLocalDb.instance.saveConversations([repaired]);
      return;
    }

    final last = visible.last;
    final repaired = existing.copyWith(
      lastMessage: last.content,
      lastMessageSenderId: last.senderId,
      lastMessageTime: last.timestamp,
      lastMessageType: last.attachmentType ?? existing.lastMessageType,
    );
    _conversationsMap[conversationId] = repaired;
    await ChatLocalDb.instance.saveConversations([repaired]);
  }

  Future<void> _applySavedContactsToHydratedConversations() async {
    final ownerUserId = (await AuthService.instance.getCurrentUserId())?.trim();
    if (ownerUserId == null || ownerUserId.isEmpty) return;

    final contacts = await ContactService().getMatrixContactsCached(
      ownerUserId,
    );
    if (contacts.isEmpty || _conversationsMap.isEmpty) return;

    var changed = false;
    for (final contact in contacts) {
      changed = _applyContactToConversationCache(contact) || changed;
    }

    if (changed) {
      unawaited(
        ChatLocalDb.instance.replaceConversations(
          _conversationsMap.values.toList(),
        ),
      );
    }
  }

  Future<void> _refreshPeerProfileFromBackendForMessage(
    ChatMessage message, {
    required String reason,
  }) {
    final ownerUserId = _currentUserId?.trim();
    if (ownerUserId == null || ownerUserId.isEmpty) return Future.value();

    final peerId = _peerMatrixIdForMessage(message);
    if (peerId == null || peerId.isEmpty) return Future.value();

    final existing = _profileRefreshInFlight[peerId];
    if (existing != null) return existing;

    final future = _refreshPeerProfileFromBackend(
      ownerUserId: ownerUserId,
      peerId: peerId,
      phoneHint: _peerPhoneHintForMessage(message),
      reason: reason,
    ).whenComplete(() {
      _profileRefreshInFlight.remove(peerId);
    });
    _profileRefreshInFlight[peerId] = future;
    return future;
  }

  Future<void> _refreshPeerProfileFromBackend({
    required String ownerUserId,
    required String peerId,
    required String phoneHint,
    required String reason,
  }) async {
    try {
      apkLog(
        'ChatService.profile',
        'BE refresh start reason="$reason" peer="$peerId"',
      );
      final profile = await UserProfileService.instance.getProfileByUid(
        peerId,
        phone: phoneHint,
      );
      if (profile == null) {
        apkLog(
          'ChatService.profile',
          'BE refresh empty reason="$reason" peer="$peerId"',
        );
        return;
      }

      final profilePhone = _normalizePhone(profile.phone);
      final phone = profilePhone.isNotEmpty ? profilePhone : phoneHint;
      final avatar =
          profile.hasProfileImage ? profile.profileImage.trim() : null;
      if (avatar?.isNotEmpty == true) {
        unawaited(AvatarPreloadService.warm(avatar));
      }

      final savedContact = await _savedContactForPeer(
        ownerUserId: ownerUserId,
        peerId: peerId,
        phone: phone,
      );

      Contact? refreshedSavedContact;
      if (savedContact != null) {
        refreshedSavedContact = await ContactLocalDb.refreshPublicProfileFields(
          ownerUserId: ownerUserId,
          wrytteUserId: peerId,
          phone: phone.isNotEmpty ? phone : savedContact.primaryPhone,
          avatarUrl: avatar,
          bio: profile.bio,
        );
        await applySavedContact(refreshedSavedContact ?? savedContact);
      } else if (phone.isNotEmpty) {
        await applyUnsavedContact(
          Contact(
            displayName: phone,
            phones: [phone],
            avatarUrl: avatar,
            bio: profile.bio,
            isOnWrytte: true,
            wrytteUserId: peerId,
          ),
        );
      }

      await ContactIdentityCache.instance.upsert(
        ownerUserId: ownerUserId,
        matrixUserId: peerId,
        phone: phone.isNotEmpty ? phone : null,
        profileName:
            _cleanHumanName(profile.displayName).isNotEmpty
                ? _cleanHumanName(profile.displayName)
                : null,
        savedName: savedContact?.formattedName,
        avatarUrl: avatar,
        bio: profile.bio,
      );

      apkLog(
        'ChatService.profile',
        'BE refresh done reason="$reason" peer="$peerId" saved=${savedContact != null} phone="$phone" avatar=${avatar?.isNotEmpty == true}',
      );
    } catch (e) {
      apkLog(
        'ChatService.profile',
        'BE refresh FAILED reason="$reason" peer="$peerId" error="$e"',
      );
    }
  }

  String? _peerMatrixIdForMessage(ChatMessage message) {
    final currentUser =
        MatrixClientService.instance.client.userID ?? _currentUserId ?? '';
    final candidates =
        _isOwnMessage(message, currentUser)
            ? [message.receiverId]
            : [message.senderId];

    for (final candidate in candidates) {
      final raw = candidate.trim();
      if (raw.isEmpty || raw.startsWith('!') || raw.startsWith('@!')) continue;
      final matrixId = _isValidMatrixUserId(raw) ? raw : _toMatrixUserId(raw);
      if (!_isValidMatrixUserId(matrixId)) continue;
      if (_isOwnMatrixId(matrixId, currentUser)) continue;
      return matrixId;
    }
    return null;
  }

  String _peerPhoneHintForMessage(ChatMessage message) {
    final currentUser =
        MatrixClientService.instance.client.userID ?? _currentUserId ?? '';
    if (!_isOwnMessage(message, currentUser)) {
      final senderPhone = _normalizePhone(message.senderPhone ?? '');
      if (senderPhone.isNotEmpty) return senderPhone;
    }
    for (final candidate in [message.receiverId, message.senderId]) {
      final phone = _normalizePhone(candidate);
      if (phone.isNotEmpty) return phone;
    }
    return '';
  }

  Future<Contact?> _savedContactForPeer({
    required String ownerUserId,
    required String peerId,
    required String phone,
  }) async {
    final contacts = await ContactLocalDb.loadSavedContacts(
      ownerUserId: ownerUserId,
    );
    final targetLocalpart = _matrixLocalpart(peerId);
    final targetPhone = _normalizePhone(phone);
    for (final contact in contacts) {
      final contactUserId = contact.wrytteUserId?.trim() ?? '';
      final sameWrytteId =
          contactUserId.isNotEmpty &&
          _matrixLocalpart(contactUserId) == targetLocalpart;
      final samePhone =
          targetPhone.isNotEmpty &&
          contact.phones.map(_normalizePhone).contains(targetPhone);
      if (sameWrytteId || samePhone) return contact;
    }
    return null;
  }

  bool _applyContactToConversationCache(Contact contact) {
    final name = _cleanHumanName(contact.displayName);
    if (name.isEmpty) return false;

    final avatar = _safePersonAvatar(contact.avatarUrl);
    final blockedGroupAvatar =
        (contact.avatarUrl?.trim().isNotEmpty ?? false) && avatar == null;
    final identityKeys = <String>{
      ..._conversationIdentityKeys(contact.wrytteUserId),
      for (final phone in contact.phones) ..._conversationIdentityKeys(phone),
    }..removeWhere((key) => key.isEmpty);
    if (identityKeys.isEmpty) return false;

    var changed = false;
    for (final entry in _conversationsMap.entries.toList()) {
      final conversation = entry.value;
      if (_isGroupConversationRow(conversation)) {
        continue; // ADDED: never enrich group
      }
      final conversationKeys = _keysForConversation(conversation);
      if (!conversationKeys.any(identityKeys.contains)) continue;

      final next = conversation.copyWith(
        otherUserName: name,
        otherUserAvatar:
            avatar?.isNotEmpty == true
                ? avatar
                : blockedGroupAvatar
                ? ''
                : conversation.otherUserAvatar,
      );
      if (next.otherUserName == conversation.otherUserName &&
          next.otherUserAvatar == conversation.otherUserAvatar) {
        continue;
      }
      _conversationsMap[entry.key] = next;
      changed = true;
    }
    return changed;
  }

  Future<void> applySavedContact(Contact contact) async {
    final name = _cleanHumanName(contact.displayName);
    if (name.isEmpty) return;

    var changed = _applyContactToConversationCache(contact);
    final avatar = _safePersonAvatar(contact.avatarUrl);
    final blockedGroupAvatar =
        (contact.avatarUrl?.trim().isNotEmpty ?? false) && avatar == null;
    if (changed) {
      unawaited(
        ChatLocalDb.instance.replaceConversations(
          _conversationsMap.values.toList(),
        ),
      );
    }

    final dbConversationIds = await ChatLocalDb.instance
        .findConversationIdsByMessageIdentity(
          userIds: [
            if (contact.wrytteUserId?.trim().isNotEmpty == true)
              contact.wrytteUserId!.trim(),
          ],
          phones: contact.phones,
        );

    for (final conversationId in dbConversationIds) {
      final conversation = _conversationsMap[conversationId];
      if (await _isGroupConversationId(conversationId, conversation)) {
        continue; // covers loaded, unloaded, and left/deleted groups
      }
      if (conversation != null) {
        final next = conversation.copyWith(
          otherUserName: name,
          otherUserAvatar:
              avatar?.trim().isNotEmpty == true
                  ? avatar
                  : blockedGroupAvatar
                  ? ''
                  : conversation.otherUserAvatar,
        );
        if (next.otherUserName != conversation.otherUserName ||
            next.otherUserAvatar != conversation.otherUserAvatar) {
          _conversationsMap[conversationId] = next;
          changed = true;
        }
      }
      unawaited(
        ChatLocalDb.instance.updateConversationUserInfo(
          conversationId: conversationId,
          name: name,
          avatar: avatar,
          clearAvatar: blockedGroupAvatar,
        ),
      );
    }
    if (changed) _emitConversations();
  }

  Future<void> applyUnsavedContact(Contact contact) async {
    final phone = _firstUsablePhone(contact.phones);
    if (phone.isEmpty) return;

    final avatar = _safePersonAvatar(contact.avatarUrl);
    final blockedGroupAvatar =
        (contact.avatarUrl?.trim().isNotEmpty ?? false) && avatar == null;
    final identityKeys = <String>{
      ..._conversationIdentityKeys(contact.wrytteUserId),
      for (final phone in contact.phones) ..._conversationIdentityKeys(phone),
    }..removeWhere((key) => key.isEmpty);
    if (identityKeys.isEmpty) return;

    var changed = false;
    for (final entry in _conversationsMap.entries.toList()) {
      final conversation = entry.value;
      if (_isGroupConversationRow(conversation)) {
        continue; // ADDED: never enrich group
      }
      final conversationKeys = _keysForConversation(conversation);
      if (!conversationKeys.any(identityKeys.contains)) continue;

      _conversationsMap[entry.key] = conversation.copyWith(
        otherUserName: phone,
        otherUserAvatar:
            avatar?.isNotEmpty == true
                ? avatar
                : blockedGroupAvatar
                ? ''
                : conversation.otherUserAvatar,
      );
      changed = true;
      unawaited(
        ChatLocalDb.instance.updateConversationUserInfo(
          conversationId: entry.key,
          name: phone,
          avatar: avatar,
          clearAvatar: blockedGroupAvatar,
        ),
      );
    }

    final dbConversationIds = await ChatLocalDb.instance
        .findConversationIdsByMessageIdentity(
          userIds: [
            if (contact.wrytteUserId?.trim().isNotEmpty == true)
              contact.wrytteUserId!.trim(),
          ],
          phones: contact.phones,
        );
    for (final conversationId in dbConversationIds) {
      if (await _isGroupConversationId(
        conversationId,
        _conversationsMap[conversationId],
      )) {
        continue;
      }
      if (_conversationsMap.containsKey(conversationId)) continue;
      unawaited(
        ChatLocalDb.instance.updateConversationUserInfo(
          conversationId: conversationId,
          name: phone,
          avatar: avatar,
        ),
      );
    }

    if (changed) _emitConversations();
  }

  List<ChatConversation> _sortedConversations() {
    return _conversationsMap.values.toList()
      ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
  }

  Set<String> _keysForConversation(ChatConversation conversation) {
    // Groups must not be matchable by member identity — that's how a member's
    // avatar leaks onto the group. Match groups only by their own room id.
    if (_isGroupConversationRow(conversation)) {
      return _conversationIdentityKeys(conversation.id).toSet()
        ..removeWhere((key) => key.isEmpty);
    }
    return <String>{
      ..._conversationIdentityKeys(conversation.otherUserId),
      ..._conversationIdentityKeys(conversation.lastMessageSenderId),
      ...conversation.participants.expand(_conversationIdentityKeys),
      if (conversation.otherUserName != null)
        ..._conversationIdentityKeys(conversation.otherUserName),
    }..removeWhere((key) => key.isEmpty);
  }

  Iterable<String> _conversationIdentityKeys(String? raw) sync* {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return;
    yield value.toLowerCase();

    if (value.startsWith('@') && value.contains(':')) {
      final localpart = value.substring(1, value.indexOf(':')).toLowerCase();
      if (localpart.isNotEmpty) yield localpart;
    }

    final phone = _normalizePhone(value);
    if (phone.isNotEmpty) {
      yield phone.toLowerCase();
      yield phone.replaceAll(RegExp(r'[^\d]'), '');
    } else {
      final digits = value.replaceAll(RegExp(r'[^\d]'), '');
      if (digits.length >= 7) yield digits;
    }
  }

  String _firstUsablePhone(Iterable<String> phones) {
    for (final raw in phones) {
      final phone = _normalizePhone(raw);
      if (phone.isNotEmpty) return phone;
    }
    return '';
  }

  String _toMatrixUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    final own = MatrixClientService.instance.client.userID;
    final domain =
        own != null && own.contains(':')
            ? own.split(':').last
            : MatrixConfig.serverName;
    final localpart = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
    return '@$localpart:$domain';
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    final digitsOnly = cleaned.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.length < 7 || digitsOnly.length > 15) return '';
    if (!cleaned.startsWith('+')) cleaned = '+$cleaned';
    return cleaned;
  }

  String _cleanHumanName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.length < 2) return '';
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' ||
        lowered == 'uder' ||
        lowered == 'unknown' ||
        lowered.startsWith('group with ')) {
      return '';
    }
    final phoneDigits = trimmed.replaceAll(RegExp(r'[\s\-()+]'), '');
    if (RegExp(r'^\d{6,}$').hasMatch(phoneDigits)) return '';
    final localpart =
        trimmed.startsWith('@')
            ? trimmed.substring(1).split(':').first
            : trimmed.split(':').first;
    if (RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart)) {
      return '';
    }
    return trimmed;
  }
}

class _WrytteDocumentFile extends mx.MatrixFile {
  _WrytteDocumentFile({required super.bytes, required super.name});

  @override
  String get msgType => mx.MessageTypes.File;
}
