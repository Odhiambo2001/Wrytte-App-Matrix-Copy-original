import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wrytte/domain/models/media_trim_range.dart';

/// Owns voice-note capture and the single player used for paused/review preview.
///
/// Capture uses record's PCM16 stream instead of asking the native recorder to
/// keep an unfinished WAV file open. Wrytte writes the PCM stream itself and can
/// therefore create a valid WAV snapshot at any pause point without stopping the
/// resumable native recording session.
class DeviceAudioRecordingService {
  DeviceAudioRecordingService() {
    _playerStateSubscription = _player.playerStateStream.listen((state) {
      final playing =
          state.playing && state.processingState != ProcessingState.completed;

      _previewPlayingController.add(playing);

      if (state.processingState == ProcessingState.completed) {
        unawaited(_rewindCompletedPreview());
      }
    });

    _positionSubscription = _player.positionStream.listen(
      _previewPositionController.add,
    );
  }

  static const int _captureSampleRate = 24000;
  static const int _captureChannels = 1;
  static const int _bitsPerSample = 16;

  int _effectiveSampleRate = _captureSampleRate;
  int _effectiveChannels = _captureChannels;

  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: true,
    useLazyPreparation: true,
  );

  final AudioRecorder _recorder = AudioRecorder();

  final StreamController<double> _captureAmplitudeController =
      StreamController<double>.broadcast(sync: true);

  final StreamController<Duration> _previewPositionController =
      StreamController<Duration>.broadcast(sync: true);

  final StreamController<bool> _previewPlayingController =
      StreamController<bool>.broadcast(sync: true);

  late final StreamSubscription<PlayerState> _playerStateSubscription;
  late final StreamSubscription<Duration> _positionSubscription;

  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<Uint8List>? _pcmSubscription;
  IOSink? _pcmSink;
  Completer<void>? _pcmDone;

  MediaTrimRange? _previewRange;
  String? _activeCapturePath;
  String? _activePcmPath;
  String? _pausedPreviewSnapshotPath;

  bool _disposed = false;

  Stream<double> get captureAmplitudes => _captureAmplitudeController.stream;

  Stream<Duration> get previewPositions => _previewPositionController.stream;

  Stream<bool> get previewPlaying => _previewPlayingController.stream;

  Future<bool> hasCapturePermission({bool request = true}) {
    _assertUsable();
    return _recorder.hasPermission(request: request);
  }

  Future<void> startCapture() async {
    _assertUsable();

    await stopPreview();
    await _deletePausedPreviewSnapshot();

    final directory = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final wavPath =
        '${directory.path}${Platform.pathSeparator}wrytte_voice_$stamp.wav';
    final pcmPath =
        '${directory.path}${Platform.pathSeparator}wrytte_voice_$stamp.pcm';

    final pcmFile = File(pcmPath);
    final sink = pcmFile.openWrite(mode: FileMode.writeOnly);

    _activeCapturePath = wavPath;
    _activePcmPath = pcmPath;
    _pcmSink = sink;

    try {
      _effectiveSampleRate = _captureSampleRate;
      _effectiveChannels = _captureChannels;

      await _recorder.setOnConfigChanged((config) {
        _effectiveSampleRate = config.sampleRate;
        _effectiveChannels = config.numChannels;
      });

      final pcmStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _captureSampleRate,
          numChannels: _captureChannels,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
          audioInterruption: AudioInterruptionMode.pause,
        ),
      );

      final done = Completer<void>();
      _pcmDone = done;

      _pcmSubscription = pcmStream.listen(
        sink.add,
        onError: (Object error, StackTrace stackTrace) {
          // The recorder operation itself reports actionable failures. Mark the
          // stream as finished here so teardown never leaves an unobserved Future
          // error behind.
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: false,
      );
    } catch (_) {
      await _closePcmOutput();
      await _deleteIfExists(pcmPath);
      await _deleteIfExists(wavPath);
      _activeCapturePath = null;
      _activePcmPath = null;
      rethrow;
    }

    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 70))
        .listen((amplitude) {
          final normalized = ((amplitude.current + 52) / 52).clamp(0.03, 1.0);
          _captureAmplitudeController.add(normalized.toDouble());
        });
  }

  Future<void> pauseCapture() async {
    _assertUsable();

    if (!await _recorder.isRecording()) return;
    if (await _recorder.isPaused()) return;

    await _recorder.pause();

    // The PCM stream belongs to Wrytte, so flushing it gives the paused editor
    // a deterministic boundary from which a valid WAV preview can be built.
    await _pcmSink?.flush();
  }

  Future<void> resumeCapture() async {
    _assertUsable();

    if (!await _recorder.isRecording()) return;
    if (!await _recorder.isPaused()) return;

    await stopPreview();
    await _deletePausedPreviewSnapshot();
    await _recorder.resume();
  }

  /// Creates a fully valid WAV snapshot while the real PCM recording remains
  /// paused and resumable.
  Future<String?> createPausedCapturePreview() async {
    _assertUsable();

    if (!await _recorder.isRecording()) return null;
    if (!await _recorder.isPaused()) return null;

    final pcmPath = _activePcmPath;
    if (pcmPath == null || pcmPath.isEmpty) return null;

    await _pcmSink?.flush();

    final pcmFile = File(pcmPath);
    if (!await pcmFile.exists()) return null;

    // A stream event can already be queued when pause completes. Give that
    // event one turn, flush once more, then snapshot the stable byte boundary.
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await _pcmSink?.flush();

    var pcmLength = await pcmFile.length();
    if (pcmLength <= 0) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _pcmSink?.flush();
      pcmLength = await pcmFile.length();
    }
    if (pcmLength <= 0) return null;

    await _deletePausedPreviewSnapshot();

    final directory = await getTemporaryDirectory();
    final snapshotPath =
        '${directory.path}${Platform.pathSeparator}'
        'wrytte_voice_pause_preview_${DateTime.now().microsecondsSinceEpoch}.wav';

    await _writeWavFromPcm(
      pcmPath: pcmPath,
      wavPath: snapshotPath,
      pcmLength: pcmLength,
    );

    _pausedPreviewSnapshotPath = snapshotPath;
    return snapshotPath;
  }

  Future<String?> stopCapture() async {
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    await stopPreview();
    await _deletePausedPreviewSnapshot();

    final wavPath = _activeCapturePath;
    final pcmPath = _activePcmPath;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }

      await _waitForPcmDone();
      await _pcmSink?.flush();
      await _closePcmOutput();

      if (wavPath == null || pcmPath == null) return null;

      final pcmFile = File(pcmPath);
      if (!await pcmFile.exists()) return null;

      final pcmLength = await pcmFile.length();
      if (pcmLength <= 0) return null;

      await _writeWavFromPcm(
        pcmPath: pcmPath,
        wavPath: wavPath,
        pcmLength: pcmLength,
      );

      return wavPath;
    } finally {
      if (pcmPath != null) await _deleteIfExists(pcmPath);
      _activeCapturePath = null;
      _activePcmPath = null;
    }
  }

  Future<void> cancelCapture() async {
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    await stopPreview();
    await _deletePausedPreviewSnapshot();

    final wavPath = _activeCapturePath;
    final pcmPath = _activePcmPath;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.cancel();
      }
    } finally {
      await _waitForPcmDone();
      await _closePcmOutput();

      if (pcmPath != null) await _deleteIfExists(pcmPath);
      if (wavPath != null) await _deleteIfExists(wavPath);

      _activeCapturePath = null;
      _activePcmPath = null;
    }
  }

  Future<void> preparePreview(
    String path, {
    required MediaTrimRange range,
  }) async {
    _assertUsable();

    await _player.stop();
    var sourceDuration = await _player.setFilePath(path, preload: true);

    if (sourceDuration == null || sourceDuration <= Duration.zero) {
      try {
        sourceDuration = _readPcmWavDuration(await File(path).readAsBytes());
      } catch (_) {
        // Keep the caller-provided range when header inspection is unavailable.
      }
    }

    var start = range.start;
    var end = range.end;

    if (sourceDuration != null && sourceDuration > Duration.zero) {
      if (start > sourceDuration) start = Duration.zero;
      if (end > sourceDuration) end = sourceDuration;
      if (end <= start) {
        start = Duration.zero;
        end = sourceDuration;
      }
    }

    if (end <= start) {
      throw StateError('Voice preview has no playable audio range.');
    }

    _previewRange = MediaTrimRange(start: start, end: end);

    await _player.setClip(start: start, end: end);
    await _player.seek(start);
    _previewPositionController.add(start);
  }

  Future<void> playPreview() async {
    final range = _previewRange;
    if (range == null) {
      throw StateError('Voice preview has not been prepared.');
    }

    if (_player.processingState == ProcessingState.completed ||
        _player.position >= range.end) {
      await _player.seek(range.start);
    }

    // just_audio's play Future completes when playback ends, so intentionally
    // do not await it here. PlayerStateStream drives the UI immediately.
    unawaited(_player.play());
  }

  Future<void> pausePreview() => _player.pause();

  Future<void> seekPreview(Duration position) async {
    final range = _previewRange;
    if (range == null) return;

    final target = position < range.start
        ? range.start
        : position > range.end
        ? range.end
        : position;

    await _player.seek(target);
    _previewPositionController.add(target);
  }

  Future<void> setPreviewSpeed(double speed) {
    return _player.setSpeed(speed.clamp(.5, 2).toDouble());
  }

  Future<void> stopPreview() async {
    await _player.stop();
    _previewRange = null;
    _previewPlayingController.add(false);
  }

  Future<void> _rewindCompletedPreview() async {
    final start = _previewRange?.start;
    if (start == null) return;

    await _player.pause();
    await _player.seek(start);
    _previewPositionController.add(start);
  }

  Future<void> _writeWavFromPcm({
    required String pcmPath,
    required String wavPath,
    required int pcmLength,
  }) async {
    final source = File(pcmPath);
    final target = File(wavPath);
    final sink = target.openWrite(mode: FileMode.writeOnly);

    try {
      sink.add(_buildPcmWavHeader(pcmLength));
      await sink.addStream(source.openRead(0, pcmLength));
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Uint8List _buildPcmWavHeader(int dataLength) {
    final bytes = Uint8List(44);
    final data = ByteData.sublistView(bytes);

    void ascii(int offset, String text) {
      for (var index = 0; index < text.length; index++) {
        bytes[offset + index] = text.codeUnitAt(index);
      }
    }

    const bytesPerSample = _bitsPerSample ~/ 8;
    final blockAlign = _effectiveChannels * bytesPerSample;
    final byteRate = _effectiveSampleRate * blockAlign;

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + dataLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, _effectiveChannels, Endian.little);
    data.setUint32(24, _effectiveSampleRate, Endian.little);
    data.setUint32(28, byteRate, Endian.little);
    data.setUint16(32, blockAlign, Endian.little);
    data.setUint16(34, _bitsPerSample, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, dataLength, Endian.little);

    return bytes;
  }

  Duration? _readPcmWavDuration(Uint8List bytes) {
    if (bytes.length < 44) return null;

    bool hasAsciiAt(int offset, String text) {
      if (offset < 0 || offset + text.length > bytes.length) return false;
      for (var index = 0; index < text.length; index++) {
        if (bytes[offset + index] != text.codeUnitAt(index)) return false;
      }
      return true;
    }

    if (!hasAsciiAt(0, 'RIFF') || !hasAsciiAt(8, 'WAVE')) return null;

    final data = ByteData.sublistView(bytes);
    final byteRate = data.getUint32(28, Endian.little);
    final dataSize = data.getUint32(40, Endian.little);

    if (byteRate <= 0 || dataSize <= 0) return null;

    final microseconds =
        (dataSize * Duration.microsecondsPerSecond) ~/ byteRate;
    return Duration(microseconds: microseconds);
  }

  Future<void> _waitForPcmDone() async {
    final done = _pcmDone;
    if (done == null || done.isCompleted) return;

    try {
      await done.future.timeout(const Duration(milliseconds: 600));
    } catch (_) {
      // Closing/cancelling below is still safe if a platform omits stream done.
    }
  }

  Future<void> _closePcmOutput() async {
    final subscription = _pcmSubscription;
    _pcmSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {
        // Best effort during teardown.
      }
    }

    final sink = _pcmSink;
    _pcmSink = null;
    if (sink != null) {
      try {
        await sink.flush();
      } catch (_) {
        // Best effort during teardown.
      }
      try {
        await sink.close();
      } catch (_) {
        // Best effort during teardown.
      }
    }

    _pcmDone = null;
  }

  Future<void> _deletePausedPreviewSnapshot() async {
    final path = _pausedPreviewSnapshotPath;
    _pausedPreviewSnapshotPath = null;

    if (path == null) return;
    await _deleteIfExists(path);
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Temporary capture cleanup is best-effort.
    }
  }

  void _assertUsable() {
    if (_disposed) {
      throw StateError('Audio service has been disposed');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _playerStateSubscription.cancel();
    await _positionSubscription.cancel();
    await _amplitudeSubscription?.cancel();

    try {
      if (await _recorder.isRecording()) {
        await _recorder.cancel();
      }
    } catch (_) {
      // Best effort during teardown.
    }

    await _waitForPcmDone();
    await _closePcmOutput();
    await _deletePausedPreviewSnapshot();

    final pcmPath = _activePcmPath;
    final wavPath = _activeCapturePath;
    if (pcmPath != null) await _deleteIfExists(pcmPath);
    if (wavPath != null) await _deleteIfExists(wavPath);
    _activePcmPath = null;
    _activeCapturePath = null;

    await _recorder.dispose();
    await _player.dispose();

    await _captureAmplitudeController.close();
    await _previewPositionController.close();
    await _previewPlayingController.close();
  }
}
