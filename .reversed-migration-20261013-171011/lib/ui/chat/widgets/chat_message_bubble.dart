import 'dart:async';

import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';
import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/chat/view_models/chat_audio_playback_view_model.dart';
import 'package:wrytte/ui/chat/view_models/chat_video_playback_view_model.dart';
import 'package:wrytte/ui/chat/widgets/audio_message_bubble.dart';
import 'package:wrytte/ui/chat/widgets/contact_message_bubble.dart';
import 'package:wrytte/ui/chat/widgets/file_message_bubble.dart';
import 'package:wrytte/ui/chat/widgets/image_message_bubble.dart';
import 'package:wrytte/ui/chat/widgets/round_video_message_bubble.dart';
import 'package:wrytte/ui/chat/widgets/text_message_bubble.dart';
import 'package:wrytte/ui/chat/widgets/video_message_bubble.dart';

// =============================================================================
// Callbacks
// =============================================================================

typedef ChatMessageActionCallback =
    FutureOr<void> Function(
      ChatMessagePresentation message,
      MessageAction action,
    );

typedef ChatMessageReactionCallback =
    FutureOr<void> Function(
      ChatMessagePresentation message,
      String reaction,
    );

// =============================================================================
// Router
// =============================================================================

class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({
    super.key,
    required this.message,
    this.showTail = true,
    this.isPinned = false,
    this.audioPlayback,
    this.videoPlayback,
    this.onBeforeVideoPlay,
    this.onActionSelected,
    this.onReactionSelected,
    this.actions,
    this.usePinChoices = false,
    this.onTextTap,
  });

  final ChatMessagePresentation message;
  final bool showTail;
  final bool isPinned;

  final ChatAudioPlaybackViewModel? audioPlayback;
  final ChatVideoPlaybackViewModel? videoPlayback;

  final Future<void> Function()? onBeforeVideoPlay;

  final ChatMessageActionCallback? onActionSelected;
  final ChatMessageReactionCallback? onReactionSelected;

  final List<MessageAction>? actions;
  final bool usePinChoices;

  /// Called only for a confirmed ordinary tap on a TEXT message.
  ///
  /// It deliberately lives outside TextMessageBubble's existing action
  /// recognizers. Flutter's gesture arena automatically rejects this tap when:
  ///
  /// - the pointer becomes a horizontal Reply / Forward swipe
  /// - the pointer becomes a vertical list scroll
  /// - the long-press recognizer wins and opens message actions
  ///
  /// Other message kinds do not receive this callback.
  final VoidCallback? onTextTap;

  @override
  Widget build(BuildContext context) {
    final actionConfig = _buildActionConfig();

    final presentedMessage = message.pinned == isPinned
        ? message
        : message.withPinned(isPinned);

    switch (message.kind) {
      // =======================================================================
      // Text
      // =======================================================================

      case ChatMessageKind.text:
        final textBubble = TextMessageBubble(
          message: presentedMessage,
          showTail: showTail,
          actionConfig: actionConfig,
        );

        final handleTap = onTextTap;
        if (handleTap == null) {
          return textBubble;
        }

        return GestureDetector(
          // deferToChild is important: TextMessageBubble's outer Align may
          // occupy the full message row, but only the actual bubble subtree
          // should make this detector hittable. Tapping blank row space must
          // remain an "empty conversation" tap handled by ChatView.
          behavior: HitTestBehavior.deferToChild,
          onTap: handleTap,
          child: textBubble,
        );

      // =======================================================================
      // Image
      // =======================================================================

      case ChatMessageKind.image:
        return ImageMessageBubble(
          message: presentedMessage,
          showTail: showTail,
          actionConfig: actionConfig,
        );

      // =======================================================================
      // Video
      // =======================================================================

      case ChatMessageKind.video:
        final playback = videoPlayback;

        if (playback == null) {
          return const SizedBox.shrink();
        }

        if (message.isVideoNote) {
          return RoundVideoMessageBubble(
            message: presentedMessage,
            playback: playback,
            actionConfig: actionConfig,
            onBeforePlay: onBeforeVideoPlay,
          );
        }

        return VideoMessageBubble(
          message: presentedMessage,
          playback: playback,
          showTail: showTail,
          actionConfig: actionConfig,
          onBeforePlay: onBeforeVideoPlay,
        );

      // =======================================================================
      // Audio
      // =======================================================================

      case ChatMessageKind.audio:
        return AudioMessageBubble(
          message: presentedMessage,
          showTail: showTail,
          playback: audioPlayback,
          actionConfig: actionConfig,
        );

      // =======================================================================
      // File
      // =======================================================================

      case ChatMessageKind.file:
        return FileMessageBubble(
          message: presentedMessage,
          showTail: showTail,
          actionConfig: actionConfig,
        );

      // =======================================================================
      // Contact
      // =======================================================================

      case ChatMessageKind.contact:
        return ContactMessageBubble(
          message: presentedMessage,
          showTail: showTail,
          actionConfig: actionConfig,
        );
    }
  }

  // ===========================================================================
  // Actions
  // ===========================================================================

  MessageActionConfig _buildActionConfig() {
    return MessageActionConfig(
      actions: actions ?? _actionsForMessage(),
      onActionSelected: onActionSelected == null
          ? null
          : (action) {
              return onActionSelected!(message, action);
            },
      onReactionSelected: onReactionSelected == null
          ? null
          : (reaction) {
              return onReactionSelected!(message, reaction);
            },
      usePinChoices: usePinChoices,
      canDeleteForEveryone: message.isMine,
    );
  }

  List<MessageAction> _actionsForMessage() {
    final actions = switch (message.kind) {
      ChatMessageKind.text => <MessageAction>[
        const MessageAction.reply(),
        const MessageAction.copy(),
        const MessageAction.forward(),
        if (message.isMine) const MessageAction.edit(),
        if (isPinned)
          const MessageAction.unpin()
        else
          const MessageAction.pin(),
        const MessageAction.delete(),
      ],
      ChatMessageKind.image => <MessageAction>[
        const MessageAction.reply(),
        const MessageAction.copy(),
        const MessageAction.save(),
        const MessageAction.forward(),
        if (isPinned)
          const MessageAction.unpin()
        else
          const MessageAction.pin(),
        const MessageAction.delete(),
      ],
      ChatMessageKind.video => <MessageAction>[
        const MessageAction.reply(),
        const MessageAction.copy(),
        const MessageAction.save(),
        const MessageAction.forward(),
        if (isPinned)
          const MessageAction.unpin()
        else
          const MessageAction.pin(),
        const MessageAction.delete(),
      ],
      ChatMessageKind.audio => <MessageAction>[
        const MessageAction.reply(),
        const MessageAction.copy(),
        const MessageAction.forward(),
        if (isPinned)
          const MessageAction.unpin()
        else
          const MessageAction.pin(),
        const MessageAction.delete(),
      ],
      ChatMessageKind.file => <MessageAction>[
        const MessageAction.reply(),
        const MessageAction.copy(),
        const MessageAction.forward(),
        if (isPinned)
          const MessageAction.unpin()
        else
          const MessageAction.pin(),
        const MessageAction.delete(),
      ],
      ChatMessageKind.contact => <MessageAction>[
        const MessageAction.reply(),
        const MessageAction.copy(),
        const MessageAction.forward(),
        if (isPinned)
          const MessageAction.unpin()
        else
          const MessageAction.pin(),
        const MessageAction.delete(),
      ],
    };

    return <MessageAction>[
      ...actions,
      const MessageAction.select(),
    ];
  }
}
