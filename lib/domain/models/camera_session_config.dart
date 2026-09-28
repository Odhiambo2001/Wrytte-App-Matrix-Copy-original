enum CameraPurpose { profilePhoto, chatAttachment, generic }

enum CameraCaptureMode { photo, photoAndVideo }

enum CameraResolution { medium, high, veryHigh }

class CameraSessionConfig {
  const CameraSessionConfig({
    required this.purpose,
    required this.captureMode,
    required this.enableAudio,
    required this.resolution,
    this.preferredFacing = CameraFacingPreference.back,
    this.jpegQuality = 92,
    this.framesPerSecond,
    this.videoBitrate,
    this.audioBitrate,
  });

  const CameraSessionConfig.profilePhoto()
    : purpose = CameraPurpose.profilePhoto,
      captureMode = CameraCaptureMode.photo,
      enableAudio = false,
      resolution = CameraResolution.high,
      preferredFacing = CameraFacingPreference.back,
      jpegQuality = 92,
      framesPerSecond = null,
      videoBitrate = null,
      audioBitrate = null;

  const CameraSessionConfig.chatAttachment()
    : purpose = CameraPurpose.chatAttachment,
      captureMode = CameraCaptureMode.photoAndVideo,
      enableAudio = true,
      resolution = CameraResolution.high,
      preferredFacing = CameraFacingPreference.back,
      jpegQuality = 92,
      framesPerSecond = null,
      videoBitrate = null,
      audioBitrate = null;

  final CameraPurpose purpose;
  final CameraCaptureMode captureMode;
  final bool enableAudio;
  final CameraResolution resolution;
  final CameraFacingPreference preferredFacing;
  final int jpegQuality;
  final int? framesPerSecond;
  final int? videoBitrate;
  final int? audioBitrate;

  bool get supportsVideo => captureMode == CameraCaptureMode.photoAndVideo;

  bool isCompatibleWith(CameraSessionConfig other) =>
      enableAudio == other.enableAudio &&
      resolution == other.resolution &&
      framesPerSecond == other.framesPerSecond &&
      videoBitrate == other.videoBitrate &&
      audioBitrate == other.audioBitrate;
}

enum CameraFacingPreference { front, back }
