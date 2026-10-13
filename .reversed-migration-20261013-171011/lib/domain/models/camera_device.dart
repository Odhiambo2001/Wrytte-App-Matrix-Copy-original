enum CameraFacing { front, back, external }

enum CameraLensRole { ultraWide, wide, telephoto, front, unknown }

class CameraDevice {
  const CameraDevice({
    required this.id,
    required this.facing,
    required this.sensorOrientation,
    required this.lensRole,
    this.intrinsicZoomRatio = 1,
    this.isLogicalCamera = false,
    this.physicalCameraIds = const <String>[],
  });

  final String id;
  final CameraFacing facing;
  final int sensorOrientation;
  final CameraLensRole lensRole;
  final double intrinsicZoomRatio;
  final bool isLogicalCamera;
  final List<String> physicalCameraIds;

  bool get isFront => facing == CameraFacing.front;
  bool get isBack => facing == CameraFacing.back;
}
