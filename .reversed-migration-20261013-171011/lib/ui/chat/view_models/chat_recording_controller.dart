import 'dart:async';

import 'dart:io';

import 'dart:math' as math;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:wrytte/data/services/wav_audio_trimmer.dart';

import 'package:path_provider/path_provider.dart';

import 'package:pro_video_editor/pro_video_editor.dart' as pve;

import 'package:video_player/video_player.dart';

import 'package:wrytte/domain/models/camera_capabilities.dart';

import 'package:wrytte/domain/models/camera_capture_result.dart';

import 'package:wrytte/domain/models/camera_session_config.dart';

import 'package:wrytte/domain/models/camera_session_state.dart';

import 'package:wrytte/domain/models/media_trim_range.dart';

import 'package:wrytte/domain/models/voice_recording_result.dart';

import 'package:wrytte/domain/repositories/audio_recording_repository.dart';

import 'package:wrytte/domain/repositories/camera_repository.dart';

enum ChatRecordingKind { voice, roundVideo }

enum ChatRecordingPhase {

  idle,

  preparing,

  holding,

  locked,

  paused,

  reviewing,

  finalizing,

}

class _RecordingDragMetrics {
  const _RecordingDragMetrics({
    required this.cancelProgress,
    required this.lockProgress,
    required this.visualDx,
    required this.visualDy,
    required this.guideReached,
  });

  final double cancelProgress;
  final double lockProgress;
  final double visualDx;
  final double visualDy;
  final bool guideReached;

  bool get cancelOnRelease => cancelProgress >= .55;
}

class ChatRecordingController extends ChangeNotifier

    with WidgetsBindingObserver {

  ChatRecordingController({

    required this.audio,

    required this.camera,

    required this.onVoiceReady,

    required this.onVideoReady,

    this.onFailure,

  }) {

    WidgetsBinding.instance.addObserver(this);

    _amplitudeSubscription = audio.captureAmplitudes.listen(_addLevel);

    _previewPositionSubscription = audio.previewPositions.listen((position) {

      _previewPosition = position;

      if (!_disposed) notifyListeners();

    });

    _previewPlayingSubscription = audio.previewPlaying.listen((playing) {

      _previewPlaying = playing;

      if (!_disposed) notifyListeners();

    });

  }

  static const Duration maxRoundVideoDuration = Duration(seconds: 60);

  // The old composer used up to 32% of the logical screen width for the
  // horizontal cancel path, capped at 132 logical pixels.
  static const double cancelDistance = 132;

  // The old lock corridor reached the target at roughly 76 logical pixels.
  static const double lockDistance = 76;

  final AudioRecordingRepository audio;

  final CameraRepository camera;

  final ValueChanged<VoiceRecordingResult> onVoiceReady;

  final ValueChanged<CameraCaptureResult> onVideoReady;

  final ValueChanged<String>? onFailure;

  ChatRecordingPhase _phase = ChatRecordingPhase.idle;

  ChatRecordingKind _kind = ChatRecordingKind.voice;

  final Stopwatch _stopwatch = Stopwatch();

  Timer? _clock;

  StreamSubscription<double>? _amplitudeSubscription;

  StreamSubscription<Duration>? _previewPositionSubscription;

  StreamSubscription<bool>? _previewPlayingSubscription;

  final List<double> _levels = <double>[];

  final WavAudioTrimmer _audioTrimmer = const WavAudioTrimmer();

  Offset _pendingDrag = Offset.zero;

  bool _pointerReleasedWhilePreparing = false;

  bool _disposed = false;

  String? _voicePath;

  // Playable copy of the still-in-progress WAV used only while native capture
  // is paused. The real recorder session remains open and resumable.
  String? _pausedPreviewPath;

  CameraCaptureResult? _videoDraft;

  VideoPlayerController? _videoPreviewController;

  List<Uint8List> _videoThumbnailBytes = const <Uint8List>[];

  bool _videoPreviewPreparing = false;

  int _videoPreviewGeneration = 0;

  Duration _reviewDuration = Duration.zero;

  Duration _previewPosition = Duration.zero;

  bool _previewPlaying = false;

  bool _previewPreparing = false;

  Future<bool>? _previewPreparation;

  bool _pauseResumeInFlight = false;

  double _trimStart = 0;

  double _trimEnd = 1;

  ChatRecordingPhase get phase => _phase;

  ChatRecordingKind get kind => _kind;

  bool get active => _phase != ChatRecordingPhase.idle;

  // Presentation closes immediately when finalization starts. Native camera/
  // recorder cleanup can safely finish after the overlay has disappeared.
  bool get uiActive =>
      _phase != ChatRecordingPhase.idle &&
      _phase != ChatRecordingPhase.finalizing;

  bool get locked =>

      _phase == ChatRecordingPhase.locked ||

      _phase == ChatRecordingPhase.paused ||

      _phase == ChatRecordingPhase.reviewing;

  bool get paused => _phase == ChatRecordingPhase.paused;

  bool get reviewing => _phase == ChatRecordingPhase.reviewing;

  bool get pauseResumeBusy => _pauseResumeInFlight;

  bool get previewPlaying => _previewPlaying;

  bool get previewAvailable =>
      _kind == ChatRecordingKind.voice &&
      (reviewing || paused) &&
      !_pauseResumeInFlight;

  bool get previewPreparing => _previewPreparing;

  Duration get elapsed {
    if (reviewing) return _reviewDuration;
    if (paused &&
        _kind == ChatRecordingKind.roundVideo &&
        _reviewDuration > Duration.zero) {
      return _reviewDuration;
    }
    return _stopwatch.elapsed;
  }

  Duration get previewPosition => _previewPosition;

  List<double> get levels => List<double>.unmodifiable(_levels);

  _RecordingDragMetrics get _dragMetrics {
    final rawDx = _pendingDrag.dx;
    final rawDy = _pendingDrag.dy;

    final horizontalDistance = rawDx.abs();
    final leftDistance = (-rawDx).clamp(0.0, double.infinity).toDouble();
    final upwardDistance = (-rawDy).clamp(0.0, double.infinity).toDouble();
    final downwardDistance = rawDy.clamp(0.0, double.infinity).toDouble();

    final effectiveCancelDistance = _effectiveCancelDistance;

    final horizontalCancelProgress =
        (leftDistance / effectiveCancelDistance).clamp(0.0, 1.0).toDouble();

    final lockCorridorWidth =
        (effectiveCancelDistance * .16).clamp(16.0, 23.0).toDouble();

    final lockAllowed =
        horizontalCancelProgress < .30 &&
        rawDy < 0 &&
        horizontalDistance <= lockCorridorWidth;

    final isTopLeftDiagonal =
        rawDx < -14 &&
        rawDy < -12 &&
        !lockAllowed &&
        leftDistance >= upwardDistance * .55;

    final diagonalDistance = Offset(leftDistance, upwardDistance).distance;
    final diagonalCancelLimit = effectiveCancelDistance * .78;

    final diagonalCancelProgress = isTopLeftDiagonal
        ? (diagonalDistance / diagonalCancelLimit).clamp(0.0, 1.0).toDouble()
        : 0.0;

    final isUpperDiagonal =
        upwardDistance > 8 && horizontalDistance > lockCorridorWidth;

    const lowerCancelDistance = 28.0;

    final isInLowerCancelSector = rawDy > 0 && rawDx <= 10;

    final lowerCancelProgressRaw = isInLowerCancelSector
        ? Offset(
            leftDistance / effectiveCancelDistance,
            downwardDistance / lowerCancelDistance,
          ).distance
        : 0.0;

    final lowerCancelProgress =
        lowerCancelProgressRaw.clamp(0.0, 1.0).toDouble();

    final cancelProgress =
        (rawDy > 0
                ? lowerCancelProgress
                : isUpperDiagonal
                ? diagonalCancelProgress
                : horizontalCancelProgress)
            .toDouble();

    final lockProgress = lockAllowed
        ? (upwardDistance / lockDistance).clamp(0.0, 1.0).toDouble()
        : 0.0;

    final guideReached = lockAllowed && lockProgress >= .98;

    final diagonalEndpointFactor =
        isTopLeftDiagonal && diagonalDistance > diagonalCancelLimit
        ? diagonalCancelLimit / diagonalDistance
        : 1.0;

    final lowerEndpointFactor =
        lowerCancelProgressRaw > 1 ? 1 / lowerCancelProgressRaw : 1.0;

    final endpointFactor =
        rawDy > 0 ? lowerEndpointFactor : diagonalEndpointFactor;

    final visualDx =
        (leftDistance * endpointFactor)
            .clamp(0.0, effectiveCancelDistance)
            .toDouble();

    final visualDy = lockAllowed
        ? -(19.5 * lockProgress)
        : (rawDy * endpointFactor).clamp(-22.0, 24.0).toDouble();

    return _RecordingDragMetrics(
      cancelProgress: cancelProgress,
      lockProgress: lockProgress,
      visualDx: visualDx,
      visualDy: visualDy,
      guideReached: guideReached,
    );
  }

  double get _effectiveCancelDistance {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return cancelDistance;

    final view = views.first;
    final ratio = view.devicePixelRatio;
    if (ratio <= 0) return cancelDistance;

    final logicalWidth = view.physicalSize.width / ratio;
    return (logicalWidth * .32).clamp(1.0, cancelDistance).toDouble();
  }

  double get cancelProgress => _dragMetrics.cancelProgress;

  double get lockProgress => _dragMetrics.lockProgress;

  bool get cancelOnRelease => _dragMetrics.cancelOnRelease;

  Offset get visualDragOffset {
    final metrics = _dragMetrics;
    return Offset(-metrics.visualDx, metrics.visualDy);
  }

  double get trimStart => _trimStart;

  double get trimEnd => _trimEnd;

  CameraSessionState get cameraState => camera.state;

  String? get reviewVideoPath => _videoDraft?.path;

  VideoPlayerController? get videoPreviewController => _videoPreviewController;

  List<Uint8List> get videoThumbnailBytes =>
      List<Uint8List>.unmodifiable(_videoThumbnailBytes);

  bool get videoPreviewPreparing => _videoPreviewPreparing;

  bool get videoPreviewReady =>
      _videoPreviewController?.value.isInitialized == true;

  Widget buildCameraPreview({Key? key}) => camera.buildPreview(key: key);

  double get videoMinimumZoom => cameraState.capabilities?.minimumZoom ?? 1.0;

  double get videoMaximumZoom =>
      cameraState.capabilities?.maximumZoom ?? videoMinimumZoom;

  bool get canSwitchVideoCamera {
    final current = cameraState.activeDevice;
    if (current == null) return false;

    return cameraState.devices.any(
      (device) => device.facing != current.facing,
    );
  }

  bool get canUseVideoFlash =>
      cameraState.activeDevice?.isBack == true &&
      cameraState.capabilities?.flashAvailable == true;

  bool get videoFlashEnabled =>
      cameraState.flashMode == WrytteFlashMode.torch ||
      cameraState.flashMode == WrytteFlashMode.always;

  Future<void> setVideoZoom(double value) async {
    await camera.setZoom(
      value.clamp(videoMinimumZoom, videoMaximumZoom).toDouble(),
    );
    if (!_disposed) notifyListeners();
  }

  Future<void> switchVideoCamera() async {
    await camera.switchCamera();
    if (!_disposed) notifyListeners();
  }

  Future<void> toggleVideoFlash() async {
    await camera.cycleFlashMode();
    if (!_disposed) notifyListeners();
  }

  Future<void> begin(ChatRecordingKind nextKind) async {

    if (_phase != ChatRecordingPhase.idle) return;

    _kind = nextKind;

    _phase = ChatRecordingPhase.preparing;

    _pendingDrag = Offset.zero;

    _pointerReleasedWhilePreparing = false;

    _levels.clear();

    _trimStart = 0;

    _trimEnd = 1;

    notifyListeners();

    try {

      if (nextKind == ChatRecordingKind.voice) {

        final granted = await audio.hasCapturePermission();

        if (!granted) {

          _fail('Microphone access is needed to record a voice message.');

          return;

        }

        await audio.startCapture();

      } else {

        await camera.open(

          const CameraSessionConfig(

            purpose: CameraPurpose.generic,

            captureMode: CameraCaptureMode.photoAndVideo,

            enableAudio: true,

            resolution: CameraResolution.medium,

            preferredFacing: CameraFacingPreference.front,

            framesPerSecond: 24,

            videoBitrate: 1800000,

            audioBitrate: 64000,

          ),

        );

        await camera.startVideo();

      }

      if (_disposed || _phase != ChatRecordingPhase.preparing) return;

      _stopwatch

        ..reset()

        ..start();

      _phase = _pointerReleasedWhilePreparing

          ? ChatRecordingPhase.locked

          : ChatRecordingPhase.holding;

      _startClock();

      _applyPendingGesture();

      notifyListeners();

    } catch (error) {

      await _discardNativeCapture();

      _fail(

        nextKind == ChatRecordingKind.voice

            ? 'Voice recording could not start.'

            : 'Camera and microphone access are needed for a video message.',

      );

    }

  }

  void updateDrag(Offset offsetFromOrigin) {

    if (_phase == ChatRecordingPhase.idle || locked) return;

    _pendingDrag = offsetFromOrigin;

    if (_phase == ChatRecordingPhase.preparing) {

      notifyListeners();

      return;

    }

    _applyPendingGesture();

    notifyListeners();

  }

  void _applyPendingGesture() {
    if (_phase != ChatRecordingPhase.holding) return;

    final metrics = _dragMetrics;

    // Old behavior: reaching the end of the cancel path cancels immediately.
    if (metrics.cancelProgress >= 1) {
      unawaited(cancel());
      return;
    }

    // Old behavior: upward lock only works inside the narrow vertical corridor.
    // Once the guide is reached, snap the moving action back to its home
    // position while the lock guide morphs into the pause control.
    if (metrics.guideReached) {
      _phase = ChatRecordingPhase.locked;
      _pendingDrag = Offset.zero;
      notifyListeners();
    }
  }

  Future<void> releaseHold() async {

    if (_phase == ChatRecordingPhase.preparing) {

      // A permission sheet/native startup consumes the original pointer. Keep

      // the successful recording instead of silently sending or discarding it.

      _pointerReleasedWhilePreparing = true;

      return;

    }

    if (_phase == ChatRecordingPhase.holding) {
      // The old composer armed cancellation once the drag passed 55% even if
      // the user released before reaching the hard 100% cancel endpoint.
      if (cancelOnRelease) {
        await cancel();
      } else {
        await send();
      }
    }

  }

  Future<void> pauseLockedRecording() async {

    if (_phase != ChatRecordingPhase.locked || _pauseResumeInFlight) return;

    // Voice recording uses the record package's real native pause operation.
    // The same recording session remains alive and can later be resumed.
    if (_kind == ChatRecordingKind.voice) {
      _pauseResumeInFlight = true;
      notifyListeners();

      try {
        await audio.pauseCapture();

        _clock?.cancel();
        _clock = null;
        _stopwatch.stop();

        _trimStart = 0;
        _trimEnd = 1;
        _previewPosition = Duration.zero;
        _previewPlaying = false;
        _pausedPreviewPath = null;

        _phase = ChatRecordingPhase.paused;
        if (!_disposed) notifyListeners();
      } catch (_) {
        onFailure?.call('Voice recording could not be paused.');
        return;
      } finally {
        _pauseResumeInFlight = false;
        if (!_disposed) notifyListeners();
      }

      // Preparing the playback snapshot is intentionally separate from the
      // native pause operation. If snapshot preparation fails, the recording
      // is still correctly paused and tapping Play can retry preparation.
      await _ensurePausedVoicePreview();

      return;
    }

    // Old Wrytte round-video pause behavior intentionally FINALIZES the
    // currently-recording clip. A finalized file is required to generate real
    // frame thumbnails and a scrub-able paused preview.
    _pauseResumeInFlight = true;
    notifyListeners();

    try {
      _clock?.cancel();
      _clock = null;
      _stopwatch.stop();

      // Update presentation FIRST. The old UI switched to the paused filmstrip
      // immediately while native finalization continued underneath.
      _trimStart = 0;
      _trimEnd = 1;
      _previewPosition = Duration.zero;
      _previewPlaying = false;
      _videoThumbnailBytes = const <Uint8List>[];
      _phase = ChatRecordingPhase.paused;

      if (!_disposed) notifyListeners();

      final segment = await camera.stopVideo();
      _videoDraft = await _mergeVideoDraft(segment);

      if (!_disposed) notifyListeners();

      // Thumbnails/player preparation can take longer than native finalization.
      // Do it in the background; the filmstrip already shows its old dark
      // placeholders and becomes populated as frames arrive.
      unawaited(_preparePausedVideoAssets());
    } catch (_) {
      // If native finalization failed and the camera is still recording, return
      // to the locked live state instead of leaving a dead paused UI.
      if (camera.state.isRecording) {
        _phase = ChatRecordingPhase.locked;
        _stopwatch.start();
        _startClock();
      }
      onFailure?.call('Video recording could not be paused.');
    } finally {
      _pauseResumeInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> resumeLockedRecording() async {
    if (_phase != ChatRecordingPhase.paused || _pauseResumeInFlight) {
      return;
    }

    _pauseResumeInFlight = true;
    notifyListeners();

    try {
      if (_kind == ChatRecordingKind.voice) {
        await audio.stopPreview();
        _previewPlaying = false;
        _previewPosition = Duration.zero;

        await audio.resumeCapture();
        _pausedPreviewPath = null;
        _previewPreparing = false;
        _previewPreparation = null;

        // Once capture continues the duration/waveform can grow again, so any
        // paused trim selection no longer describes the full recording.
        _trimStart = 0;
        _trimEnd = 1;
      } else {
        // A paused round-video is a finalized clip so its real frames can be
        // trimmed. Resume starts a fresh capture segment while preserving the
        // finalized draft; Send merges the segments back together.
        await _disposeVideoPreview();
        _videoThumbnailBytes = const <Uint8List>[];
        _previewPosition = Duration.zero;
        _previewPlaying = false;
        _trimStart = 0;
        _trimEnd = 1;

        await camera.startVideo();
      }

      _phase = ChatRecordingPhase.locked;
      _stopwatch.start();
      _startClock();
    } catch (_) {
      onFailure?.call(
        _kind == ChatRecordingKind.voice
            ? 'Voice recording could not be resumed.'
            : 'Video recording could not be resumed.',
      );
    } finally {
      _pauseResumeInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _finalizeToReview() async {

    if (_phase != ChatRecordingPhase.locked) return;

    _clock?.cancel();
    _clock = null;

    _stopwatch.stop();

    _reviewDuration = _stopwatch.elapsed;

    if (_kind == ChatRecordingKind.voice) {

      _voicePath = await audio.stopCapture();

      final path = _voicePath;

      if (path == null || path.isEmpty) {

        _fail('Voice recording could not be saved.');

        return;

      }

      await audio.preparePreview(

        path,

        range: MediaTrimRange.full(_reviewDuration),

      );

    } else {

      _videoDraft = await camera.stopVideo();

    }

    _phase = ChatRecordingPhase.reviewing;

    notifyListeners();

  }

  Future<void> togglePreview() async {
    if (_kind != ChatRecordingKind.voice || (!paused && !reviewing)) return;

    try {
      if (_previewPlaying) {
        await audio.pausePreview();
        return;
      }

      if (paused) {
        final ready = await _ensurePausedVoicePreview();
        if (!ready) {
          onFailure?.call('Voice preview is not ready yet. Tap Play to retry.');
          return;
        }
      }

      await audio.playPreview();
    } catch (_) {
      _previewPlaying = false;
      if (!_disposed) notifyListeners();
      onFailure?.call('Voice preview could not be played.');
    }
  }

  Future<bool> _ensurePausedVoicePreview() {
    if (_kind != ChatRecordingKind.voice || !paused) {
      return Future<bool>.value(false);
    }

    if (_pausedPreviewPath != null && _pausedPreviewPath!.isNotEmpty) {
      return Future<bool>.value(true);
    }

    // A tap can arrive while the automatic pause-time preparation is still
    // running. Reuse that same Future instead of treating the tap as a failure.
    final existing = _previewPreparation;
    if (existing != null) return existing;

    final future = _preparePausedVoicePreview();
    _previewPreparation = future;

    return future.whenComplete(() {
      if (identical(_previewPreparation, future)) {
        _previewPreparation = null;
      }
    });
  }

  Future<bool> _preparePausedVoicePreview() async {
    _previewPreparing = true;
    if (!_disposed) notifyListeners();

    try {
      final previewPath = await audio.createPausedCapturePreview();
      if (previewPath == null || previewPath.isEmpty) return false;

      await audio.preparePreview(
        previewPath,
        range: MediaTrimRange.full(_stopwatch.elapsed),
      );

      if (!paused || _disposed) {
        await audio.stopPreview();
        return false;
      }

      _pausedPreviewPath = previewPath;
      _previewPosition = Duration.zero;
      return true;
    } catch (_) {
      _pausedPreviewPath = null;
      _previewPlaying = false;
      try {
        await audio.stopPreview();
      } catch (_) {
        // Preview cleanup is best effort.
      }
      return false;
    } finally {
      _previewPreparing = false;
      if (!_disposed) notifyListeners();
    }
  }


  Future<CameraCaptureResult> _mergeVideoDraft(
    CameraCaptureResult segment,
  ) async {
    final previous = _videoDraft;
    final totalDuration = _stopwatch.elapsed;

    if (previous == null) {
      return CameraCaptureResult(
        path: segment.path,
        type: segment.type,
        capturedAt: segment.capturedAt,
        cameraId: segment.cameraId,
        zoom: segment.zoom,
        duration: totalDuration,
      );
    }

    final mergedPath = await _mergeVideoFiles(
      <String>[previous.path, segment.path],
    );

    await _delete(previous.path);
    await _delete(segment.path);

    return CameraCaptureResult(
      path: mergedPath,
      type: segment.type,
      capturedAt: previous.capturedAt,
      cameraId: segment.cameraId,
      zoom: segment.zoom,
      duration: totalDuration,
    );
  }

  Future<String> _mergeVideoFiles(List<String> paths) async {
    if (paths.length == 1) return paths.first;

    final directory = await getTemporaryDirectory();
    final output =
        '${directory.path}${Platform.pathSeparator}wrytte_round_video_merge_${DateTime.now().microsecondsSinceEpoch}.mp4';

    return pve.ProVideoEditor.instance.renderVideoToFile(
      output,
      pve.VideoRenderData(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        videoSegments: paths
            .map(
              (path) => pve.VideoSegment(
                video: pve.EditorVideo.file(path),
              ),
            )
            .toList(growable: false),
        enableAudio: true,
        outputFormat: pve.VideoOutputFormat.mp4,
      ),
    );
  }

  Future<void> _preparePausedVideoAssets() async {
    final draft = _videoDraft;
    if (_kind != ChatRecordingKind.roundVideo ||
        !paused ||
        draft == null ||
        draft.path.isEmpty) {
      return;
    }

    final generation = ++_videoPreviewGeneration;
    _videoPreviewPreparing = true;
    _videoThumbnailBytes = const <Uint8List>[];
    if (!_disposed) notifyListeners();

    try {
      await Future.wait<void>([
        _preparePausedVideoPreview(draft.path, generation),
        _loadPausedVideoThumbnails(draft.path, generation),
      ]);
    } finally {
      if (generation == _videoPreviewGeneration) {
        _videoPreviewPreparing = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> _preparePausedVideoPreview(
    String path,
    int generation,
  ) async {
    await _disposeVideoPreview();

    final controller = VideoPlayerController.file(File(path));
    _videoPreviewController = controller;
    controller.addListener(_syncPausedVideoPreview);

    try {
      await controller.initialize();
      await controller.setLooping(false);
      await controller.setVolume(1);

      if (_disposed ||
          generation != _videoPreviewGeneration ||
          !paused ||
          _videoDraft?.path != path) {
        controller.removeListener(_syncPausedVideoPreview);
        await controller.dispose();
        if (identical(_videoPreviewController, controller)) {
          _videoPreviewController = null;
        }
        return;
      }

      final encodedDuration = controller.value.duration;
      if (encodedDuration > Duration.zero) {
        _reviewDuration = encodedDuration;
      } else {
        _reviewDuration = _stopwatch.elapsed;
      }

      final start = trimRange.start;
      await controller.seekTo(start);
      _previewPosition = start;
      await controller.play();
      _previewPlaying = true;

      if (!_disposed) notifyListeners();
    } catch (_) {
      if (identical(_videoPreviewController, controller)) {
        _videoPreviewController = null;
      }
      controller.removeListener(_syncPausedVideoPreview);
      await controller.dispose();
      _previewPlaying = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _loadPausedVideoThumbnails(
    String path,
    int generation,
  ) async {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      final logicalWidth = views.isEmpty
          ? 360.0
          : views.first.physicalSize.width / views.first.devicePixelRatio;
      final devicePixelRatio =
          views.isEmpty ? 1.0 : views.first.devicePixelRatio;

      final frameCount = (logicalWidth / 42).ceil().clamp(7, 12).toInt();
      final frameWidth = math.max(
        56.0,
        (logicalWidth / frameCount) * devicePixelRatio,
      );
      final frameHeight = math.max(56.0, 40.0 * devicePixelRatio);

      var frames = await pve.ProVideoEditor.instance.getKeyFrames(
        pve.KeyFramesConfigs(
          video: pve.EditorVideo.file(path),
          outputSize: Size(frameWidth, frameHeight),
          boxFit: pve.ThumbnailBoxFit.cover,
          maxOutputFrames: frameCount,
          outputFormat: pve.ThumbnailFormat.jpeg,
        ),
      );

      // A quiet/static clip can have very few keyframes. Fill the old filmstrip
      // with evenly-spaced real frames so it never looks empty.
      if (frames.length < math.min(5, frameCount)) {
        final total = elapsed;
        final timestamps = <Duration>[
          for (var index = 0; index < frameCount; index++)
            Duration(
              microseconds: total.inMicroseconds <= 0
                  ? 0
                  : ((total.inMicroseconds * index) /
                          math.max(1, frameCount - 1))
                      .round(),
            ),
        ];

        frames = await pve.ProVideoEditor.instance.getThumbnails(
          pve.ThumbnailConfigs(
            video: pve.EditorVideo.file(path),
            outputSize: Size(frameWidth, frameHeight),
            boxFit: pve.ThumbnailBoxFit.cover,
            timestamps: timestamps,
            outputFormat: pve.ThumbnailFormat.jpeg,
          ),
        );
      }

      if (_disposed ||
          generation != _videoPreviewGeneration ||
          !paused ||
          _videoDraft?.path != path ||
          frames.isEmpty) {
        return;
      }

      _videoThumbnailBytes = List<Uint8List>.unmodifiable(frames);
      notifyListeners();
    } catch (_) {
      // The old UI shows dark frame placeholders until thumbnails are ready.
      // Keep the editor functional even if thumbnail extraction fails.
    }
  }

  void _syncPausedVideoPreview() {
    final controller = _videoPreviewController;
    if (controller == null ||
        !controller.value.isInitialized ||
        _kind != ChatRecordingKind.roundVideo ||
        !paused) {
      return;
    }

    final position = controller.value.position;
    final range = trimRange;

    if (controller.value.isPlaying &&
        range.end > range.start &&
        position >= range.end) {
      unawaited(_loopPausedVideoPreview(range.start));
      return;
    }

    final changed =
        position != _previewPosition ||
        controller.value.isPlaying != _previewPlaying;

    _previewPosition = position;
    _previewPlaying = controller.value.isPlaying;

    if (changed && !_disposed) notifyListeners();
  }

  Future<void> _loopPausedVideoPreview(Duration position) async {
    final controller = _videoPreviewController;
    if (controller == null || !controller.value.isInitialized || !paused) {
      return;
    }

    await controller.seekTo(position);
    if (paused) await controller.play();
  }

  Future<void> seekVideoPreview(Duration position) async {
    if (_kind != ChatRecordingKind.roundVideo || !paused) return;

    final controller = _videoPreviewController;
    if (controller == null || !controller.value.isInitialized) return;

    final range = trimRange;
    final safePosition = Duration(
      microseconds: position.inMicroseconds
          .clamp(range.start.inMicroseconds, range.end.inMicroseconds)
          .toInt(),
    );

    _previewPosition = safePosition;
    if (!_disposed) notifyListeners();

    await controller.seekTo(safePosition);
  }

  Future<void> playVideoPreview() async {
    if (_kind != ChatRecordingKind.roundVideo || !paused) return;

    final controller = _videoPreviewController;
    if (controller == null || !controller.value.isInitialized) return;

    final range = trimRange;
    if (controller.value.position < range.start ||
        controller.value.position >= range.end) {
      await controller.seekTo(range.start);
    }

    await controller.play();
  }

  Future<void> _disposeVideoPreview() async {
    final controller = _videoPreviewController;
    _videoPreviewController = null;

    if (controller == null) return;

    controller.removeListener(_syncPausedVideoPreview);
    try {
      await controller.pause();
    } catch (_) {}
    await controller.dispose();

    _previewPlaying = false;
  }

  Future<void> updateTrim(double start, double end) async {

    if (!paused && !reviewing) return;

    if (_kind == ChatRecordingKind.roundVideo) {
      final durationMs = math.max(1, elapsed.inMilliseconds).toDouble();
      final minimumFraction = math.min(1.0, 100 / durationMs).toDouble();

      final normalizedStart = start.clamp(0.0, 1.0).toDouble();
      final normalizedEnd = end.clamp(0.0, 1.0).toDouble();

      _trimStart = math
          .min(normalizedStart, math.max(0.0, normalizedEnd - minimumFraction))
          .toDouble();
      _trimEnd = math
          .max(normalizedEnd, math.min(1.0, _trimStart + minimumFraction))
          .toDouble();

      notifyListeners();
      return;
    }

    // Voice uses the old waveform editor's small proportional minimum range.
    final normalizedStart = start.clamp(0.0, .98).toDouble();
    final normalizedEnd = end.clamp(normalizedStart + .02, 1.0).toDouble();

    _trimStart = normalizedStart;
    _trimEnd = normalizedEnd;

    notifyListeners();

  }

  Future<void> commitTrim() async {

    if (!paused && !reviewing) return;
    if (_kind != ChatRecordingKind.voice) return;

    final path = paused ? _pausedPreviewPath : _voicePath;
    if (path == null || path.isEmpty) return;

    final range = trimRange;
    final wasPlaying = _previewPlaying;

    await audio.preparePreview(path, range: range);
    _previewPosition = range.start;

    if (wasPlaying) {
      await audio.playPreview();
    }

    if (!_disposed) notifyListeners();
  }

  Future<void> seekPreviewFraction(
    double fraction, {
    bool commit = true,
  }) async {
    if (_kind != ChatRecordingKind.voice || (!paused && !reviewing)) return;

    final safeFraction = fraction.clamp(_trimStart, _trimEnd).toDouble();
    final position = _durationAt(safeFraction);

    _previewPosition = position;
    if (!_disposed) notifyListeners();

    if (!commit) return;

    final pathReady = reviewing || _pausedPreviewPath != null;
    if (!pathReady) return;

    await audio.seekPreview(position);
  }

  MediaTrimRange get trimRange => MediaTrimRange(

    start: _durationAt(_trimStart),

    end: _durationAt(_trimEnd),

  );

  Duration _durationAt(double fraction) =>

      Duration(microseconds: (elapsed.inMicroseconds * fraction).round());

  Future<void> send() async {

    if (_phase != ChatRecordingPhase.holding &&

        _phase != ChatRecordingPhase.locked &&

        _phase != ChatRecordingPhase.paused &&

        _phase != ChatRecordingPhase.reviewing) {

      return;

    }

    final wasPaused = _phase == ChatRecordingPhase.paused;
    final wasReviewing = _phase == ChatRecordingPhase.reviewing;
    final shouldApplyVoiceTrim =
        _kind == ChatRecordingKind.voice && (wasPaused || wasReviewing);
    final shouldApplyVideoTrim =
        _kind == ChatRecordingKind.roundVideo && (wasPaused || wasReviewing);

    _phase = ChatRecordingPhase.finalizing;

    _clock?.cancel();

    _stopwatch.stop();

    notifyListeners();

    try {

      if (_kind == ChatRecordingKind.voice) {

        var path = _voicePath ?? await audio.stopCapture();

        final duration = wasReviewing ? _reviewDuration : _stopwatch.elapsed;

        if (path == null ||

            path.isEmpty ||

            duration < const Duration(seconds: 1)) {

          if (path != null) await _delete(path);

        } else {

          final range = shouldApplyVoiceTrim
              ? trimRange
              : MediaTrimRange.full(duration);

          if (shouldApplyVoiceTrim && !range.isFullDuration(duration)) {

            final sourcePath = path;

            path = await _audioTrimmer.trim(

              sourcePath,

              startFraction: _trimStart,

              endFraction: _trimEnd,

            );

            if (path != sourcePath) await _delete(sourcePath);

          }

          onVoiceReady(

            VoiceRecordingResult(

              path: path,

              duration: range.duration,

              waveform: List<double>.unmodifiable(
                _waveformForRange(
                  shouldApplyVoiceTrim ? _trimStart : 0,
                  shouldApplyVoiceTrim ? _trimEnd : 1,
                ),
              ),

              trimRange: MediaTrimRange.full(range.duration),

            ),

          );

        }

      } else {

        CameraCaptureResult result;

        if (wasPaused || wasReviewing) {
          final draft = _videoDraft;
          if (draft == null) {
            throw StateError('Paused video draft is missing.');
          }
          result = draft;
        } else {
          final segment = await camera.stopVideo();
          result = await _mergeVideoDraft(segment);
          _videoDraft = result;
        }

        final duration = result.duration ?? _stopwatch.elapsed;

        if (duration < const Duration(seconds: 1)) {

          await _delete(result.path);

        } else {

          var outputPath = result.path;

          var outputDuration = duration > maxRoundVideoDuration

              ? maxRoundVideoDuration

              : duration;

          final range = shouldApplyVideoTrim

              ? trimRange

              : MediaTrimRange.full(outputDuration);

          if (shouldApplyVideoTrim && !range.isFullDuration(outputDuration)) {

            outputPath = await _trimVideo(

              result.path,

              start: range.start,

              end: range.end,

            );

            outputDuration = range.duration;

            if (outputPath != result.path) await _delete(result.path);

          }

          onVideoReady(

            CameraCaptureResult(

              path: outputPath,

              type: result.type,

              capturedAt: result.capturedAt,

              cameraId: result.cameraId,

              zoom: result.zoom,

              duration: outputDuration,

            ),

          );

        }

      }

    } catch (_) {

      _fail('The recording could not be completed.');

      return;

    } finally {

      await _releaseMedia();

    }

    _reset();

  }

  Future<void> cancel() async {

    if (_phase == ChatRecordingPhase.idle) return;

    _phase = ChatRecordingPhase.finalizing;

    notifyListeners();

    await _discardNativeCapture();

    await _releaseMedia();

    _reset();

  }

  void _startClock() {

    _clock?.cancel();

    _clock = Timer.periodic(const Duration(milliseconds: 80), (_) {

      if (_disposed) return;

      if (_kind == ChatRecordingKind.roundVideo &&

          _stopwatch.elapsed >= maxRoundVideoDuration) {

        unawaited(send());

        return;

      }

      notifyListeners();

    });

  }

  void _addLevel(double level) {

    if (_kind != ChatRecordingKind.voice ||

        (_phase != ChatRecordingPhase.holding &&

            _phase != ChatRecordingPhase.locked)) {

      return;

    }

    final previous = _levels.isEmpty ? .05 : _levels.last;

    _levels.add((previous * .42 + level * .58).clamp(.03, 1.0));

    if (_levels.length > 180) _levels.removeAt(0);

    if (!_disposed) notifyListeners();

  }

  List<double> _waveformForRange(double start, double end) {
    if (_levels.isEmpty) return const <double>[];

    final safeStart = start.clamp(0.0, 1.0).toDouble();
    final safeEnd = end.clamp(safeStart, 1.0).toDouble();

    final first = (safeStart * _levels.length)
        .floor()
        .clamp(0, _levels.length - 1)
        .toInt();
    final last = (safeEnd * _levels.length)
        .ceil()
        .clamp(first + 1, _levels.length)
        .toInt();

    return List<double>.of(_levels.sublist(first, last));
  }

  Future<void> _discardNativeCapture() async {

    try {

      if (_kind == ChatRecordingKind.voice) {

        await audio.stopPreview();

        if (_voicePath != null) {

          await _delete(_voicePath!);

        } else {

          await audio.cancelCapture();

        }

      } else {

        if (camera.state.isRecording) {
          final result = await camera.stopVideo();
          await _delete(result.path);
        }

        final draft = _videoDraft;
        if (draft != null) {
          await _delete(draft.path);
        }

      }

    } catch (_) {}

  }

  Future<void> _releaseMedia() async {

    try {

      await audio.stopPreview();

    } catch (_) {}

    if (_kind == ChatRecordingKind.roundVideo) {

      try {

        await _disposeVideoPreview();

      } catch (_) {}

      try {

        await camera.close();

      } catch (_) {}

    }

  }

  void _fail(String message) {

    _clock?.cancel();

    _stopwatch

      ..stop()

      ..reset();

    _phase = ChatRecordingPhase.idle;

    _pendingDrag = Offset.zero;

    _pausedPreviewPath = null;
    _previewPreparing = false;
    _previewPreparation = null;
    _videoThumbnailBytes = const <Uint8List>[];
    _videoPreviewPreparing = false;
    _videoPreviewGeneration++;
    unawaited(_disposeVideoPreview());

    onFailure?.call(message);

    if (!_disposed) notifyListeners();

  }

  void _reset() {

    _clock?.cancel();

    _stopwatch

      ..stop()

      ..reset();

    _phase = ChatRecordingPhase.idle;

    _pendingDrag = Offset.zero;

    _voicePath = null;

    _pausedPreviewPath = null;

    _videoDraft = null;

    _videoThumbnailBytes = const <Uint8List>[];

    _videoPreviewPreparing = false;

    _videoPreviewGeneration++;

    _reviewDuration = Duration.zero;

    _previewPosition = Duration.zero;

    _previewPlaying = false;

    _previewPreparing = false;

    _previewPreparation = null;

    _pauseResumeInFlight = false;

    _trimStart = 0;

    _trimEnd = 1;

    _levels.clear();

    if (!_disposed) notifyListeners();

  }

  Future<void> _delete(String path) async {

    try {

      final file = File(path);

      if (await file.exists()) await file.delete();

    } catch (_) {}

  }

  Future<String> _trimVideo(

    String path, {

    required Duration start,

    required Duration end,

  }) async {

    final source = pve.EditorVideo.file(path);

    final metadata = await pve.ProVideoEditor.instance.getMetadata(source);

    final directory = await getTemporaryDirectory();

    final output =

        '${directory.path}${Platform.pathSeparator}wrytte_round_video_${DateTime.now().microsecondsSinceEpoch}.mp4';

    return pve.ProVideoEditor.instance.renderVideoToFile(

      output,

      pve.VideoRenderData(

        id: DateTime.now().microsecondsSinceEpoch.toString(),

        videoSegments: [pve.VideoSegment(video: source)],

        startTime: start,

        endTime: end,

        enableAudio: true,

        outputFormat: pve.VideoOutputFormat.mp4,

        bitrate: metadata.bitrate,

      ),

    );

  }

  @override

  void didChangeAppLifecycleState(AppLifecycleState state) {

    // Android permission sheets may temporarily pause the activity. Preserve

    // the preparing operation so the first granted hold returns locked.

    if (state == AppLifecycleState.paused &&

        _phase == ChatRecordingPhase.preparing) {

      _pointerReleasedWhilePreparing = true;

      return;

    }

    if (state == AppLifecycleState.paused ||

        state == AppLifecycleState.detached) {

      unawaited(cancel());

    }

  }

  @override

  void dispose() {

    _disposed = true;

    WidgetsBinding.instance.removeObserver(this);

    _clock?.cancel();

    unawaited(_amplitudeSubscription?.cancel());

    unawaited(_previewPositionSubscription?.cancel());

    unawaited(_previewPlayingSubscription?.cancel());

    unawaited(_disposeVideoPreview());

    if (_phase != ChatRecordingPhase.idle) unawaited(_discardNativeCapture());

    super.dispose();

  }

}