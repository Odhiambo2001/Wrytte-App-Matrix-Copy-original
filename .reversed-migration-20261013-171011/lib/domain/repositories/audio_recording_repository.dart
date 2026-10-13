import 'package:wrytte/domain/models/media_trim_range.dart';

/// Voice recording + preview boundary used by the chat recording controller.
abstract interface class AudioRecordingRepository {
  Stream<double> get captureAmplitudes;
  Stream<Duration> get previewPositions;
  Stream<bool> get previewPlaying;

  Future<bool> hasCapturePermission({bool request = true});

  Future<void> startCapture();
  Future<void> pauseCapture();
  Future<void> resumeCapture();
  Future<String?> stopCapture();
  Future<void> cancelCapture();

  /// Builds a temporary playable WAV snapshot while the real recorder remains
  /// paused. This preserves true pause/resume while still allowing the old
  /// Wrytte paused-editor preview UI to work.
  Future<String?> createPausedCapturePreview();

  Future<void> preparePreview(
    String path, {
    required MediaTrimRange range,
  });

  Future<void> playPreview();
  Future<void> pausePreview();
  Future<void> seekPreview(Duration position);
  Future<void> setPreviewSpeed(double speed);
  Future<void> stopPreview();

  Future<void> dispose();
}
