import 'package:wrytte/domain/models/camera_capabilities.dart';
import 'package:wrytte/domain/models/camera_device.dart';
import 'package:wrytte/domain/models/camera_failure.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';

enum CameraSessionStatus {
  closed,
  opening,
  ready,
  capturing,
  recordingStarting,
  recording,
  recordingPaused,
  recordingStopping,
  interrupted,
  failure,
}

class CameraSessionState {
  const CameraSessionState({
    this.status = CameraSessionStatus.closed,
    this.devices = const <CameraDevice>[],
    this.activeDevice,
    this.capabilities,
    this.config,
    this.zoom = 1,
    this.flashMode = WrytteFlashMode.off,
    this.exposureOffset = 0,
    this.previewAspectRatio,
    this.failure,
  });

  final CameraSessionStatus status;
  final List<CameraDevice> devices;
  final CameraDevice? activeDevice;
  final CameraCapabilities? capabilities;
  final CameraSessionConfig? config;
  final double zoom;
  final WrytteFlashMode flashMode;
  final double exposureOffset;
  final double? previewAspectRatio;
  final CameraFailure? failure;

  bool get isReady => status == CameraSessionStatus.ready;
  bool get isRecording =>
      status == CameraSessionStatus.recording ||
      status == CameraSessionStatus.recordingPaused ||
      status == CameraSessionStatus.recordingStopping;

  CameraSessionState copyWith({
    CameraSessionStatus? status,
    List<CameraDevice>? devices,
    CameraDevice? activeDevice,
    CameraCapabilities? capabilities,
    CameraSessionConfig? config,
    double? zoom,
    WrytteFlashMode? flashMode,
    double? exposureOffset,
    double? previewAspectRatio,
    CameraFailure? failure,
    bool clearFailure = false,
  }) {
    return CameraSessionState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      activeDevice: activeDevice ?? this.activeDevice,
      capabilities: capabilities ?? this.capabilities,
      config: config ?? this.config,
      zoom: zoom ?? this.zoom,
      flashMode: flashMode ?? this.flashMode,
      exposureOffset: exposureOffset ?? this.exposureOffset,
      previewAspectRatio: previewAspectRatio ?? this.previewAspectRatio,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}
