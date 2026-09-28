import 'package:wrytte/domain/models/camera_capture_result.dart';

enum CameraRouteAction { captured, returnToGallery }

class CameraRouteResult {
  const CameraRouteResult.capture(this.capture)
    : action = CameraRouteAction.captured;

  const CameraRouteResult.returnToGallery()
    : action = CameraRouteAction.returnToGallery,
      capture = null;

  final CameraRouteAction action;
  final CameraCaptureResult? capture;
}
