import 'package:flutter/material.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';

/// A lightweight ordered-pin indicator. Deliberately has no surrounding
/// container: the blue markers and preview sit directly on the parent surface.
class PinnedEventsStrip extends StatelessWidget {
  final List<String> pinnedEventIds;
  final List<ChatMessage> events;

  const PinnedEventsStrip({
    super.key,
    required this.pinnedEventIds,
    required this.events,
  });

  ChatMessage? get _latestVisibleEvent {
    for (final id in pinnedEventIds) {
      for (final event in events) {
        if (event.id == id && !event.isDeleted) return event;
      }
    }
    return null;
  }

  String _preview(ChatMessage event) {
    final type = event.attachmentType?.trim().toLowerCase() ?? '';
    if (event.isVoiceNote || type == 'audio') return 'Voice message';
    if (type == 'image') return 'Photo';
    if (type == 'video') return 'Video';
    if (type.isNotEmpty) return 'File';
    final text = event.content.trim().replaceAll(RegExp(r'\s+'), ' ');
    return text.isEmpty ? 'Message' : text;
  }

  @override
  Widget build(BuildContext context) {
    final event = _latestVisibleEvent;
    if (event == null || pinnedEventIds.isEmpty) {
      return const SizedBox.shrink();
    }
    final visibleMarkers =
        pinnedEventIds.length > 6 ? 6 : pinnedEventIds.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 5, 14, 7),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(
              visibleMarkers,
              (index) => Padding(
                padding: EdgeInsets.only(
                  bottom: index == visibleMarkers - 1 ? 0 : 2,
                ),
                child: SizedBox(
                  width: 3,
                  height: 7,
                  child: ColoredBox(
                    color: Color(
                      0xFF42A5F5,
                    ).withValues(alpha: index == 0 ? 1 : 0.48),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Icon(Icons.push_pin, size: 17, color: Color(0xFF42A5F5)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pinned message',
                  maxLines: 1,
                  style: TextStyle(
                    color: Color(0xFF42A5F5),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  _preview(event),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          if (pinnedEventIds.length > 6)
            Text(
              '+${pinnedEventIds.length - 6}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
