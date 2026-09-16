import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:wrytte/services/face/opencv_face_preprocessor.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

/// One frontend-prepared capture set. No Umeyama alignment, embedding,
/// liveness score, biometric key, quantization, or commitment is created on
/// the device.
class BiometricCropSet {
  const BiometricCropSet({
    required this.retinaFaceBgr,
    required this.adafaceLandmarks,
    required this.livenessFrameBgr,
    required this.livenessFrameWidth,
    required this.livenessFrameHeight,
    required this.livenessFaceBox,
  });

  /// The 640x640 RetinaFace image and its landmark coordinates. The backend
  /// uses them to run Umeyama and create the 112x112 AdaFace input.
  final Uint8List retinaFaceBgr;
  final FaceLandmarks adafaceLandmarks;

  /// A correctly-oriented camera frame. The backend derives both fixed
  /// MiniFASNet context crops from this one source image.
  final Uint8List livenessFrameBgr;
  final int livenessFrameWidth;
  final int livenessFrameHeight;
  final LivenessFaceBox livenessFaceBox;

  /// Clears the frontend-owned candidate bytes immediately after its upload
  /// has completed. The backend never asks the device to retain candidates.
  void clear() {
    retinaFaceBgr.fillRange(0, retinaFaceBgr.length, 0);
    livenessFrameBgr.fillRange(0, livenessFrameBgr.length, 0);
  }
}

class FrameAnalysis {
  const FrameAnalysis({
    required this.faceDetected,
    required this.targetFaceSelected,
    required this.alignmentAccepted,
    required this.processingMilliseconds,
    this.faceCenterX,
    this.faceCenterY,
    this.faceTooFar = false,
    this.faceTooClose = false,
    this.multipleFaces = false,
    this.capture,
  });

  final bool faceDetected;
  final bool targetFaceSelected;
  final bool alignmentAccepted;
  final int processingMilliseconds;
  final double? faceCenterX;
  final double? faceCenterY;
  final bool faceTooFar;
  final bool faceTooClose;
  final bool multipleFaces;
  final BiometricCropSet? capture;
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

/// Keeps RetinaFace and OpenCV frame preparation on the device. The backend
/// owns Umeyama, AdaFace, MiniFASNet, and quantization. Flutter performs LDPC
/// only after the backend has accepted five immediately uploaded candidates.
class FaceBiometricPipeline {
  static const framesToUse = 5;
  static const targetConfidenceThreshold = 0.83;
  static const fullBboxVisibleThreshold = 0.90;
  static const normalFaceSizeMinimum = 0.34;
  static const normalFaceSizeMaximum = 0.74;

  final RetinaFaceDetector retinaFace = RetinaFaceDetector();
  final OpenCvFacePreprocessor openCv = OpenCvFacePreprocessor();
  bool _processing = false;

  Future<void> initializeDetector() => retinaFace.initialize();

  static FaceDistance measureFaceDistance(FaceDetection face) {
    final widthRatio = face.width / 640;
    final heightRatio = face.height / 640;
    final size = math.max(widthRatio, heightRatio);
    return FaceDistance(
      size < normalFaceSizeMinimum
          ? 'FAR'
          : size > normalFaceSizeMaximum
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
    if (_processing) {
      return FrameAnalysis(
        faceDetected: false,
        targetFaceSelected: false,
        alignmentAccepted: false,
        processingMilliseconds: 0,
      );
    }
    _processing = true;
    final stopwatch = Stopwatch()..start();
    final openCvTimer = Stopwatch()..start();
    final prepared = openCv.prepare(cameraFrame);
    openCvTimer.stop();
    // ignore: avoid_print
    print(
      '[BiometricTiming] pipeline=OpenCV stage=prepare '
      'elapsed_ms=${openCvTimer.elapsedMilliseconds}',
    );
    try {
      final retinaTimer = Stopwatch()..start();
      final faces = await retinaFace.detectBgr(prepared.bgr);
      retinaTimer.stop();
      // ignore: avoid_print
      print(
        '[BiometricTiming] pipeline=RetinaFace stage=inference_decode '
        'elapsed_ms=${retinaTimer.elapsedMilliseconds}',
      );
      final target = _selectTargetFace(faces);
      if (target == null) {
        return FrameAnalysis(
          faceDetected: faces.isNotEmpty,
          targetFaceSelected: false,
          alignmentAccepted: false,
          processingMilliseconds: stopwatch.elapsedMilliseconds,
          faceTooFar:
              faces.isNotEmpty &&
              faces.every((face) => measureFaceDistance(face).label == 'FAR'),
          faceTooClose:
              faces.isNotEmpty &&
              faces.every((face) => measureFaceDistance(face).label == 'CLOSE'),
          multipleFaces: faces.length > 1,
        );
      }
      final livenessFaceBox = openCv.mapFaceToOriginalBox(prepared, target);
      final capture = BiometricCropSet(
        retinaFaceBgr: Uint8List.fromList(prepared.bgr),
        adafaceLandmarks: target.landmarks,
        livenessFrameBgr: Uint8List.fromList(prepared.originalBgr),
        livenessFrameWidth: prepared.originalWidth,
        livenessFrameHeight: prepared.originalHeight,
        livenessFaceBox: livenessFaceBox,
      );
      return FrameAnalysis(
        faceDetected: true,
        targetFaceSelected: true,
        alignmentAccepted: true,
        processingMilliseconds: stopwatch.elapsedMilliseconds,
        faceCenterX: target.centerX,
        faceCenterY: target.centerY,
        capture: capture,
      );
    } finally {
      // This is the end-to-end FE cost for one frame, including preprocessing,
      // RetinaFace inference/decode, and target selection/crop preparation.
      // Keep it alongside the stage timers so device logs expose the complete
      // per-frame budget.
      // ignore: avoid_print
      print(
        '[BiometricTiming] pipeline=FaceFrame stage=total '
        'elapsed_ms=${stopwatch.elapsedMilliseconds}',
      );
      prepared.dispose();
      _processing = false;
    }
  }

  FaceDetection? _selectTargetFace(List<FaceDetection> faces) {
    // A biometric capture is permitted for one qualifying normal-distance
    // face, or for exactly two faces only when the other is far and at least
    // 0.20 smaller by the detector's size ratio. This intentionally rejects
    // two normal faces and every three-or-more-face frame.
    if (faces.isEmpty || faces.length > 2) return null;
    final selection = selectTargetFace(
      List<TargetFaceMetrics>.generate(faces.length, (index) {
        final face = faces[index];
        final completeness = measureFaceCompleteness(face);
        final distance = measureFaceDistance(face);
        return TargetFaceMetrics(
          faceNumber: index,
          faceLabel: completeness.label,
          visibleLandmarks: _hasFiveUsableLandmarks(face) ? 5 : 0,
          distanceLabel: distance.label,
          boundingBoxVisibleFraction: completeness.boundingBoxVisibleFraction,
          faceSizeRatio: distance.sizeRatio,
          confidence: face.confidence,
        );
      }),
    );
    final targetNumber = selection.targetFaceNumber;
    return targetNumber == null ? null : faces[targetNumber];
  }

  static bool _hasFiveUsableLandmarks(FaceDetection face) {
    final points = <math.Point<double>>[
      face.landmarks.leftEye,
      face.landmarks.rightEye,
      face.landmarks.nose,
      face.landmarks.leftMouth,
      face.landmarks.rightMouth,
    ];
    return points.every(
      (point) =>
          point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0,
    );
  }

  /// Best-effort in-memory cleanup once a biometric request has finished.
  /// Each candidate is cleared by its caller after its immediate upload, so
  /// this pipeline never accumulates camera frames in device memory.
  void reset() {}

  Future<void> dispose() async {
    reset();
    await retinaFace.dispose();
  }
}
