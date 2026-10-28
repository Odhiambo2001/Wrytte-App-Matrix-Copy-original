import 'package:wrytte/data/services/device_audio_recording_service.dart';
import 'package:wrytte/domain/models/media_trim_range.dart';
import 'package:wrytte/domain/repositories/audio_recording_repository.dart';

class AudioRecordingRepositoryImpl implements AudioRecordingRepository {
  AudioRecordingRepositoryImpl(this._service);

  final DeviceAudioRecordingService _service;

  @override
  Stream<double> get captureAmplitudes => _service.captureAmplitudes;

  @override
  Stream<Duration> get previewPositions => _service.previewPositions;

  @override
  Stream<bool> get previewPlaying => _service.previewPlaying;

  @override
  Future<bool> hasCapturePermission({bool request = true}) =>
      _service.hasCapturePermission(request: request);

  @override
  Future<void> startCapture() => _service.startCapture();

  @override
  Future<void> pauseCapture() => _service.pauseCapture();

  @override
  Future<void> resumeCapture() => _service.resumeCapture();

  @override
  Future<String?> stopCapture() => _service.stopCapture();

  @override
  Future<void> cancelCapture() => _service.cancelCapture();

  @override
  Future<String?> createPausedCapturePreview() =>
      _service.createPausedCapturePreview();

  @override
  Future<void> preparePreview(
    String path, {
    required MediaTrimRange range,
  }) {
    return _service.preparePreview(path, range: range);
  }

  @override
  Future<void> playPreview() => _service.playPreview();

  @override
  Future<void> pausePreview() => _service.pausePreview();

  @override
  Future<void> seekPreview(Duration position) =>
      _service.seekPreview(position);

  @override
  Future<void> setPreviewSpeed(double speed) =>
      _service.setPreviewSpeed(speed);

  @override
  Future<void> stopPreview() => _service.stopPreview();

  @override
  Future<void> dispose() => _service.dispose();
}
