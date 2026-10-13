import 'package:flutter/foundation.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

@immutable
class ChatTimelineEntry {
  const ChatTimelineEntry({required this.message, required this.messageIndex});

  final ChatMessagePresentation message;
  final int messageIndex;
}

@immutable
class ChatTimelineSection {
  const ChatTimelineSection({required this.label, required this.entries});

  final String label;
  final List<ChatTimelineEntry> entries;
}

/// Groups consecutive messages by their presentation day while preserving the
/// original index used for bubble grouping and selection.
List<ChatTimelineSection> buildChatTimelineSections(
  List<ChatMessagePresentation> messages,
) {
  if (messages.isEmpty) {
    return const <ChatTimelineSection>[];
  }

  final sections = <ChatTimelineSection>[];
  var currentLabel = messages.first.dayLabel;
  var currentEntries = <ChatTimelineEntry>[];

  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    if (message.dayLabel != currentLabel) {
      sections.add(
        ChatTimelineSection(
          label: currentLabel,
          entries: List<ChatTimelineEntry>.unmodifiable(currentEntries),
        ),
      );
      currentLabel = message.dayLabel;
      currentEntries = <ChatTimelineEntry>[];
    }

    currentEntries.add(
      ChatTimelineEntry(message: message, messageIndex: index),
    );
  }

  sections.add(
    ChatTimelineSection(
      label: currentLabel,
      entries: List<ChatTimelineEntry>.unmodifiable(currentEntries),
    ),
  );
  return List<ChatTimelineSection>.unmodifiable(sections);
}
