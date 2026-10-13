import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wrytte/ui/chat/models/chat_screen_config.dart';
import 'package:wrytte/ui/chat/view_models/chat_audio_playback_view_model.dart';
import 'package:wrytte/ui/chat/view_models/chat_view_model.dart';
import 'package:wrytte/ui/chat/views/chat_view.dart';

/// Source-workspace chat surface migrated as a complete screen.
class SourceChatPreviewScreen extends StatelessWidget {
  const SourceChatPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatViewModel(
        config: const ChatScreenConfig.preview(),
      ),
      child: const ChatView(),
    );
  }
}
