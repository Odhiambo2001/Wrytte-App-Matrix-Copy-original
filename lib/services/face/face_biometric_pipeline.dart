import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:wrytte/services/face/opencv_face_preprocessor.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

/// One frontend-prepared crop set. No embedding, liveness score, biometric
/// key, quantization, or commitment is created on the device.
class BiometricCropSet {
  const BiometricCropSet({
    required this.adafaceBgr,
    required this.livenessFrameBgr,
    required this.livenessFrameWidth,
    required this.livenessFrameHeight,
    required this.livenessFaceBox,
  });

  final Uint8List adafaceBgr;

  /// A correctly-oriented camera frame. The backend derives both fixed
  /// MiniFASNet context crops from this one source image.
  final Uint8List livenessFrameBgr;
  final int livenessFrameWidth;
  final int livenessFrameHeight;
  final LivenessFaceBox livenessFaceBox;
}

class FrameAnalysis {
  const FrameAnalysis({
    required this.faceDetected,
    required this.targetFaceSelected,
    required this.alignmentAccepted,
    required this.acceptedFrameCount,
    required this.processingMilliseconds,
  });

  final bool faceDetected;
  final bool targetFaceSelected;
  final bool alignmentAccepted;
  final int acceptedFrameCount;
  final int processingMilliseconds;
}

class FaceDistance {
  const FaceDistance(
    this.label,
    this.widthRatio,
    this.heightRatio,
    this.sizeRatio,
  );
  final String label;
  final double widthRatio;
  final double heightRatio;
  final double sizeRatio;
}

class FaceCompleteness {
  const FaceCompleteness(
    this.label,
    this.boundingBoxVisibleFraction,
    this.geometryScore,
  );
  final String label;
  final double boundingBoxVisibleFraction;
  final double geometryScore;
}

class TargetFaceMetrics {
  const TargetFaceMetrics({
    required this.faceNumber,
    required this.faceLabel,
    required this.visibleLandmarks,
    required this.distanceLabel,
    required this.boundingBoxVisibleFraction,
    required this.faceSizeRatio,
    required this.confidence,
  });
  final int faceNumber;
  final String faceLabel;
  final int visibleLandmarks;
  final String distanceLabel;
  final double boundingBoxVisibleFraction;
  final double faceSizeRatio;
  final double confidence;
}

class TargetFaceSelection {
  const TargetFaceSelection(
    this.targetFaceNumber,
    this.reason,
    this.qualifyingFaceNumbers,
    this.sizeGap,
  );
  final int? targetFaceNumber;
  final String reason;
  final List<int> qualifyingFaceNumbers;
  final double? sizeGap;
}

/// Keeps RetinaFace and OpenCV on the device, then prepares the exact crops
/// consumed by the backend. AdaFace, MiniFASNet, quantization, and LDPC are
/// intentionally absent from this class.
class FaceBiometricPipeline {
  static const framesToUse = 5;
  static const targetConfidenceThreshold = 0.83;
  static const fullBboxVisibleThreshold = 0.90;
  static const normalFaceSizeMinimum = 0.34;
  static const normalFaceSizeMaximum = 0.72;

  final RetinaFaceDetector retinaFace = RetinaFaceDetector();
  final OpenCvFacePreprocessor openCv = OpenCvFacePreprocessor();
  final List<BiometricCropSet> _acceptedCrops = [];
  bool _processing = false;

  int get acceptedFrameCount => _acceptedCrops.length;
  List<BiometricCropSet> get cropSets => List.unmodifiable(_acceptedCrops);

  Future<void> initializeDetector() => retinaFace.initialize();

  static FaceDistance measureFaceDistance(FaceDetection face) {
    final widthRatio = face.width / 640;
    final heightRatio = face.height / 640;
    final size = math.max(widthRatio, heightRatio);
    return FaceDistance(
      size < 0.35
          ? 'FAR'
          : size > 0.70
          ? 'CLOSE'
          : 'NORMAL',
      widthRatio,
      heightRatio,
      size,
    );
  }

  static FaceCompleteness measureFaceCompleteness(FaceDetection face) {
    final left = face.rawLeft ?? face.left;
    final top = face.rawTop ?? face.top;
    final right = face.rawRight ?? face.right;
    final bottom = face.rawBottom ?? face.bottom;
    final fullArea = math.max(0, right - left) * math.max(0, bottom - top);
    final visibleArea =
        math.max(0, math.min(640, right) - math.max(0, left)) *
        math.max(0, math.min(640, bottom) - math.max(0, top));
    final visible = (fullArea == 0 ? 0 : visibleArea / fullArea).toDouble();
    final landmarks = face.landmarks;
    final geometry =
        (landmarks.leftEye.y < landmarks.nose.y &&
                landmarks.rightEye.y < landmarks.nose.y &&
                landmarks.leftMouth.y > landmarks.nose.y &&
                landmarks.rightMouth.y > landmarks.nose.y)
            ? 1.0
            : 0.75;
    final distance = measureFaceDistance(face);
    final full =
        face.confidence >= targetConfidenceThreshold &&
        visible >= fullBboxVisibleThreshold &&
        distance.label == 'NORMAL';
    return FaceCompleteness(full ? 'FULL' : 'PARTIAL', visible, geometry);
  }

  static TargetFaceSelection selectTargetFace(List<TargetFaceMetrics> faces) {
    final qualifying =
        faces
            .where(
              (face) =>
                  face.faceLabel == 'FULL' &&
                  face.visibleLandmarks == 5 &&
                  face.distanceLabel == 'NORMAL' &&
                  face.boundingBoxVisibleFraction >= fullBboxVisibleThreshold &&
                  face.confidence >= targetConfidenceThreshold,
            )
            .toList();
    if (qualifying.length == 1 && faces.length == 1) {
      return TargetFaceSelection(
        qualifying.first.faceNumber,
        'ONLY_QUALIFYING_FACE',
        [qualifying.first.faceNumber],
        null,
      );
    }
    if (qualifying.length == 1 && faces.length == 2) {
      final other = faces.firstWhere(
        (f) => f.faceNumber != qualifying.first.faceNumber,
      );
      final gap = qualifying.first.faceSizeRatio - other.faceSizeRatio;
      if (other.distanceLabel == 'FAR' && gap >= 0.20) {
        return TargetFaceSelection(
          qualifying.first.faceNumber,
          'NORMAL_FAR_SIZE_GAP_OK',
          [qualifying.first.faceNumber],
          gap,
        );
      }
      return TargetFaceSelection(
        null,
        other.distanceLabel == 'FAR'
            ? 'NORMAL_FAR_SIZE_GAP_BELOW_0.20'
            : 'BOTH_FACES_NORMAL',
        [qualifying.first.faceNumber],
        gap,
      );
    }
    return TargetFaceSelection(
      null,
      qualifying.length > 1
          ? 'BOTH_FACES_NORMAL'
          : 'NO_FACE_MET_ALL_REQUIREMENTS',
      qualifying.map((f) => f.faceNumber).toList(),
      null,
    );
  }

  Future<FrameAnalysis> processFrame(img.Image cameraFrame) async {
    if (_processing || _acceptedCrops.length >= framesToUse) {
      return FrameAnalysis(
        faceDetected: false,
        targetFaceSelected: false,
        alignmentAccepted: false,
        acceptedFrameCount: _acceptedCrops.length,
        processingMilliseconds: 0,
      );
    }
    _processing = true;
    final stopwatch = Stopwatch()..start();
    final prepared = openCv.prepare(cameraFrame);
    try {
      final faces = await retinaFace.detectBgr(prepared.bgr);
      final target = _selectTargetFace(faces);
      if (target == null) {
        return FrameAnalysis(
          faceDetected: faces.isNotEmpty,
          targetFaceSelected: false,
          alignmentAccepted: false,
          acceptedFrameCount: _acceptedCrops.length,
          processingMilliseconds: stopwatch.elapsedMilliseconds,
        );
      }
      final aligned = openCv.align(prepared, target.landmarks);
      if (aligned == null) {
        return FrameAnalysis(
          faceDetected: true,
          targetFaceSelected: true,
          alignmentAccepted: false,
          acceptedFrameCount: _acceptedCrops.length,
          processingMilliseconds: stopwatch.elapsedMilliseconds,
        );
      }
      final livenessFaceBox = openCv.mapFaceToOriginalBox(prepared, target);
      _acceptedCrops.add(
        BiometricCropSet(
          adafaceBgr: Uint8List.fromList(aligned.bgr),
          livenessFrameBgr: Uint8List.fromList(prepared.originalBgr),
          livenessFrameWidth: prepared.originalWidth,
          livenessFrameHeight: prepared.originalHeight,
          livenessFaceBox: livenessFaceBox,
        ),
      );
      return FrameAnalysis(
        faceDetected: true,
        targetFaceSelected: true,
        alignmentAccepted: true,
        acceptedFrameCount: _acceptedCrops.length,
        processingMilliseconds: stopwatch.elapsedMilliseconds,
      );
    } finally {
      prepared.dispose();
      _processing = false;
    }
  }

  FaceDetection? _selectTargetFace(List<FaceDetection> faces) {
    final eligible =
        faces.where((face) {
            final size = math.max(face.width / 640, face.height / 640);
            return face.confidence >= targetConfidenceThreshold &&
                _visibleFraction(face) >= fullBboxVisibleThreshold &&
                size >= normalFaceSizeMinimum &&
                size <= normalFaceSizeMaximum &&
                // A RetinaFace detection always carries its five named landmarks.
                // `align` below is the final validity check for those coordinates.
                true;
          }).toList()
          ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    if (eligible.isEmpty) return null;
    if (eligible.length == 1) return eligible.first;
    final firstArea = eligible[0].width * eligible[0].height;
    final secondArea = eligible[1].width * eligible[1].height;
    return (firstArea - secondArea) / firstArea >= 0.20 ? eligible.first : null;
  }

  double _visibleFraction(FaceDetection face) {
    final width = math.max(
      0.0,
      math.min(640.0, face.right) - math.max(0.0, face.left),
    );
    final height = math.max(
      0.0,
      math.min(640.0, face.bottom) - math.max(0.0, face.top),
    );
    final area = face.width * face.height;
    return area <= 0 ? 0 : (width * height) / area;
  }

  /// Best-effort in-memory cleanup once a biometric request has finished.
  /// Camera frames are never written to device storage. Dart cannot promise
  /// secure physical-memory erasure, but zeroing our owned byte arrays before
  /// releasing their references minimizes their lifetime in this process.
  void reset() {
    for (final capture in _acceptedCrops) {
      capture.adafaceBgr.fillRange(0, capture.adafaceBgr.length, 0);
      capture.livenessFrameBgr.fillRange(0, capture.livenessFrameBgr.length, 0);
    }
    _acceptedCrops.clear();
  }

  Future<void> dispose() async {
    reset();
    await retinaFace.dispose();
  }
}
