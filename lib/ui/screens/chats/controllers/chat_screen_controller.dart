import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/state/chat/chat_state.dart';

class ChatScreenController {
  final String conversationId;
  final AuthUser currentUser;
  final String receiverId;

  late final ChatState _chatState;
  final ChatService _chatService = ChatService();

  ChatScreenController({
    required this.conversationId,
    required this.currentUser,
    required this.receiverId,
  }) {
    _chatState = ChatState();
  }


  // PUBLIC STREAMS


  Stream<List<ChatMessage>> get messagesStream => _chatState.messagesStream;
  Stream<bool>              get loadingStream  => _chatState.loadingStream;
  Stream<String?>           get errorStream    => _chatState.errorStream;


  // INITIALIZE


  Future<void> initialize() async {
    await _chatState.initialize();
    final String resolvedId = await _resolveConversationId();
    await _chatState.loadConversation(resolvedId);
  }


  // SEND TEXT MESSAGE


  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty) return;

    final resolvedId = await _resolveConversationId();

    final message = ChatMessage(
      id: '${currentUser.userId}_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: resolvedId,
      senderId: currentUser.userId,
      receiverId: receiverId,
      content: content.trim(),
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    );

    await _chatState.sendMessage(message);
  }


  // SEND VOICE NOTE


  Future<void> sendVoiceMessage({
    required String filePath,
    required int durationSeconds,
  }) async {
    await _chatService.sendVoiceMessage(
      receiverID: receiverId,
      filePath: filePath,
      durationSeconds: durationSeconds,
      senderName: currentUser.username.isNotEmpty
          ? currentUser.username
          : 'New voice message',
    );
  }


  // IS MINE


  bool isMine(ChatMessage message) {
    return message.senderId == currentUser.userId;
  }


  // DISPOSE


  void dispose() {
    _chatState.dispose();
  }


  // PRIVATE HELPERS


  String? _cachedConversationId;

  Future<String> _resolveConversationId() async {
    if (_cachedConversationId != null) return _cachedConversationId!;

    _cachedConversationId =
        await _chatService.getMatrixConversationId(receiverId) ?? conversationId;

    return _cachedConversationId!;
  }
}
