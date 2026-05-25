import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:path/path.dart' as p;
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

class ChatService {
  ChatService._internal();
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;

  final _messageController = StreamController<ChatMessage>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _conversationsController =
      StreamController<List<ChatConversation>>.broadcast();

  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<List<ChatConversation>> get conversationsStream =>
      _conversationsController.stream;

  String? _currentUserId;
  bool _isConnected = false;
  Future<void>? _connectFuture;
  StreamSubscription? _timelineSub;
  StreamSubscription? _syncSub;
  bool _handlingSync = false;

  final Map<String, ChatConversation> _conversationsMap = {};
  final Map<String, List<ChatMessage>> _messagesCache = {};

  bool get isConnected => _isConnected;
  String? get currentUserId => _currentUserId;

  String _expectedMatrixUserId(String userId) =>
      '@$userId:${MatrixConfig.serverName}';

  Future<void> connect() async {
    final activeUserId = await AuthService.instance.getCurrentUserId();
    if (_isConnected && _currentUserId == activeUserId) return;
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

  Future<void> _connect() async {
    try {
      final user = await AuthService.instance.getCurrentUser();
      _currentUserId = user?.userId;
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
      unawaited(_finishConnectionWarmup());
    } catch (e) {
      _isConnected = false;
      _connectionController.add(false);
      _errorController.add('Connection failed: $e');
      apkLog('ChatService.connect', 'FAILED error="$e"');
      rethrow;
    }
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
      );
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
      );
    }

    return current;
  }

  Future<mx.Client> _loginCurrentMatrixSession({
    required String expectedMatrixUserId,
    required String userId,
    required String nickname,
  }) async {
    apkLog(
      'ChatService.connect',
      'Matrix login required user_id="$userId" expected="$expectedMatrixUserId"',
    );
    try {
      await AuthService.instance
          .loginToMatrix(userId: userId, nickname: nickname)
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
      _refreshConversationsFromRooms();
      _refreshAllMessageStatuses();
    } catch (e) {
      debugPrint('[ChatService] connection warmup skipped: $e');
    }
  }

  Future<void> _waitForConnection() async {
    if (_isConnected) return;
    await connect();
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

  Future<ChatMessage> sendMessage(ChatMessage message) async {
    await _waitForConnection();
    try {
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
      );
      _cacheMessage(sent);
      _refreshMessageStatusesForRoom(room);
      return sent;
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
      attachmentType: 'voice',
      voiceDuration: durationSeconds,
    );
    _cacheMessage(local);
    _messageController.add(local);
  }

  Future<List<ChatMessage>> fetchMessageHistory({
    required String conversationID,
    Object? startMsg,
    int count = 40,
  }) async {
    await _waitForConnection();
    try {
      final room = _roomById(conversationID);
      if (room == null) return [];
      final timeline = await room.getTimeline(limit: count);
      final localById = {
        for (final message in await ChatLocalDb.instance.loadMessages(
          conversationID,
        ))
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
      unawaited(ChatLocalDb.instance.saveMessages(messages));
      _refreshMessageStatusesForRoom(room);
      timeline.cancelSubscriptions();
      return messages;
    } catch (e) {
      debugPrint('[ChatService] fetchMessageHistory error: $e');
      return [];
    }
  }

  Future<void> fetchConversations({int offset = 0, int count = 100}) async {
    try {
      await MatrixAuthService.instance.restore();
      _refreshConversationsFromRooms();
    } catch (e) {
      debugPrint('[ChatService] fetchConversations error: $e');
    }
  }

  Future<void> markConversationAsRead(String conversationId) async {
    try {
      await MatrixChatService.instance.markRead(conversationId);
      final current = _conversationsMap[conversationId];
      if (current != null) {
        _conversationsMap[conversationId] = current.copyWith(unreadCount: 0);
        _emitConversations();
      }
      await ChatLocalDb.instance.markConversationRead(conversationId);
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
      _messagesCache.putIfAbsent(conversationId, () => []);
      if (!_messagesCache[conversationId]!.any((m) => m.id == message.id)) {
        _messagesCache[conversationId]!.add(message);
      }
    }
    return visible;
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
    await _waitForConnection();
    final room = _roomById(message.conversationId);
    if (room == null) {
      throw StateError('Unknown Matrix room: ${message.conversationId}');
    }
    await room.redactEvent(message.id, reason: 'Deleted by sender');
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
      final room = await _directRoom(otherUserId);
      apkLog(
        'ChatService',
        'Matrix direct room ready room_id="${room.id}" otherUserId="$otherUserId"',
      );
      return room.id;
    } catch (e) {
      debugPrint('[ChatService] get conversation id error: $e');
      return null;
    }
  }

  Future<String?> findMatrixConversationId(String otherUserId) async {
    try {
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
    _currentUserId = null;
    _conversationsMap.clear();
    _messagesCache.clear();
    await _timelineSub?.cancel();
    await _syncSub?.cancel();
    _timelineSub = null;
    _syncSub = null;
    _connectionController.add(false);
  }

  void dispose() {
    disconnect();
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
    final otherId = room.directChatMatrixID ?? room.id;
    final last = room.lastEvent;
    return ChatConversation(
      id: room.id,
      participants: [if (client.userID != null) client.userID!, otherId],
      otherUserId: otherId,
      lastMessage: last?.body ?? '',
      lastMessageSenderId: last?.senderId ?? '',
      lastMessageTime: last?.originServerTs ?? DateTime.now(),
      unreadCount: room.notificationCount,
      otherUserName: room.getLocalizedDisplayname(),
      otherUserAvatar: room.avatar?.toString(),
    );
  }

  void _refreshConversationsFromRooms() {
    final rooms = MatrixClientService.instance.client.rooms;
    _conversationsMap
      ..clear()
      ..addEntries(
        rooms.map((room) => MapEntry(room.id, _toConversation(room))),
      );
    unawaited(
      ChatLocalDb.instance.saveConversations(_conversationsMap.values.toList()),
    );
    _emitConversations();
  }

  void _cacheMessage(ChatMessage message, {bool countUnread = true}) {
    final convId = message.conversationId;
    final currentUser =
        MatrixClientService.instance.client.userID ?? _currentUserId ?? '';
    _messagesCache.putIfAbsent(convId, () => []);
    final isNewMessage =
        !_messagesCache[convId]!.any((m) => m.id == message.id);
    if (isNewMessage) {
      _messagesCache[convId]!.add(message);
    }
    final existing = _conversationsMap[convId];
    _conversationsMap[convId] =
        existing == null
            ? ChatConversation.fromMessage(
              message,
              currentUser,
            ).copyWith(unreadCount: countUnread ? null : 0)
            : isNewMessage && countUnread
            ? existing.updateWithMessage(message, currentUser)
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
            );
    unawaited(_persistCachedMessage(message, _conversationsMap[convId]!));
    _emitConversations();
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
}
