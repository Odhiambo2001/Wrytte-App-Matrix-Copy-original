import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wrytte/domain/models/media_trim_range.dart';
import 'package:wrytte/domain/repositories/audio_recording_repository.dart';
import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

/// Coordinates voice-note playback so the chat owns one native player instead
/// of allocating an audio engine for every visible message bubble.
class ChatAudioPlaybackViewModel extends ChangeNotifier {
  ChatAudioPlaybackViewModel(this._repository) {
    _positionSubscription = _repository.previewPositions.listen((value) {
      position = value;
      notifyListeners();
    });
    _playingSubscription = _repository.previewPlaying.listen((value) {
      playing = value;
      notifyListeners();
    });
  }

  final AudioRecordingRepository _repository;
  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<bool> _playingSubscription;

  String? activeMessageId;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  double speed = 1;

  bool isActive(String messageId) => activeMessageId == messageId;

  double progressFor(String messageId) {
    if (!isActive(messageId) || duration.inMicroseconds <= 0) return 0;
    return (position.inMicroseconds / duration.inMicroseconds)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  Future<void> toggle(ChatMessagePresentation message) async {
    final path = message.assetPath;
    if (path == null || path.isEmpty) return;
    if (isActive(message.id)) {
      if (playing) {
        await _repository.pausePreview();
      } else {
        await _repository.playPreview();
      }
      return;
    }
    final total = Duration(
      seconds: (message.audioDurationSeconds ?? 1).clamp(1, 86400),
    );
    await _repository.stopPreview();
    await _repository.preparePreview(path, range: MediaTrimRange.full(total));
    activeMessageId = message.id;
    position = Duration.zero;
    duration = total;
    speed = 1;
    await _repository.setPreviewSpeed(speed);
    notifyListeners();
    await _repository.playPreview();
  }

  Future<void> seek(ChatMessagePresentation message, double progress) async {
    if (!isActive(message.id)) {
      await toggle(message);
      await _repository.pausePreview();
    }
    final target = Duration(
      microseconds: (duration.inMicroseconds * progress.clamp(0.0, 1.0))
          .round(),
    );
    position = target;
    notifyListeners();
    await _repository.seekPreview(target);
  }

  Future<void> cycleSpeed() async {
    speed = switch (speed) {
      < 1.25 => 1.5,
      < 1.75 => 2,
      _ => 1,
    };
    await _repository.setPreviewSpeed(speed);
    notifyListeners();
  }

  Future<void> stopAndClear() async {
    await _repository.stopPreview();
    activeMessageId = null;
    position = Duration.zero;
    duration = Duration.zero;
    playing = false;
    speed = 1;
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSubscription.cancel();
    _playingSubscription.cancel();
    if (activeMessageId != null) unawaited(_repository.stopPreview());
    super.dispose();
  }
}
