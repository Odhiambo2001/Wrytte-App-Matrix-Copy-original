class CameraDeviceRecord {
  const CameraDeviceRecord({
    required this.id,
    required this.lensDirection,
    required this.sensorOrientation,
    required this.lensType,
  });

  final String id;
  final String lensDirection;
  final int sensorOrientation;
  final String lensType;
}

class NativeCameraMetadataRecord {
  const NativeCameraMetadataRecord({
    required this.cameraId,
    this.intrinsicZoomRatio = 1,
    this.logicalMultiCamera = false,
    this.physicalCameraIds = const <String>[],
    this.flashAvailable = false,
  });

  final String cameraId;
  final double intrinsicZoomRatio;
  final bool logicalMultiCamera;
  final List<String> physicalCameraIds;
  final bool flashAvailable;
}

class DeviceCameraCapabilitiesRecord {
  const DeviceCameraCapabilitiesRecord({
    required this.minimumZoom,
    required this.maximumZoom,
    required this.minimumExposureOffset,
    required this.maximumExposureOffset,
    required this.exposureOffsetStep,
    required this.focusPointSupported,
    required this.exposurePointSupported,
    required this.imageStreamingSupported,
    required this.stabilizationModes,
    required this.previewAspectRatio,
  });

  final double minimumZoom;
  final double maximumZoom;
  final double minimumExposureOffset;
  final double maximumExposureOffset;
  final double exposureOffsetStep;
  final bool focusPointSupported;
  final bool exposurePointSupported;
  final bool imageStreamingSupported;
  final Set<String> stabilizationModes;
  final double previewAspectRatio;
}

class DeviceCameraException implements Exception {
  const DeviceCameraException(this.code, this.description, [this.cause]);

  final String code;
  final String description;
  final Object? cause;
}
