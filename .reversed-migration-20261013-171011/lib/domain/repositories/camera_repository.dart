import 'package:flutter/widgets.dart';
import 'package:wrytte/domain/models/camera_capture_result.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';
import 'package:wrytte/domain/models/camera_session_state.dart';

abstract interface class CameraRepository {
  CameraSessionState get state;
  Stream<CameraSessionState> get states;

  Future<void> open(CameraSessionConfig config);
  Future<void> close();
  Future<void> interrupt();
  Future<void> resume();
  Future<void> switchCamera();
  Future<CameraCaptureResult> takePhoto();
  Future<void> startVideo();
  Future<CameraCaptureResult> stopVideo();
  Future<void> pauseVideo();
  Future<void> resumeVideo();
  Future<void> setZoom(double zoom);
  Future<void> setFocusAndExposurePoint(double x, double y);
  Future<void> cycleFlashMode();
  Future<void> pausePreview();
  Future<void> resumePreview();

  Widget buildPreview({Key? key});
}
