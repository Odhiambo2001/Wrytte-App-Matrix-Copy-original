import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';

ChatMessage _message(String id) {
  return ChatMessage(
    id: id,
    conversationId: 'conversation',
    senderId: 'sender',
    receiverId: 'receiver',
    content: id,
    timestamp: DateTime(2026, 1, 1),
  );
}

void main() {
  test('duplicateMessageIds returns repeated IDs in encounter order', () {
    final messages = <ChatMessage>[
      _message('first'),
      _message('second'),
      _message('first'),
      _message('third'),
      _message('second'),
      _message('first'),
    ];

    expect(duplicateMessageIds(messages), ['first', 'second', 'first']);
  });

  test('duplicateMessageIds returns an empty list when IDs are unique', () {
    expect(
      duplicateMessageIds([_message('first'), _message('second')]),
      isEmpty,
    );
  });
}
