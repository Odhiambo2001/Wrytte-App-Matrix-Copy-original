import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wrytte/domain/models/media_trim_range.dart';
import 'package:wrytte/domain/repositories/audio_recording_repository.dart';
import 'package:wrytte/ui/chat/models/chat_screen_config.dart';
import 'package:wrytte/ui/chat/view_models/chat_audio_playback_view_model.dart';
import 'package:wrytte/ui/chat/view_models/chat_view_model.dart';
import 'package:wrytte/ui/chat/views/chat_view.dart';

/// Source-workspace chat surface migrated as a complete screen.
class SourceChatPreviewScreen extends StatelessWidget {
  const SourceChatPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final audio = _PreviewAudioRepository();
    return MultiProvider(
      providers: [
        Provider<AudioRecordingRepository>.value(value: audio),
        ChangeNotifierProvider(
          create: (_) => ChatViewModel(
            config: const ChatScreenConfig.preview(),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatAudioPlaybackViewModel(audio),
        ),
      ],
      child: const ChatView(),
    );
  }
}

/// Preview-only audio boundary. The migrated image UI still constructs the
/// source chat composer, which requires this provider even when no recording
/// action is used.
class _PreviewAudioRepository implements AudioRecordingRepository {
  @override
  Stream<double> get captureAmplitudes => const Stream<double>.empty();

  @override
  Stream<Duration> get previewPositions => const Stream<Duration>.empty();

  @override
  Stream<bool> get previewPlaying => const Stream<bool>.empty();

  @override
  Future<bool> hasCapturePermission({bool request = true}) async => false;

  @override
  Future<void> startCapture() async {}

  @override
  Future<void> pauseCapture() async {}

  @override
  Future<void> resumeCapture() async {}

  @override
  Future<String?> stopCapture() async => null;

  @override
  Future<void> cancelCapture() async {}

  @override
  Future<String?> createPausedCapturePreview() async => null;

  @override
  Future<void> preparePreview(
    String path, {
    required MediaTrimRange range,
  }) async {}

  @override
  Future<void> playPreview() async {}

  @override
  Future<void> pausePreview() async {}

  @override
  Future<void> seekPreview(Duration position) async {}

  @override
  Future<void> setPreviewSpeed(double speed) async {}

  @override
  Future<void> stopPreview() async {}

  @override
  Future<void> dispose() async {}
}
