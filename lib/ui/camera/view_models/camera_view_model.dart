import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:wrytte/domain/models/camera_capture_result.dart';
import 'package:wrytte/domain/models/camera_failure.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';
import 'package:wrytte/domain/models/camera_session_state.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';

class CameraViewModel extends ChangeNotifier {
  CameraViewModel(
    this._repository, {
    required this.config,
    required this.keepSessionAliveOnExit,
  }) : _state = _repository.state {
    _subscription = _repository.states.listen(_onState);
  }

  final CameraRepository _repository;
  final CameraSessionConfig config;
  final bool keepSessionAliveOnExit;
  late final StreamSubscription<CameraSessionState> _subscription;

  CameraSessionState _state;
  bool _videoMode = false;
  bool _disposed = false;
  double _lastGestureScale = 1;
  double? _gestureZoom;
  bool _pinchActive = false;
  int _zoomGestureGeneration = 0;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;

  CameraSessionState get state => _state;
  bool get videoMode => _videoMode && config.supportsVideo;
  bool get showModePicker => config.supportsVideo;
  Duration get recordingDuration => _recordingDuration;
  CameraFailure? get failure => _state.failure;
  double get displayZoom => _gestureZoom ?? _state.zoom;

  Future<void> initialize() => _repository.open(config);

  void beginZoomGesture() {
    _zoomGestureGeneration++;
    _lastGestureScale = 1;
    _pinchActive = false;
  }

  void updateZoomGesture(double scale) {
    if (!_state.isReady || !scale.isFinite) return;
    if (!_pinchActive) {
      _pinchActive = true;
      _lastGestureScale = scale > 0 ? scale : 1;
      _gestureZoom = _state.zoom;
      notifyListeners();
      return;
    }
    final previousScale = _lastGestureScale.isFinite && _lastGestureScale > 0
        ? _lastGestureScale
        : 1.0;
    final currentScale = scale.isFinite && scale > 0 ? scale : 1.0;
    _lastGestureScale = currentScale;
    final capabilities = _state.capabilities;
    if (capabilities == null) return;
    final incrementalScale = currentScale / previousScale;
    final sensitiveScale = math.pow(incrementalScale, 1.65).toDouble();
    final target = (displayZoom * sensitiveScale)
        .clamp(capabilities.minimumZoom, capabilities.maximumZoom)
        .toDouble();
    if ((target - displayZoom).abs() < .002) return;
    _gestureZoom = target;
    notifyListeners();
    unawaited(_repository.setZoom(target));
  }

  Future<void> endZoomGesture() async {
    if (!_pinchActive) return;
    final generation = _zoomGestureGeneration;
    final target = displayZoom;
    _pinchActive = false;
    _lastGestureScale = 1;
    await _repository.setZoom(target);
    if (_disposed || generation != _zoomGestureGeneration) return;
    _gestureZoom = null;
    notifyListeners();
  }

  Future<void> setZoom(double zoom) {
    _zoomGestureGeneration++;
    _pinchActive = false;
    _gestureZoom = null;
    return _repository.setZoom(zoom);
  }

  Future<void> focus(double x, double y) =>
      _repository.setFocusAndExposurePoint(x, y);

  Future<void> switchCamera() => _repository.switchCamera();

  Future<void> cycleFlash() => _repository.cycleFlashMode();

  void selectPhotoMode() {
    if (!_videoMode) return;
    _videoMode = false;
    notifyListeners();
  }

  void selectVideoMode() {
    if (_videoMode || !config.supportsVideo) return;
    _videoMode = true;
    notifyListeners();
  }

  Future<CameraCaptureResult?> pressShutter() async {
    if (!_state.isReady && !_state.isRecording) return null;
    if (!videoMode) return _repository.takePhoto();
    if (_state.isRecording) {
      final result = await _repository.stopVideo();
      _stopRecordingClock();
      return result;
    }
    await _repository.startVideo();
    _startRecordingClock();
    return null;
  }

  Future<void> handleLifecyclePause() async {
    _stopRecordingClock();
    await _repository.interrupt();
  }

  Future<void> handleLifecycleResume() => _repository.resume();

  Future<void> release() async {
    if (!keepSessionAliveOnExit) await _repository.close();
  }

  void _onState(CameraSessionState value) {
    _state = value;
    if (!_disposed) notifyListeners();
  }

  void _startRecordingClock() {
    _recordingDuration = Duration.zero;
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordingDuration += const Duration(seconds: 1);
      if (!_disposed) notifyListeners();
    });
  }

  void _stopRecordingClock() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRecordingClock();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
