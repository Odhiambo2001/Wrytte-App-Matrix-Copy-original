enum CameraFailureCode {
  permissionDenied,
  permissionPermanentlyDenied,
  noCamera,
  configurationUnsupported,
  interrupted,
  captureFailed,
  unavailable,
  unknown,
}

class CameraFailure implements Exception {
  const CameraFailure(this.code, this.message, {this.cause});

  final CameraFailureCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'CameraFailure($code, $message)';
}
