import 'package:flutter/material.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';

/// A lightweight ordered-pin indicator. Deliberately has no surrounding
/// container: the blue markers and preview sit directly on the parent surface.
class PinnedEventsStrip extends StatefulWidget {
  final List<String> pinnedEventIds;
  final List<ChatMessage> events;
  final ValueChanged<String>? onOpenEvent;

  const PinnedEventsStrip({
    super.key,
    required this.pinnedEventIds,
    required this.events,
    this.onOpenEvent,
  });

  @override
  State<PinnedEventsStrip> createState() => _PinnedEventsStripState();
}

class _PinnedEventsStripState extends State<PinnedEventsStrip> {
  int _selectedIndex = 0;

  @override
  void didUpdateWidget(covariant PinnedEventsStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pinnedEventIds.isEmpty) {
      _selectedIndex = 0;
      return;
    }
    final previousId =
        oldWidget.pinnedEventIds.isEmpty
            ? null
            : oldWidget.pinnedEventIds[_selectedIndex <
                    oldWidget.pinnedEventIds.length
                ? _selectedIndex
                : 0];
    final retainedIndex =
        previousId == null ? -1 : widget.pinnedEventIds.indexOf(previousId);
    _selectedIndex = retainedIndex >= 0 ? retainedIndex : 0;
  }

  String get _selectedId => widget.pinnedEventIds[_selectedIndex];

  ChatMessage? get _selectedEvent {
    for (final event in widget.events) {
      if (event.id == _selectedId && !event.isDeleted) return event;
    }
    return null;
  }

  void _select(int index) {
    if (index < 0 || index >= widget.pinnedEventIds.length) return;
    setState(() => _selectedIndex = index);
  }

  void _selectNext() {
    final nextIndex =
        widget.pinnedEventIds.length < 2
            ? _selectedIndex
            : (_selectedIndex + 1) % widget.pinnedEventIds.length;
    _select(nextIndex);
    widget.onOpenEvent?.call(widget.pinnedEventIds[nextIndex]);
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
    if (widget.pinnedEventIds.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_selectedIndex >= widget.pinnedEventIds.length) _selectedIndex = 0;
    final event = _selectedEvent;
    final visibleMarkers =
        widget.pinnedEventIds.length > 6 ? 6 : widget.pinnedEventIds.length;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _selectNext,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 5, 14, 7),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Column(
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
                        ).withValues(alpha: index == _selectedIndex ? 1 : 0.36),
                      ),
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
                    event == null
                        ? 'Pinned message unavailable'
                        : _preview(event),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (widget.pinnedEventIds.length > 6)
              Text(
                '+${widget.pinnedEventIds.length - 6}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}
