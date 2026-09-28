enum CameraMediaType { photo, video }

class CameraCaptureResult {
  const CameraCaptureResult({
    required this.path,
    required this.type,
    required this.capturedAt,
    required this.cameraId,
    required this.zoom,
    this.duration,
  });

  final String path;
  final CameraMediaType type;
  final DateTime capturedAt;
  final String cameraId;
  final double zoom;
  final Duration? duration;
}
