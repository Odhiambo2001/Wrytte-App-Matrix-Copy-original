import 'package:flutter/material.dart';

class PinnedMessageWidget extends StatelessWidget {
  final Map<String, dynamic>? pinnedMessage;
  final VoidCallback onTap;
  final String currentUserId;
  final String otherUserName;

  const PinnedMessageWidget({
    super.key,
    required this.pinnedMessage,
    required this.onTap,
    required this.currentUserId,
    required this.otherUserName,
  });

  String _getMessagePreview(Map<String, dynamic> messageData) {
    final messageType = messageData['messageType'] ?? 'text';
    if (messageType == 'text') {
      final text = messageData['text']?.toString() ?? '';
      return text.length > 40 ? '${text.substring(0, 40)}...' : text;
    }
    if (messageType == 'image') return 'Photo';
    if (messageType == 'audio') return 'Voice message';
    return 'Message';
  }

  String _getSenderName(Map<String, dynamic> messageData) {
    final senderId = messageData['senderId']?.toString() ?? '';
    return senderId == currentUserId ? 'You' : otherUserName;
  }

  @override
  Widget build(BuildContext context) {
    final messageData = pinnedMessage;
    if (messageData == null || messageData.isEmpty) {
      return const SizedBox.shrink();
    }

    final senderName = _getSenderName(messageData);
    final messagePreview = _getMessagePreview(messageData);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade800, width: 1),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.push_pin, color: Colors.blue, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pinned message',
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$senderName: $messagePreview',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade300, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
