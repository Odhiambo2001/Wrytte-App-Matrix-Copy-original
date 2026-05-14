import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:path/path.dart' as p;
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';

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

  final Map<String, ChatConversation> _conversationsMap = {};
  final Map<String, List<ChatMessage>> _messagesCache = {};

  bool get isConnected => _isConnected;
  String? get currentUserId => _currentUserId;

  Future<void> connect() async {
    if (_isConnected) return;
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

      await MatrixAuthService.instance.restore();
      final client = MatrixClientService.instance.client;
      if (!client.isLogged()) {
        await AuthService.instance.loginToMatrix(
          userId: _currentUserId!,
          nickname: user?.username ?? _currentUserId!,
        );
      }

      _timelineSub ??= client.onTimelineEvent.stream.listen((event) {
        final message = ChatMessage.fromMatrixEvent(event);
        if (message == null) return;
        _cacheMessage(message);
        _messageController.add(message);
      });
      _syncSub ??= client.onSync.stream.listen((_) => fetchConversations());

      _isConnected = true;
      _connectionController.add(true);
      await fetchConversations();
    } catch (e) {
      _isConnected = false;
      _connectionController.add(false);
      _errorController.add('Connection failed: $e');
      rethrow;
    }
  }

  Future<void> _waitForConnection() async {
    if (_isConnected) return;
    await connect();
  }

  Future<ChatMessage> sendMessage(ChatMessage message) async {
    await _waitForConnection();
    try {
      final client = MatrixClientService.instance.client;
      final room = _roomForMessage(message);
      final eventId = await room.sendTextEvent(message.content);
      final sent = message.copyWith(
        id: eventId ?? message.id,
        conversationId: room.id,
        senderId: client.userID ?? _currentUserId ?? '',
        receiverId: message.receiverId,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      );
      _cacheMessage(sent);
      _messageController.add(sent);
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
    final eventId = await room.sendAudioEvent(file, durationInMs: durationSeconds * 1000);
    final local = ChatMessage(
      id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
      conversationId: room.id,
      senderId: MatrixClientService.instance.client.userID ?? _currentUserId ?? '',
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
      final messages = timeline.events
          .map(ChatMessage.fromMatrixEvent)
          .whereType<ChatMessage>()
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      for (final message in messages) {
        _cacheMessage(message);
      }
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
      final rooms = MatrixClientService.instance.client.rooms;
      _conversationsMap
        ..clear()
        ..addEntries(rooms.map((room) => MapEntry(room.id, _toConversation(room))));
      _emitConversations();
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
    } catch (e) {
      debugPrint('[ChatService] markConversationAsRead error: $e');
    }
  }

  List<ChatMessage> getConversationMessages(String conversationId) {
    final messages = List<ChatMessage>.from(_messagesCache[conversationId] ?? []);
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  Future<String?> getOpenImConversationId(String otherUserId) async {
    try {
      final room = await _directRoom(otherUserId);
      return room.id;
    } catch (e) {
      debugPrint('[ChatService] get conversation id error: $e');
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
      'Call getOpenImConversationId(receiverId) before sending.',
    );
  }

  Future<mx.Room> _directRoom(String otherUserId) async =>
      MatrixChatService.instance.getOrCreateDirectRoom(_toMatrixUserId(otherUserId));

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
      participants: [
        if (client.userID != null) client.userID!,
        otherId,
      ],
      otherUserId: otherId,
      lastMessage: last?.body ?? '',
      lastMessageSenderId: last?.senderId ?? '',
      lastMessageTime: last?.originServerTs ?? DateTime.now(),
      unreadCount: room.notificationCount,
      otherUserName: room.displayname,
      otherUserAvatar: room.avatar?.toString(),
    );
  }

  void _cacheMessage(ChatMessage message) {
    final convId = message.conversationId;
    final currentUser = MatrixClientService.instance.client.userID ?? _currentUserId ?? '';
    _messagesCache.putIfAbsent(convId, () => []);
    if (!_messagesCache[convId]!.any((m) => m.id == message.id)) {
      _messagesCache[convId]!.add(message);
    }
    final existing = _conversationsMap[convId];
    _conversationsMap[convId] = existing == null
        ? ChatConversation.fromMessage(message, currentUser)
        : existing.updateWithMessage(message, currentUser);
    _emitConversations();
  }

  void _emitConversations() {
    final sorted = _conversationsMap.values.toList()
      ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    _conversationsController.add(sorted);
  }

  String _toMatrixUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    final own = MatrixClientService.instance.client.userID;
    final domain = own != null && own.contains(':') ? own.split(':').last : 'matrix.org';
    final localpart = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
    return '@$localpart:$domain';
  }
}
