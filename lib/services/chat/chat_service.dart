import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:path/path.dart' as p;
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/matrix/matrix_contact_service.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'package:path_provider/path_provider.dart';

class ChatService {
  ChatService._internal();
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;

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
  Stream<List<ChatConversation>> get conversationsStream =>
      _conversationsController.stream;
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
  final Set<String> _readConversationIds = {};
  final Map<String, DateTime> _lastReadAtByConversation = {};

  bool get isConnected => _isConnected;
  String? get currentUserId => _currentUserId;

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
        final message = ChatMessage.fromMatrixEvent(event);
        if (message == null) return;
        _cacheMessage(message);
        _refreshMessageStatusesForRoom(event.room);
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
      await _finishConnectionWarmup();
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

    MatrixContactService.instance.clearCache();
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
      await _syncLocalContactsToMatrix();
      await restoreAllRoomHistoryFromServer();
      _refreshConversationsFromRooms();
      _refreshAllMessageStatuses();
    } catch (e) {
      debugPrint('[ChatService] connection warmup skipped: $e');
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
      final messages =
          timeline.events
              .map(ChatMessage.fromMatrixEvent)
              .whereType<ChatMessage>()
              .map((message) {
                final local = localById[message.id];
                if (local == null) return message;
                return message.copyWith(
                  isStarred: local.isStarred,
                  isDeletedForMe: local.isDeletedForMe,
                );
              })
              .where((message) => !message.isDeletedForMe)
              .toList()
            ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

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

  Future<void> _syncLocalContactsToMatrix() async {
    final ownerUserId = _currentUserId;
    if (ownerUserId == null || ownerUserId.isEmpty) return;
    try {
      await ContactService().syncLocalContactsToMatrix(ownerUserId);
    } catch (e) {
      debugPrint('[ChatService] Matrix contact sync skipped: $e');
    }
  }

  bool _isDisplayableMessage(ChatMessage? message) {
    if (message == null) return false;
    return message.content.trim().isNotEmpty ||
        (message.attachmentUrl?.trim().isNotEmpty ?? false);
  }

  Future<ChatMessage> sendMessage(ChatMessage message) async {
    try {
      return await _withMatrixTokenRetry('sendMessage', () async {
        await _waitForConnection();
        final client = MatrixClientService.instance.client;
        final room = _roomForMessage(message);
        await MatrixChatService.instance.ensurePeerInvited(
          roomId: room.id,
          matrixUserId: _toMatrixUserId(message.receiverId),
        );
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
      _messageController.add(local);
    });
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

  Future<void> markConversationAsRead(String conversationId) async {
    try {
      await _withMatrixTokenRetry('markConversationAsRead', () async {
        await MatrixChatService.instance.markRead(conversationId);
      });
      final current = _conversationsMap[conversationId];
      if (current != null) {
        final readAt = _latestKnownMessageTime(conversationId);
        _lastReadAtByConversation[conversationId] = readAt;
        _readConversationIds.add(conversationId);
        _conversationsMap[conversationId] = current.copyWith(unreadCount: 0);
        _emitConversations();
        await ChatLocalDb.instance.markConversationReadAt(
          conversationId,
          readAt,
        );
      } else {
        await ChatLocalDb.instance.markConversationRead(conversationId);
      }
    } catch (e) {
      debugPrint('[ChatService] markConversationAsRead error: $e');
    }
  }

  List<ChatMessage> getConversationMessages(String conversationId) {
    final messages =
        List<ChatMessage>.from(
          _messagesCache[conversationId] ?? [],
        ).where((message) => !message.isDeletedForMe).toList();
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  Future<List<ChatMessage>> loadCachedMessages(String conversationId) async {
    final cached = await ChatLocalDb.instance.loadMessages(conversationId);
    final visible =
        cached.where((message) => !message.isDeletedForMe).toList()
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

  Future<void> hydrateLocalConversations() async {
    _lastReadAtByConversation
      ..clear()
      ..addAll(await ChatLocalDb.instance.loadConversationReadMarkers());
    final conversations = await ChatLocalDb.instance.loadConversations();
    for (final conversation in conversations) {
      if (conversation.unreadCount == 0) {
        _readConversationIds.add(conversation.id);
        _lastReadAtByConversation.putIfAbsent(
          conversation.id,
          () => conversation.lastMessageTime,
        );
      }
      await loadCachedMessages(conversation.id);
    }
  }

  Future<void> starMessage(ChatMessage message, bool starred) async {
    final updated = message.copyWith(isStarred: starred);
    _replaceCachedMessage(updated);
    await ChatLocalDb.instance.setMessageStarred(message.id, starred);
    _messageController.add(updated);
  }

  Future<void> deleteMessageForMe(ChatMessage message) async {
    final updated = message.copyWith(isDeletedForMe: true);
    _replaceCachedMessage(updated);
    await ChatLocalDb.instance.deleteMessageForMe(message.id);
    _emitConversations();
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
  }) async {
    final room = await _directRoom(receiverId);
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
    _lastReadAtByConversation.clear();
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

  mx.Room? _roomById(String roomId) {
    for (final room in MatrixClientService.instance.client.rooms) {
      if (room.id == roomId) return room;
    }
    return null;
  }

  ChatConversation _toConversation(mx.Room room) {
    final client = MatrixClientService.instance.client;
    final otherId = _roomPeerMatrixId(room, client.userID) ?? room.id;
    final last = room.lastEvent;
    final lastMessage = last == null ? null : ChatMessage.fromMatrixEvent(last);
    final incomingSenderPhone =
        lastMessage == null ||
                client.userID == null ||
                _isOwnMessage(lastMessage, client.userID!)
            ? ''
            : _normalizePhone(lastMessage.senderPhone ?? '');
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
              : room.getLocalizedDisplayname(),
      otherUserAvatar: room.avatar?.toString(),
    );
  }

  int _displayableUnreadCountForRoom(mx.Room room, String? currentUser) {
    if (currentUser == null || currentUser.isEmpty) return 0;
    final readAt = _lastReadAtByConversation[room.id];

    final cached = _messagesCache[room.id];
    if (cached != null && cached.isNotEmpty) {
      return cached
          .where(
            (message) =>
                !message.isDeletedForMe &&
                _isDisplayableMessage(message) &&
                !_isOwnMessage(message, currentUser) &&
                _isAfterReadMarker(message, room.id),
          )
          .length;
    }

    if (_readConversationIds.contains(room.id)) return 0;

    final last = room.lastEvent;
    final lastMessage = last == null ? null : ChatMessage.fromMatrixEvent(last);
    if (!_isDisplayableMessage(lastMessage)) return 0;
    if (_isOwnMessage(lastMessage!, currentUser)) return 0;
    if (readAt != null && !lastMessage.timestamp.isAfter(readAt)) return 0;
    return 1;
  }

  void _refreshConversationsFromRooms() {
    final rooms = MatrixClientService.instance.client.rooms;
    apkLog(
      'ChatService.rooms',
      'refresh user_id="${MatrixClientService.instance.client.userID}" rooms=${rooms.length} '
          'summary="${rooms.map((r) => '${r.id}:${r.membership.name}:direct=${r.directChatMatrixID}:last=${r.lastEvent?.eventId ?? ''}').join('|')}"',
    );
    for (final room in rooms) {
      _cacheRoomIdentity(room);
    }
    _conversationsMap
      ..clear()
      ..addEntries(
        rooms
            .where((room) {
              final last = room.lastEvent;
              return last != null &&
                  _isDisplayableMessage(ChatMessage.fromMatrixEvent(last));
            })
            .map((room) => MapEntry(room.id, _toConversation(room))),
      );
    unawaited(
      ChatLocalDb.instance.replaceConversations(
        _conversationsMap.values.toList(),
      ),
    );
    _emitConversations();
  }

  void _cacheRoomIdentity(mx.Room room) {
    final ownerUserId = _currentUserId;
    final peerId = _roomPeerMatrixId(room, MatrixClientService.instance.userId);
    if (ownerUserId == null ||
        ownerUserId.isEmpty ||
        peerId == null ||
        peerId.isEmpty) {
      return;
    }
    unawaited(
      ContactIdentityCache.instance.upsert(
        ownerUserId: ownerUserId,
        matrixUserId: peerId,
        profileName: room.getLocalizedDisplayname(),
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
        !_isOwnMessage(message, currentUser) &&
        _isAfterReadMarker(message, convId);
    if (shouldCountUnread) {
      _readConversationIds.remove(convId);
    }
    final existing = _conversationsMap[convId];
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

  bool _upsertCachedMessage(ChatMessage message) {
    final convId = message.conversationId;
    final messages = _messagesCache.putIfAbsent(convId, () => []);
    final existingIndex = messages.indexWhere((m) => m.id == message.id);
    if (existingIndex == -1) {
      messages.add(message);
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return true;
    }
    messages[existingIndex] = message;
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return false;
  }

  DateTime _latestKnownMessageTime(String conversationId) {
    final cached = _messagesCache[conversationId];
    if (cached != null && cached.isNotEmpty) {
      final visible = cached.where((message) => !message.isDeletedForMe);
      var latest = DateTime.fromMillisecondsSinceEpoch(0);
      for (final message in visible) {
        if (message.timestamp.isAfter(latest)) latest = message.timestamp;
      }
      if (latest.millisecondsSinceEpoch > 0) return latest;
    }
    final conversation = _conversationsMap[conversationId];
    return conversation?.lastMessageTime ?? DateTime.now();
  }

  bool _isAfterReadMarker(ChatMessage message, String conversationId) {
    final readAt = _lastReadAtByConversation[conversationId];
    if (readAt == null) return true;
    return message.timestamp.isAfter(readAt);
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
    final sorted =
        _conversationsMap.values.toList()
          ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    _conversationsController.add(sorted);
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
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
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
