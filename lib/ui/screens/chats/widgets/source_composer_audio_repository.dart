import 'package:wrytte/data/services/device_audio_recording_service.dart';
import 'package:wrytte/domain/models/media_trim_range.dart';
import 'package:wrytte/domain/repositories/audio_recording_repository.dart';

/// The legacy chat screen keeps this provider boundary, but now uses the
/// complete production recorder from the source composer implementation.
class SourceComposerAudioRepository implements AudioRecordingRepository {
  SourceComposerAudioRepository()
      : _delegate = DeviceAudioRecordingService();

  final DeviceAudioRecordingService _delegate;

  @override
  Stream<double> get captureAmplitudes => _delegate.captureAmplitudes;
  @override
  Stream<Duration> get previewPositions => _delegate.previewPositions;
  @override
  Stream<bool> get previewPlaying => _delegate.previewPlaying;
  @override
  Future<bool> hasCapturePermission({bool request = true}) =>
      _delegate.hasCapturePermission(request: request);
  @override
  Future<void> startCapture() => _delegate.startCapture();
  @override
  Future<void> pauseCapture() => _delegate.pauseCapture();
  @override
  Future<void> resumeCapture() => _delegate.resumeCapture();
  @override
  Future<String?> stopCapture() => _delegate.stopCapture();
  @override
  Future<void> cancelCapture() => _delegate.cancelCapture();
  @override
  Future<String?> createPausedCapturePreview() =>
      _delegate.createPausedCapturePreview();
  @override
  Future<void> preparePreview(String path, {required MediaTrimRange range}) =>
      _delegate.preparePreview(path, range: range);
  @override
  Future<void> playPreview() => _delegate.playPreview();
  @override
  Future<void> pausePreview() => _delegate.pausePreview();
  @override
  Future<void> seekPreview(Duration position) =>
      _delegate.seekPreview(position);
  @override
  Future<void> setPreviewSpeed(double speed) =>
      _delegate.setPreviewSpeed(speed);
  @override
  Future<void> stopPreview() => _delegate.stopPreview();
  @override
  Future<void> dispose() => _delegate.dispose();
}
