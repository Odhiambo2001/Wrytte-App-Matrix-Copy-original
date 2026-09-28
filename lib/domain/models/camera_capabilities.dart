enum WrytteFlashMode { off, auto, always, torch }

enum WrytteVideoStabilization { off, standard, cinematic }

class CameraCapabilities {
  const CameraCapabilities({
    required this.minimumZoom,
    required this.maximumZoom,
    required this.minimumExposureOffset,
    required this.maximumExposureOffset,
    required this.exposureOffsetStep,
    required this.focusPointSupported,
    required this.exposurePointSupported,
    required this.imageStreamingSupported,
    required this.flashAvailable,
    required this.stabilizationModes,
  });

  final double minimumZoom;
  final double maximumZoom;
  final double minimumExposureOffset;
  final double maximumExposureOffset;
  final double exposureOffsetStep;
  final bool focusPointSupported;
  final bool exposurePointSupported;
  final bool imageStreamingSupported;
  final bool flashAvailable;
  final Set<WrytteVideoStabilization> stabilizationModes;
}
