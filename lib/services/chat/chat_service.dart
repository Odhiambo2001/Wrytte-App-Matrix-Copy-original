import 'dart:async';
import 'dart:io';

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

class ChatService {
  ChatService._internal();
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;

  static const String _hiddenEventsAccountDataType = 'com.wrytte.hidden_events';
  static const String groupDeletedMessageType = 'group_deleted';
  static const String groupDeletedEventKey = 'wrytte.group_deleted';
  static const String groupDeletedAtKey = 'wrytte.deleted_at';
  static const String groupDeletedByKey = 'wrytte.deleted_by';

  static bool isGroupDeletedPreview(String? value) {
    final text = value?.trim().toLowerCase() ?? '';
    return text.startsWith('this group has been deleted');
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
  Future<void>? _connectFuture;
  Future<void>? _historyRestoreFuture;
  StreamSubscription? _timelineSub;
  StreamSubscription? _syncSub;
  bool _handlingSync = false;

  static const int _matrixHistoryPageSize = MatrixConfig.historyPageSize;

  final Map<String, ChatConversation> _conversationsMap = {};
  final Map<String, List<ChatMessage>> _messagesCache = {};
  final Map<String, Set<String>> _hiddenEventIdsByRoom = {};
  final Map<String, DateTime> _groupJoinCutoffsByRoom = {};
  final Set<String> _createdGroupRoomIds = {};
  final Set<String> _readConversationIds = {};
  final Set<String> _activeReadConversationIds = {};
  final Map<String, DateTime> _lastReadAtByConversation = {};
  final Map<String, Future<void>> _profileRefreshInFlight = {};
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
      _suppressRestoredRoomUnread = true;

      final expectedMatrixUserId = _expectedMatrixUserId(_currentUserId!);
      apkLog(
        'ChatService.connect',
        'restore start user_id="$_currentUserId" expected="$expectedMatrixUserId"',
      );
      var client = await MatrixAuthService.instance.restore().timeout(
        const Duration(seconds: 5),
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
        if (_applyLiveRedactionEvent(event)) {
          _refreshMessageStatusesForRoom(event.room);
          return;
        }

        if (ChatMessage.matrixEditTargetId(event)?.isNotEmpty == true) {
          _applyMatrixEditEvent(event);
          _refreshMessageStatusesForRoom(event.room);
          return;
        }

        final message = ChatMessage.fromMatrixEvent(event);
        if (message == null) return;
        if (_isBeforeGroupJoinCutoff(message)) return;

        _cacheMessage(message);
        if (_isGroupDeletedMatrixEvent(event)) {
          unawaited(
            markGroupDeletedLocally(
              roomId: event.room.id,
              name: event.room.getLocalizedDisplayname(),
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

        _refreshMessageStatusesForRoom(event.room);

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
      _syncSub ??= client.onSync.stream.listen((update) {
        unawaited(_handleLiveSyncUpdate(update));
      });

      _isConnected = true;
      _connectionController.add(true);
      apkLog(
        'ChatService.connect',
        'ready isConnected=true user_id="${client.userID}" rooms=${client.rooms.length}',
      );
      await hydrateLocalConversations();
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

  Future<void> _recoverMatrixLocalStore() async {
    _isConnected = false;
    await _timelineSub?.cancel();
    await _syncSub?.cancel();
    _timelineSub = null;
    _syncSub = null;

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
      _refreshAllMessageStatuses();
      final userId = _currentUserId;
      if (userId != null && userId.isNotEmpty) {
        unawaited(ContactService().syncLocalContactsToBackend(userId));
      }

      await restoreAllRoomHistoryFromServer();
      await MatrixChatService.instance.ensureSyncedAndAutoJoinInvites(
        forceSync: true,
      );
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
      _refreshAllMessageStatuses();

      apkLog(
        'ChatService.connect',
        'startup sync complete; notifications enabled',
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

  Future<List<ChatMessage>> _restoreRoomHistoryFromServer(mx.Room room) async {
    mx.Timeline? timeline;
    try {
      timeline = await room.getTimeline(limit: null);
      var page = 0;

      while (timeline.canRequestHistory) {
        final beforeCount = timeline.events.length;
        page += 1;
        await timeline.requestHistory(
          historyCount: _matrixHistoryPageSize,
          filter: mx.StateFilter(lazyLoadMembers: true),
        );
        final afterCount = timeline.events.length;
        apkLog(
          'Matrix.history',
          'page room_id="${room.id}" page=$page before=$beforeCount '
              'after=$afterCount added=${afterCount - beforeCount} '
              'canMore=${timeline.canRequestHistory}',
        );

        if (afterCount <= beforeCount) {
          apkLog(
            'Matrix.history',
            'stop room_id="${room.id}" page=$page reason="no older timeline events returned"',
          );
          break;
        }
      }

      final localById = {
        for (final message in await ChatLocalDb.instance.loadMessages(room.id))
          message.id: message,
      };
      final hiddenIds = _hiddenEventIdsForRoom(room.id, room: room);
      final groupJoinCutoff = _groupJoinCutoffForRoom(room);
      final messages = _messagesFromMatrixEvents(
        timeline.events,
        localById: localById,
        hiddenIds: hiddenIds,
        groupJoinCutoff: groupJoinCutoff,
      );

      final latestRestoredAt =
          messages.isNotEmpty ? messages.last.timestamp : null;
      final serverReadAt = _serverReadTimeForRoom(room, messages);
      final restoredReadAt =
          latestRestoredAt == null
              ? serverReadAt
              : serverReadAt == null || latestRestoredAt.isAfter(serverReadAt)
              ? latestRestoredAt
              : serverReadAt;
      if (restoredReadAt != null) {
        _readConversationIds.add(room.id);
        _lastReadAtByConversation[room.id] = restoredReadAt;
        await ChatLocalDb.instance.markConversationReadAt(
          room.id,
          restoredReadAt,
        );
      }

      for (final message in messages) {
        _cacheMessage(message, countUnread: false);
      }
      await ChatLocalDb.instance.saveMessages(messages);
      _emitRoomMessages(room.id);
      _refreshMessageStatusesForRoom(room);
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
            name: event.room.getLocalizedDisplayname(),
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
                isStarred: local.isStarred,
                isDeletedForMe: local.isDeletedForMe || isHidden,
                isEdited: local.isEdited,
              );
    }

    for (final event in sortedEvents) {
      _applyMatrixEditEventToMap(event, byId);
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

  Future<void> _handleLiveSyncUpdate(mx.SyncUpdate update) async {
    if (!update.hasRoomUpdate) return;
    if (_handlingSync) return;
    _handlingSync = true;
    try {
      if (update.rooms?.invite?.isNotEmpty ?? false) {
        await MatrixChatService.instance.autoJoinTrustedDirectInvites();
      }
      _refreshConversationsFromRooms();
      _refreshAllMessageStatuses();
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

  Future<ChatMessage> sendMessage(ChatMessage message) async {
    try {
      return await _withMatrixTokenRetry('sendMessage', () async {
        await _waitForConnection();
        final client = MatrixClientService.instance.client;
        final room = _roomForMessage(message);
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
          receiverId: message.receiverId,
          timestamp: DateTime.now(),
          status: MessageStatus.sent,
          senderPhone: _currentUserPhone,
        );
        _cacheMessage(sent);
        unawaited(
          _refreshPeerProfileFromBackendForMessage(sent, reason: 'sendMessage'),
        );
        _refreshMessageStatusesForRoom(room);
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
    String senderName = 'New voice message',
  }) async {
    await _withMatrixTokenRetry('sendVoiceMessage', () async {
      await _waitForConnection();
      final room = await _directRoom(receiverID);
      await FileUploadLimits.validatePath(
        filePath,
        maxBytes: FileUploadLimits.voiceMessageMaxBytes,
        label: 'Voice message',
      );
      final bytes = await File(filePath).readAsBytes();
      final file = mx.MatrixAudioFile(
        bytes: bytes,
        name: p.basename(filePath),
        mimeType: 'audio/mpeg',
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
        receiverId: _toMatrixUserId(receiverID),
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
  }) async {
    await _withMatrixTokenRetry('sendVideoMessage', () async {
      await _waitForConnection();
      final room = await _directRoom(receiverID);
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
        receiverId: _toMatrixUserId(receiverID),
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
      final matrixFile =
          attachmentType == 'file'
              ? _WrytteDocumentFile(bytes: bytes, name: p.basename(filePath))
              : mx.MatrixFile.fromMimeType(
                bytes: bytes,
                name: p.basename(filePath),
              );
      final eventId = await room.sendFileEvent(
        matrixFile,
        extraContent:
            attachmentType == 'file'
                ? const {'wrytte.sent_as_file': true}
                : null,
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
    try {
      return await _withMatrixTokenRetry('fetchMessageHistory', () async {
        await _waitForConnection();
        final room = _roomById(conversationID);
        if (room == null) return [];
        return _restoreRoomHistoryFromServer(room);
      });
    } catch (e) {
      debugPrint('[ChatService] fetchMessageHistory error: $e');
      return [];
    }
  }

  Future<void> fetchConversations({int offset = 0, int count = 100}) async {
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
    int limit = 250,
  }) async {
    final id = roomId.trim();
    if (id.isEmpty) return const [];
    try {
      return await _withMatrixTokenRetry('fetchPublicGroupPreview', () async {
        await _waitForConnection();
        final client = MatrixClientService.instance.client;
        final messages = <ChatMessage>[];
        String? from;

        while (messages.length < limit) {
          final remaining = limit - messages.length;
          final pageLimit = remaining > 80 ? 80 : remaining;
          final response = await client.getRoomEvents(
            id,
            mx.Direction.b,
            from: from,
            limit: pageLimit,
          );
          final pageMessages =
              response.chunk
                  .map(
                    (event) => _publicGroupPreviewMessage(
                      event,
                      roomId: id,
                      client: client,
                    ),
                  )
                  .whereType<ChatMessage>();
          messages.addAll(pageMessages);

          final next = response.end?.trim();
          if (next == null || next.isEmpty || next == from) break;
          from = next;
        }

        messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        if (messages.isNotEmpty) {
          _messagesCache[id] = messages;
          await ChatLocalDb.instance.saveMessages(messages);
        }
        return messages;
      });
    } catch (e) {
      debugPrint('[ChatService] public group preview failed: $e');
      return const [];
    }
  }

  ChatMessage? _publicGroupPreviewMessage(
    mx.MatrixEvent event, {
    required String roomId,
    required mx.Client client,
  }) {
    if (event.type != mx.EventTypes.Message) return null;
    final content = event.content;
    final body = content['body']?.toString().trim() ?? '';
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
      senderName: content['wrytte.sender_name']?.toString(),
      senderPhone: content['wrytte.sender_phone']?.toString(),
      isForwarded: content['wrytte.forwarded'] == true,
    );
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
    return uri.getDownloadLink(client).toString();
  }

  Future<void> markConversationAsRead(String conversationId) async {
    try {
      await _withMatrixTokenRetry('markConversationAsRead', () async {
        await MatrixChatService.instance.markRead(
          conversationId,
          eventId: _latestKnownMessageId(conversationId),
        );
      });
    } catch (e) {
      debugPrint('[ChatService] markConversationAsRead error: $e');
    }

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
    _emitRoomMessages(conversationId);
    return visible;
  }

  Future<List<ChatMessage>> hydrateConversation(String conversationId) async {
    final memory = getConversationMessages(conversationId);
    if (memory.isNotEmpty) {
      _emitRoomMessages(conversationId);
      return memory;
    }
    return loadCachedMessages(conversationId);
  }

  Future<void> hydrateLocalConversations({bool syncReadMarkers = true}) async {
    _lastReadAtByConversation
      ..clear()
      ..addAll(await ChatLocalDb.instance.loadConversationReadMarkers());
    final conversations = await ChatLocalDb.instance.loadConversations();
    apkLog(
      'ChatService.local',
      'hydrated local conversations=${conversations.length}',
    );
    for (final conversation in conversations) {
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
    await _applySavedContactsToHydratedConversations();
    _emitConversations();
    for (final conversation in conversations) {
      await loadCachedMessages(conversation.id);
      if (syncReadMarkers && conversation.id.startsWith('!')) {
        await _syncLocalReadMarkerToMatrix(conversation.id);
      }
    }
    _emitConversations();
  }

  Future<void> _backfillConversationKinds() async {
    final upgraded = <ChatConversation>[];
    for (final entry in _conversationsMap.entries.toList()) {
      final conv = entry.value;
      if (conv.hasExplicitKind) continue;

      String kind = ConversationKind.unknown;
      final room = _roomById(conv.id);
      final storedAsGroup =
          (conv.lastMessageType == 'group' ||
              conv.lastMessageType == groupDeletedMessageType) &&
          conv.id.startsWith('!') &&
          conv.otherUserId == conv.id;
      final inRegistry = _createdGroupRoomIds.contains(conv.id.trim());
      final liveGroup =
          room != null && MatrixChatService.instance.isMatrixGroupRoom(room);

      if (storedAsGroup || inRegistry || liveGroup) {
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
        unawaited(markGroupCreated(conv.id));
      }
    }
    if (upgraded.isEmpty) return;
    await ChatLocalDb.instance.saveConversations(upgraded);
    apkLog(
      'ChatService.kindMigration',
      'stamped conversationKind on ${upgraded.length} legacy rows',
    );
  }

  Future<void> _syncLocalReadMarkerToMatrix(String conversationId) async {
    final eventId = _latestKnownMessageId(conversationId);
    if (eventId == null || eventId.isEmpty) return;
    try {
      await MatrixChatService.instance.markRead(
        conversationId,
        eventId: eventId,
      );
      apkLog(
        'ChatService.read',
        'synced local read marker room_id="$conversationId" event_id="$eventId"',
      );
    } catch (e) {
      debugPrint('[ChatService] local read marker sync skipped: $e');
    }
  }

  Future<void> starMessage(ChatMessage message, bool starred) async {
    final updated = message.copyWith(isStarred: starred);
    _replaceCachedMessage(updated);
    await ChatLocalDb.instance.setMessageStarred(message.id, starred);
    _messageController.add(updated);
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
      await room.redactEvent(message.id, reason: 'Deleted by sender');
    });
    final updated = message.copyWith(
      content: 'This message was deleted',
      isDeletedForEveryone: true,
    );
    _replaceCachedMessage(updated);
    await ChatLocalDb.instance.markMessageDeletedForEveryone(message.id);
    _messageController.add(updated);
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
      _refreshMessageStatusesForRoom(targetRoom);
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

  Future<void> disconnect() async {
    if (!_isConnected) return;
    await reset();
  }

  Future<void> reset() async {
    _isConnected = false;
    _connectFuture = null;
    _historyRestoreFuture = null;
    _currentUserId = null;
    _currentUserPhone = null;
    _currentUserName = null;
    _conversationsMap.clear();
    _messagesCache.clear();
    _readConversationIds.clear();
    _activeReadConversationIds.clear();
    _lastReadAtByConversation.clear();
    _profileRefreshInFlight.clear();
    MatrixChatService.instance.resetRuntimeState();
    for (final controller in _roomMessagesControllers.values) {
      if (!controller.isClosed) controller.add(const []);
    }
    await _timelineSub?.cancel();
    await _syncSub?.cancel();
    _timelineSub = null;
    _syncSub = null;
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
  }) async {
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
      conversationKind: ConversationKind.group,
    );
    _conversationsMap[roomId] = conversation;
    await markGroupCreated(roomId);
    await ChatLocalDb.instance.saveConversations([conversation]);
    _emitConversations();
    apkLog(
      'ChatService.groupCreate',
      'saved local group room_id="$roomId" name="${name.trim()}" participants=${conversation.participants.length}',
    );
    return conversation;
  }

  Future<ChatConversation> saveJoinedGroupShell({
    required String roomId,
    required String name,
    String? avatarUrl,
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
      conversationKind: ConversationKind.group,
    );
    await markGroupCreated(id);
    final existing = _conversationsMap[id];
    _conversationsMap[id] =
        existing == null
            ? conversation
            : _preferImmediateConversation(
              existing,
              conversation,
            ).copyWith(conversationKind: ConversationKind.group);
    await ChatLocalDb.instance.saveConversations([_conversationsMap[id]!]);
    _emitConversations();
    return _conversationsMap[id]!;
  }

  Future<ChatConversation> markGroupDeletedLocally({
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
    _emitConversations();
    return conversation;
  }

  mx.Room? _roomById(String roomId) {
    for (final room in MatrixClientService.instance.client.rooms) {
      if (room.id == roomId) return room;
    }
    return null;
  }

  ChatConversation _toConversation(mx.Room room) {
    final client = MatrixClientService.instance.client;
    final existing = _conversationsMap[room.id];
    final isGroupRoom = _isGroupRoom(room, existing);
    final cleanRoomName = _cleanHumanName(room.name);
    if (isGroupRoom) {
      final last = room.lastEvent;
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
      final deletedAt =
          last != null && _isGroupDeletedMatrixEvent(last)
              ? _groupDeletedAtFromEvent(last) ?? last.originServerTs
              : existing?.deletedAt;
      return ChatConversation(
        id: room.id,
        participants: [
          if (client.userID != null) client.userID!,
          ...room
              .getParticipants()
              .map((user) => user.id)
              .where((id) => id != client.userID),
        ],
        otherUserId: room.id,
        lastMessage: visibleLastMessage?.content ?? '',
        lastMessageSenderId:
            visibleLastMessage?.senderId ?? existing?.lastMessageSenderId ?? '',
        lastMessageTime:
            visibleLastMessage?.timestamp ??
            existing?.lastMessageTime ??
            DateTime.now(),
        unreadCount: _displayableUnreadCountForRoom(room, client.userID),
        lastMessageType: deletedAt == null ? 'group' : groupDeletedMessageType,
        conversationKind:
            existing?.hasExplicitKind == true
                ? existing!.conversationKind
                : ConversationKind.group,
        deletedAt: deletedAt,
        deletedBy:
            last != null && _isGroupDeletedMatrixEvent(last)
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

  DateTime? _serverReadTimeForRoom(mx.Room room, List<ChatMessage> messages) {
    if (messages.isEmpty) return null;
    final eventIds =
        <String>[
          room.receiptState.global.latestOwnReceipt?.eventId ?? '',
          room.receiptState.mainThread?.latestOwnReceipt?.eventId ?? '',
          room.fullyRead,
        ].where((eventId) => eventId.isNotEmpty).toList();

    for (final eventId in eventIds) {
      final index = messages.indexWhere((message) => message.id == eventId);
      if (index == -1) continue;
      var readAt = messages[index].timestamp;
      for (var i = 0; i <= index; i += 1) {
        final candidate = messages[i].timestamp;
        if (candidate.isAfter(readAt)) readAt = candidate;
      }
      return readAt;
    }

    final receiptTs = room.receiptState.global.latestOwnReceipt?.ts;
    if (receiptTs != null && receiptTs > 0) {
      return DateTime.fromMillisecondsSinceEpoch(receiptTs);
    }
    return null;
  }

  void _refreshConversationsFromRooms() {
    // ✅ Snapshot to avoid ConcurrentModificationError when sync
    // updates arrive while we're iterating.
    final rooms = List<mx.Room>.from(MatrixClientService.instance.client.rooms);

    apkLog(
      'ChatService.rooms',
      'refresh user_id="..." rooms=${rooms.length} ...',
    );

    for (final room in rooms) {
      // was: for (final room in client.rooms)
      _syncHiddenEventsFromRoom(room);
      _cacheRoomIdentity(room);
    }

    final merged = Map<String, ChatConversation>.from(_conversationsMap);
    var restoredFromCache = 0;
    var refreshedFromMatrix = 0;
    for (final room in rooms) {
      final existing = _conversationWithVisiblePreview(merged[room.id]);
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
    apkLog(
      'ChatService.rooms',
      'merged conversations total=${_conversationsMap.length} matrix=$refreshedFromMatrix cached=$restoredFromCache',
    );
    unawaited(
      ChatLocalDb.instance.replaceConversations(
        _conversationsMap.values.toList(),
      ),
    );
    _emitConversations();
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

  void _cacheMessage(ChatMessage message, {bool countUnread = true}) {
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
        conversationKind:
            existing?.hasExplicitKind == true
                ? existing!.conversationKind
                : ConversationKind.group,
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
      _emitRoomMessages(convId);
      _emitConversations();
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
    _emitRoomMessages(convId);
    _emitConversations();
  }

  void _prefetchPersistentAttachment(ChatMessage message) {
    final type = message.attachmentType?.trim();
    final source = message.attachmentUrl?.trim() ?? '';
    const persistentTypes = {'image', 'video', 'file', 'voice'};
    if (source.isEmpty || !persistentTypes.contains(type)) return;
    unawaited(_prefetchAttachment(message, source, type == 'file'));
  }

  Future<void> _prefetchAttachment(
    ChatMessage message,
    String source,
    bool allowPartial,
  ) async {
    try {
      await AttachmentLocalStore.instance.ensureInitial(
        source: source,
        fileName: message.content,
        allowPartial: allowPartial,
      );
    } catch (error) {
      apkLog(
        'ChatService.attachmentCache',
        'prefetch failed event_id="${message.id}" error="$error"',
      );
    }
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

  Future<void> _saveCreatedGroupRoomIds() async {
    final owner = _currentUserId;
    if (owner == null || owner.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _createdGroupRoomIdsKey(owner),
      _createdGroupRoomIds.toList(growable: false),
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
    final raw = event.content[groupDeletedAtKey]?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  String _groupDeletedByFromEvent(mx.Event event) =>
      event.content[groupDeletedByKey]?.toString().trim() ?? event.senderId;

  Future<void> removeConversationLocally(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
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
      final updated = current.copyWith(
        content: 'This message was deleted',
        isDeletedForEveryone: true,
      );
      messages[index] = updated;
      _messageController.add(updated);
      _emitRoomMessages(roomId);
      unawaited(ChatLocalDb.instance.markMessageDeletedForEveryone(updated.id));
      _emitConversations();
      apkLog(
        'ChatService.redaction',
        'live redaction applied room_id="$roomId" event_id="$targetEventId"',
      );
      return true;
    }

    unawaited(
      ChatLocalDb.instance.markMessageDeletedForEveryone(targetEventId),
    );
    _emitRoomMessages(roomId);
    _emitConversations();
    apkLog(
      'ChatService.redaction',
      'live redaction stored room_id="$roomId" event_id="$targetEventId"',
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

    final otherReceiptEventIds = _otherUserReceiptEventIds(room, currentUser);
    final peerJoined = _directPeerJoined(room, currentUser);
    final readIndex = messages.lastIndexWhere(
      (message) => otherReceiptEventIds.contains(message.id),
    );

    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (!_isOwnMessage(message, currentUser)) continue;
      if (message.status == MessageStatus.failed ||
          message.status == MessageStatus.sending) {
        continue;
      }

      final nextStatus =
          readIndex >= i
              ? MessageStatus.read
              : peerJoined
              ? MessageStatus.delivered
              : MessageStatus.sent;
      if (_messageStatusRank(nextStatus) < _messageStatusRank(message.status)) {
        continue;
      }
      if (message.status == nextStatus) continue;

      final updated = message.copyWith(status: nextStatus);
      messages[i] = updated;
      changed = true;
      _messageController.add(updated);
    }

    if (!changed) return;
    unawaited(ChatLocalDb.instance.saveMessages(messages));
    _emitRoomMessages(room.id);
    _emitConversations();
  }

  Set<String> _otherUserReceiptEventIds(mx.Room room, String currentUser) {
    final eventIds = <String>{};

    void collect(Map<String, dynamic> receiptsByUser) {
      for (final entry in receiptsByUser.entries) {
        if (entry.key == currentUser) continue;
        final eventId = entry.value.eventId;
        if (eventId is String && eventId.isNotEmpty) {
          eventIds.add(eventId);
        }
      }
    }

    collect(room.receiptState.global.otherUsers);
    final mainThreadReceipts = room.receiptState.mainThread?.otherUsers;
    if (mainThreadReceipts != null) collect(mainThreadReceipts);
    return eventIds;
  }

  bool _directPeerJoined(mx.Room room, String currentUser) {
    final directUserId = room.directChatMatrixID;
    if (directUserId == null || directUserId == currentUser) return false;
    return room
        .getParticipants([mx.Membership.join])
        .any((user) => user.id == directUserId);
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

  int _messageStatusRank(MessageStatus status) {
    switch (status) {
      case MessageStatus.failed:
        return -1;
      case MessageStatus.sending:
        return 0;
      case MessageStatus.sent:
        return 1;
      case MessageStatus.delivered:
        return 2;
      case MessageStatus.read:
        return 3;
    }
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
        forceRefresh: true,
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

    final avatar = contact.avatarUrl?.trim();
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
            avatar?.isNotEmpty == true ? avatar : conversation.otherUserAvatar,
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
              contact.avatarUrl?.trim().isNotEmpty == true
                  ? contact.avatarUrl
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
          avatar: contact.avatarUrl,
        ),
      );
    }
    if (changed) _emitConversations();
  }

  Future<void> applyUnsavedContact(Contact contact) async {
    final phone = _firstUsablePhone(contact.phones);
    if (phone.isEmpty) return;

    final avatar = contact.avatarUrl?.trim();
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
            avatar?.isNotEmpty == true ? avatar : conversation.otherUserAvatar,
      );
      changed = true;
      unawaited(
        ChatLocalDb.instance.updateConversationUserInfo(
          conversationId: entry.key,
          name: phone,
          avatar: avatar,
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
