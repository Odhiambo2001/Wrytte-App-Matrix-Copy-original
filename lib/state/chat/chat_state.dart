import 'dart:async';

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/chat/chat_service.dart';

class ChatState {
  String? _activeConversationId;

  final ChatService _chatService = ChatService();
  final List<ChatMessage> _messages = [];
  final List<ChatConversation> _conversations = [];

  StreamSubscription? _messageSub;
  StreamSubscription? _conversationSub;

  final StreamController<List<ChatMessage>> _messagesController =
      StreamController<List<ChatMessage>>.broadcast();
  final StreamController<List<ChatConversation>> _conversationsController =
      StreamController<List<ChatConversation>>.broadcast();
  final StreamController<bool> _loadingController =
      StreamController<bool>.broadcast();
  final StreamController<String?> _errorController =
      StreamController<String?>.broadcast();

  Stream<List<ChatMessage>> get messagesStream => _messagesController.stream;
  Stream<List<ChatConversation>> get conversationsStream =>
      _conversationsController.stream;
  Stream<bool> get loadingStream => _loadingController.stream;
  Stream<String?> get errorStream => _errorController.stream;

  Future<void> initialize() async {
    _loadingController.add(true);
    try {
      await _chatService.connect();
      _messageSub ??= _chatService.messageStream.listen(_handleIncomingMessage);
      _conversationSub ??=
          _chatService.conversationsStream.listen(_handleConversations);
      await _chatService.fetchConversations();
      _loadingController.add(false);
    } catch (e) {
      _loadingController.add(false);
      _handleError('Failed to initialize chat: $e');
    }
  }

  Future<void> loadConversation(String conversationId) async {
    _activeConversationId = conversationId;
    _messages
      ..clear()
      ..addAll(_chatService.getConversationMessages(conversationId));

    if (_messages.isEmpty) {
      _messages.addAll(
        await _chatService.fetchMessageHistory(conversationID: conversationId),
      );
    }

    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _messagesController.add(List.unmodifiable(_messages));
  }

  Future<void> sendMessage(ChatMessage message) async {
    if (message.conversationId == _activeConversationId) {
      _upsertMessage(message);
    }

    try {
      final sent = await _chatService.sendMessage(message);
      _upsertMessage(sent);
    } catch (e) {
      _upsertMessage(message.copyWith(status: MessageStatus.failed));
      _handleError('Failed to send message: $e');
    }
  }

  void clearMessages() {
    _messages.clear();
    _messagesController.add([]);
  }

  Future<void> disconnect() => _chatService.disconnect();

  void dispose() {
    _messageSub?.cancel();
    _conversationSub?.cancel();
    _messagesController.close();
    _conversationsController.close();
    _loadingController.close();
    _errorController.close();
  }

  void _handleIncomingMessage(ChatMessage message) {
    if (message.conversationId == _activeConversationId) {
      _upsertMessage(message);
    }
  }

  void _handleConversations(List<ChatConversation> conversations) {
    _conversations
      ..clear()
      ..addAll(conversations);
    _conversationsController.add(List.unmodifiable(_conversations));
  }

  void _upsertMessage(ChatMessage message) {
    final index = _messages.indexWhere((m) => m.id == message.id);
    if (index == -1) {
      _messages.add(message);
    } else {
      _messages[index] = message;
    }
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _messagesController.add(List.unmodifiable(_messages));
  }

  void _handleError(String message) {
    _errorController.add(message);
  }
}
