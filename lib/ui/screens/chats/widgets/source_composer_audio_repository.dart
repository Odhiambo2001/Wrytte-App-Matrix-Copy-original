import 'package:wrytte/domain/models/media_trim_range.dart';
import 'package:wrytte/domain/repositories/audio_recording_repository.dart';

/// Safe adapter used while the legacy chat screen adopts the source composer.
class SourceComposerAudioRepository implements AudioRecordingRepository {
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
  Future<void> preparePreview(String path, {required MediaTrimRange range}) async {}
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
