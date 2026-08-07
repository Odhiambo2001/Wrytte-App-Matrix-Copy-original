import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:wrytte/services/face/adaface_embedder.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';
import 'package:wrytte/services/face/mini_fasnet_liveness.dart';
import 'package:wrytte/services/face/opencv_face_preprocessor.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

class FrameAnalysis {
  const FrameAnalysis({
    required this.faceDetected,
    required this.targetFaceSelected,
    required this.alignmentAccepted,
    required this.originalWidth,
    required this.originalHeight,
    required this.cropSide,
    required this.wasResized,
    required this.acceptedFrameCount,
    required this.liveness,
    required this.completeness,
    required this.faceDistance,
    required this.adaFaceComputed,
    required this.processingMilliseconds,
  });

  final bool faceDetected;
  final bool targetFaceSelected;
  final bool alignmentAccepted;
  final int originalWidth;
  final int originalHeight;
  final int cropSide;
  final bool wasResized;
  final int acceptedFrameCount;
  final DualLivenessResult? liveness;
  final FaceCompleteness completeness;
  final FaceDistance faceDistance;
  final bool adaFaceComputed;
  final int processingMilliseconds;
}

/// Apparent face distance derived from the RetinaFace bounding-box size.
///
/// This is not a physical distance measurement. A smaller face box indicates
/// a face that appears farther from the camera, while a larger box indicates
/// a face that appears closer.
class FaceDistance {
  const FaceDistance({
    required this.label,
    required this.widthRatio,
    required this.heightRatio,
    required this.sizeRatio,
  });

  final String label;
  final double widthRatio;
  final double heightRatio;
  final double sizeRatio;

  static const none = FaceDistance(
    label: 'NONE',
    widthRatio: 0,
    heightRatio: 0,
    sizeRatio: 0,
  );
}

class FaceCompleteness {
  const FaceCompleteness({
    required this.label,
    required this.detectionConfidence,
    required this.boundingBoxVisibleFraction,
    required this.visibleLandmarks,
    required this.geometryScore,
  });

  final String label;
  final double detectionConfidence;
  final double boundingBoxVisibleFraction;
  final int visibleLandmarks;
  final double geometryScore;

  static const none = FaceCompleteness(
    label: 'NONE',
    detectionConfidence: 0,
    boundingBoxVisibleFraction: 0,
    visibleLandmarks: 0,
    geometryScore: 0,
  );
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
  const TargetFaceSelection({
    required this.targetFaceNumber,
    required this.reason,
    required this.qualifyingFaceNumbers,
    required this.sizeGap,
  });

  final int? targetFaceNumber;
  final String reason;
  final List<int> qualifyingFaceNumbers;
  final double? sizeGap;
}

class FaceBiometricPipeline {
  static const framesToUse = 20;
  static const targetConfidenceThreshold = 0.83;
  static const targetSizeGap = 0.15;
  static const fullBboxVisibleThreshold = 0.90;
  static const fullGeometryThreshold = 0.80;
  static const normalFaceSizeMinimum = 0.25;
  static const normalFaceSizeMaximum = 0.65;

  final RetinaFaceDetector retinaFace = RetinaFaceDetector();
  final AdaFaceEmbedder adaFace = AdaFaceEmbedder();
  final LdpcFuzzyCommitment ldpc = LdpcFuzzyCommitment();
  final OpenCvFacePreprocessor openCv = OpenCvFacePreprocessor();
  final MiniFasNetLiveness liveness = MiniFasNetLiveness();
  final List<AlignedFace> _alignedFaces = [];
  int _frameSequence = 0;

  int get acceptedFrameCount => _alignedFaces.length;

  Future<void> initializeDetector() async {
    await Future.wait([
      retinaFace.initialize(),
      liveness.initialize(),
      adaFace.initialize(),
    ]);
  }

  Future<FrameAnalysis> processFrame(img.Image cameraFrame) async {
    final stopwatch = Stopwatch()..start();
    final frameNumber = ++_frameSequence;
    final prepared = openCv.prepare(cameraFrame);
    debugPrint(
      '[KFace][Frame $frameNumber][RetinaCrop] original='
      '${prepared.originalWidth}x${prepared.originalHeight} '
      'square=x${prepared.cropX},y${prepared.cropY},'
      '${prepared.cropSide}x${prepared.cropSide} output=640x640 '
      'resized=${prepared.wasResized}',
    );
    final faces = await retinaFace.detectBgr(prepared.bgr);
    final orderedFaces = faces.toList(growable: false)
      ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    final perFaceResults =
        <
          ({
            FaceDetection face,
            FaceCompleteness completeness,
            FaceDistance distance,
            bool insideRing,
          })
        >[];
    for (final face in orderedFaces) {
      perFaceResults.add((
        face: face,
        completeness: measureFaceCompleteness(face),
        distance: measureFaceDistance(face),
        insideRing: _isInsideRetinaRing(face),
      ));
    }
    final facesInsideRing =
        perFaceResults.where((result) => result.insideRing).length;
    debugPrint(
      '[KFace][RetinaTest][Frame $frameNumber][Faces] '
      'detected=${perFaceResults.length} insideRing=$facesInsideRing '
      'twoOrMoreInsideRing=${facesInsideRing >= 2}',
    );
    for (var index = 0; index < perFaceResults.length; index++) {
      final result = perFaceResults[index];
      final face = result.face;
      final faceCompleteness = result.completeness;
      final distance = result.distance;
      debugPrint(
        '[KFace][RetinaTest][Frame $frameNumber][Face ${index + 1}] '
        'insideRing=${result.insideRing} '
        'face=${faceCompleteness.label} '
        'confidence=${faceCompleteness.detectionConfidence.toStringAsFixed(3)} '
        'bbox=${face.left.toStringAsFixed(1)},${face.top.toStringAsFixed(1)},'
        '${face.right.toStringAsFixed(1)},${face.bottom.toStringAsFixed(1)} '
        'bboxVisible=${faceCompleteness.boundingBoxVisibleFraction.toStringAsFixed(3)} '
        'landmarks=${faceCompleteness.visibleLandmarks}/5 '
        'geometry=${faceCompleteness.geometryScore.toStringAsFixed(3)} '
        'distance=${distance.label} '
        'faceWidthRatio=${distance.widthRatio.toStringAsFixed(3)} '
        'faceHeightRatio=${distance.heightRatio.toStringAsFixed(3)} '
        'faceSizeRatio=${distance.sizeRatio.toStringAsFixed(3)}',
      );
    }
    final targetMetrics = <TargetFaceMetrics>[];
    for (var index = 0; index < perFaceResults.length; index++) {
      final result = perFaceResults[index];
      targetMetrics.add(
        TargetFaceMetrics(
          faceNumber: index + 1,
          faceLabel: result.completeness.label,
          visibleLandmarks: result.completeness.visibleLandmarks,
          distanceLabel: result.distance.label,
          boundingBoxVisibleFraction:
              result.completeness.boundingBoxVisibleFraction,
          faceSizeRatio: result.distance.sizeRatio,
          confidence: result.completeness.detectionConfidence,
        ),
      );
    }
    final targetSelection = selectTargetFace(targetMetrics);
    final maximumEligibleSize = targetMetrics
        .where(isTargetFaceEligible)
        .fold<double>(
          0,
          (maximum, face) => math.max(maximum, face.faceSizeRatio),
        );
    for (final metrics in targetMetrics) {
      final landmarksPass = metrics.visibleLandmarks == 5;
      final fullFacePass = metrics.faceLabel == 'FULL';
      final distancePass = metrics.distanceLabel == 'NORMAL';
      final bboxPass =
          metrics.boundingBoxVisibleFraction >= fullBboxVisibleThreshold;
      final confidencePass = metrics.confidence >= targetConfidenceThreshold;
      final maximumPass =
          isTargetFaceEligible(metrics) &&
          metrics.faceSizeRatio >= maximumEligibleSize;
      final selected = targetSelection.targetFaceNumber == metrics.faceNumber;
      debugPrint(
        '[KFace][Target][Frame $frameNumber][Face ${metrics.faceNumber}] '
        'fullFace=$fullFacePass '
        'landmarks5of5=$landmarksPass '
        'distanceNormal=$distancePass '
        'bboxVisible90=$bboxPass '
        'confidence83=$confidencePass '
        'insideTransparentPane=$bboxPass '
        'maxFaceSize=$maximumPass '
        'faceSizeRatio=${metrics.faceSizeRatio.toStringAsFixed(3)} '
        'result=${selected ? 'TARGET' : 'REJECTED_DELETED'}',
      );
    }
    debugPrint(
      '[KFace][Target][Frame $frameNumber] '
      'target=${targetSelection.targetFaceNumber == null ? 'NONE' : 'Face ${targetSelection.targetFaceNumber}'} '
      'reason=${targetSelection.reason} '
      'qualifying=${targetSelection.qualifyingFaceNumbers} '
      'sizeGap=${targetSelection.sizeGap?.toStringAsFixed(3) ?? 'N/A'}',
    );
    final targetResult =
        targetSelection.targetFaceNumber == null
            ? null
            : perFaceResults[targetSelection.targetFaceNumber! - 1];
    final selectedForCompleteness = targetResult?.face ?? _largestFace(faces);
    final completeness =
        selectedForCompleteness == null
            ? FaceCompleteness.none
            : measureFaceCompleteness(selectedForCompleteness);
    final faceDistance =
        selectedForCompleteness == null
            ? FaceDistance.none
            : measureFaceDistance(selectedForCompleteness);
    AlignedFace? aligned;
    DualLivenessResult? livenessResult;
    var adaFaceComputed = false;
    if (targetResult != null) {
      final selectedFace = targetResult.face;
      final selectedFaceNumber = targetSelection.targetFaceNumber!;
      final crops = openCv.cropForMiniFasNet(prepared, selectedFace);
      debugPrint(
        '[KFace][Frame $frameNumber][Face $selectedFaceNumber][LivenessCrop] '
        'face=${selectedFace.left.toStringAsFixed(1)},'
        '${selectedFace.top.toStringAsFixed(1)},'
        '${selectedFace.right.toStringAsFixed(1)},'
        '${selectedFace.bottom.toStringAsFixed(1)} '
        'V2(scale=2.7,box=${_boxLog(crops.v2Box)},output=80x80) '
        'V1SE(scale=4.0,box=${_boxLog(crops.v1seBox)},output=80x80)',
      );
      livenessResult = await liveness.predict(
        v2FaceBgr: crops.v2Bgr,
        v1seFaceBgr: crops.v1seBgr,
      );
      debugPrint(
        '[KFace][Frame $frameNumber][Face $selectedFaceNumber][Liveness] '
        'V2(real=${_prob(livenessResult.v2.realProbability)},'
        'fake=${_prob(livenessResult.v2.fakeProbability)},'
        'class=${livenessResult.v2.labelIndex},'
        'decision=${livenessResult.v2.isReal ? 'REAL' : 'FAKE'}) '
        'V1SE(real=${_prob(livenessResult.v1se.realProbability)},'
        'fake=${_prob(livenessResult.v1se.fakeProbability)},'
        'class=${livenessResult.v1se.labelIndex},'
        'decision=${livenessResult.v1se.isReal ? 'REAL' : 'FAKE'}) '
        'combined=${livenessResult.isReal ? 'PASS' : 'REJECT'}',
      );
      if (livenessResult.isReal) {
        aligned = openCv.align(prepared, selectedFace.landmarks);
      }
      if (aligned != null && livenessResult.isReal) {
        await adaFace.embed(aligned.bgr);
        adaFaceComputed = true;
        _alignedFaces.add(aligned);
        _alignedFaces.sort((a, b) => b.sharpness.compareTo(a.sharpness));
        if (_alignedFaces.length > framesToUse) _alignedFaces.removeLast();
      }
    } else {
      debugPrint(
        '[KFace][Frame $frameNumber][Liveness] '
        'status=NOT_RUN reason=NO_TARGET_FACE',
      );
    }
    stopwatch.stop();
    debugPrint(
      '[KFace][RetinaTest][Frame $frameNumber] '
      'face=${completeness.label} '
      'confidence=${completeness.detectionConfidence.toStringAsFixed(3)} '
      'bboxVisible=${completeness.boundingBoxVisibleFraction.toStringAsFixed(3)} '
      'landmarks=${completeness.visibleLandmarks}/5 '
      'geometry=${completeness.geometryScore.toStringAsFixed(3)} '
      'distance=${faceDistance.label} '
      'faceWidthRatio=${faceDistance.widthRatio.toStringAsFixed(3)} '
      'faceHeightRatio=${faceDistance.heightRatio.toStringAsFixed(3)} '
      'faceSizeRatio=${faceDistance.sizeRatio.toStringAsFixed(3)} '
      'frame=${completeness.label == "NONE" ? "RELEASED" : "PROCESSED"} '
      'liveness=${livenessResult == null
          ? 'NOT_RUN'
          : livenessResult.isReal
          ? 'PASS'
          : 'REJECT'} '
      'adaFace=${adaFaceComputed ? 'COMPLETED' : 'NOT_RUN'} '
      'processingMs=${stopwatch.elapsedMilliseconds} '
      'effectiveFps=${stopwatch.elapsedMilliseconds == 0 ? 'inf' : (1000 / stopwatch.elapsedMilliseconds).toStringAsFixed(2)}',
    );
    return FrameAnalysis(
      faceDetected: faces.isNotEmpty,
      targetFaceSelected: targetResult != null,
      alignmentAccepted: aligned != null,
      originalWidth: prepared.originalWidth,
      originalHeight: prepared.originalHeight,
      cropSide: prepared.cropSide,
      wasResized: prepared.wasResized,
      acceptedFrameCount: _alignedFaces.length,
      liveness: livenessResult,
      completeness: completeness,
      faceDistance: faceDistance,
      adaFaceComputed: adaFaceComputed,
      processingMilliseconds: stopwatch.elapsedMilliseconds,
    );
  }

  static FaceDetection? _largestFace(List<FaceDetection> faces) {
    if (faces.isEmpty) return null;
    return faces.reduce(
      (current, next) =>
          next.width * next.height > current.width * current.height
              ? next
              : current,
    );
  }

  static bool isTargetFaceEligible(TargetFaceMetrics face) =>
      face.faceLabel == 'FULL' &&
      face.visibleLandmarks == 5 &&
      face.distanceLabel == 'NORMAL' &&
      face.boundingBoxVisibleFraction >= fullBboxVisibleThreshold &&
      face.confidence >= targetConfidenceThreshold;

  static TargetFaceSelection selectTargetFace(List<TargetFaceMetrics> faces) {
    final qualifying =
        faces.where(isTargetFaceEligible).toList()
          ..sort((a, b) => b.faceSizeRatio.compareTo(a.faceSizeRatio));
    final qualifyingNumbers = qualifying
        .map((face) => face.faceNumber)
        .toList(growable: false);
    if (qualifying.isEmpty) {
      return const TargetFaceSelection(
        targetFaceNumber: null,
        reason: 'NO_FACE_MET_ALL_REQUIREMENTS',
        qualifyingFaceNumbers: [],
        sizeGap: null,
      );
    }
    if (qualifying.length == 1) {
      return TargetFaceSelection(
        targetFaceNumber: qualifying.first.faceNumber,
        reason: 'ONLY_QUALIFYING_FACE',
        qualifyingFaceNumbers: qualifyingNumbers,
        sizeGap: null,
      );
    }
    final gap = qualifying[0].faceSizeRatio - qualifying[1].faceSizeRatio;
    if (gap < targetSizeGap) {
      return TargetFaceSelection(
        targetFaceNumber: null,
        reason: 'AMBIGUOUS_SIZE_GAP_BELOW_0.15',
        qualifyingFaceNumbers: qualifyingNumbers,
        sizeGap: gap,
      );
    }
    return TargetFaceSelection(
      targetFaceNumber: qualifying.first.faceNumber,
      reason: 'LARGEST_QUALIFYING_FACE_GAP_AT_LEAST_0.15',
      qualifyingFaceNumbers: qualifyingNumbers,
      sizeGap: gap,
    );
  }

  static FaceCompleteness measureFaceCompleteness(FaceDetection face) {
    final size = OpenCvFacePreprocessor.retinaSize.toDouble();
    final rawLeft = face.rawLeft ?? face.left;
    final rawTop = face.rawTop ?? face.top;
    final rawRight = face.rawRight ?? face.right;
    final rawBottom = face.rawBottom ?? face.bottom;
    final rawWidth = math.max(0.0, rawRight - rawLeft);
    final rawHeight = math.max(0.0, rawBottom - rawTop);
    final rawArea = rawWidth * rawHeight;
    final visibleWidth = math.max(
      0.0,
      math.min(size, rawRight) - math.max(0.0, rawLeft),
    );
    final visibleHeight = math.max(
      0.0,
      math.min(size, rawBottom) - math.max(0.0, rawTop),
    );
    final bboxVisible =
        rawArea <= 0
            ? 0.0
            : (visibleWidth * visibleHeight / rawArea).clamp(0.0, 1.0);

    final points = [
      face.landmarks.leftEye,
      face.landmarks.rightEye,
      face.landmarks.nose,
      face.landmarks.leftMouth,
      face.landmarks.rightMouth,
    ];
    final visibleLandmarks =
        points
            .where(
              (point) =>
                  point.x >= 0 &&
                  point.x < size &&
                  point.y >= 0 &&
                  point.y < size,
            )
            .length;
    final leftEye = face.landmarks.leftEye;
    final rightEye = face.landmarks.rightEye;
    final nose = face.landmarks.nose;
    final leftMouth = face.landmarks.leftMouth;
    final rightMouth = face.landmarks.rightMouth;
    final geometryChecks = <bool>[
      leftEye.x < rightEye.x,
      leftMouth.x < rightMouth.x,
      math.max(leftEye.y, rightEye.y) < nose.y,
      nose.y < math.min(leftMouth.y, rightMouth.y),
    ];
    final geometryScore =
        geometryChecks.where((value) => value).length / geometryChecks.length;
    final distance = measureFaceDistance(face);
    final full =
        face.confidence >= targetConfidenceThreshold &&
        bboxVisible >= fullBboxVisibleThreshold &&
        visibleLandmarks == 5 &&
        geometryScore >= fullGeometryThreshold &&
        distance.label == 'NORMAL' &&
        distance.sizeRatio >= normalFaceSizeMinimum &&
        distance.sizeRatio <= normalFaceSizeMaximum;
    return FaceCompleteness(
      label: full ? 'FULL' : 'PARTIAL',
      detectionConfidence: face.confidence,
      boundingBoxVisibleFraction: bboxVisible,
      visibleLandmarks: visibleLandmarks,
      geometryScore: geometryScore,
    );
  }

  /// Classifies apparent camera distance using the larger normalized face-box
  /// dimension. This remains stable for modest head rotation and supports the
  /// portrait-shaped boxes commonly returned by RetinaFace.
  ///
  /// FAR:    face occupies less than 25% of the Retina input dimension.
  /// NORMAL: face occupies 25% through 65%.
  /// CLOSE:  face occupies more than 65%.
  static FaceDistance measureFaceDistance(FaceDetection face) {
    final inputSize = OpenCvFacePreprocessor.retinaSize.toDouble();
    final rawWidth = math.max(
      0.0,
      (face.rawRight ?? face.right) - (face.rawLeft ?? face.left),
    );
    final rawHeight = math.max(
      0.0,
      (face.rawBottom ?? face.bottom) - (face.rawTop ?? face.top),
    );
    final widthRatio = rawWidth / inputSize;
    final heightRatio = rawHeight / inputSize;
    final sizeRatio = math.max(widthRatio, heightRatio);
    final label =
        sizeRatio < normalFaceSizeMinimum
            ? 'FAR'
            : sizeRatio > normalFaceSizeMaximum
            ? 'CLOSE'
            : 'NORMAL';
    return FaceDistance(
      label: label,
      widthRatio: widthRatio,
      heightRatio: heightRatio,
      sizeRatio: sizeRatio,
    );
  }

  static String _boxLog(MiniFasNetCropBox box) =>
      '${box.left},${box.top},${box.right},${box.bottom} '
      '${box.width}x${box.height}';

  static String _prob(double value) =>
      '${(value * 100).clamp(0, 100).toStringAsFixed(1)}%';

  Future<Float32List> createEmbedding() async {
    if (_alignedFaces.isEmpty) {
      throw StateError('No aligned faces were collected.');
    }
    debugPrint('[KFace][Finalization][AdaFace] initialization=STARTED');
    await adaFace.initialize();
    debugPrint('[KFace][Finalization][AdaFace] initialization=COMPLETED');
    final embeddings = <Float32List>[];
    final faces = _alignedFaces.take(framesToUse).toList(growable: false);
    for (var index = 0; index < faces.length; index++) {
      debugPrint(
        '[KFace][Finalization][AdaFace] embedding=${index + 1}/${faces.length} '
        'status=STARTED',
      );
      final face = faces[index];
      embeddings.add(await adaFace.embed(face.bgr));
      debugPrint(
        '[KFace][Finalization][AdaFace] embedding=${index + 1}/${faces.length} '
        'status=COMPLETED',
      );
    }
    debugPrint('[KFace][Finalization][AdaFace] averaging=STARTED');
    final averaged = adaFace.average(embeddings);
    debugPrint('[KFace][Finalization][AdaFace] averaging=COMPLETED');
    return averaged;
  }

  Future<FuzzyCommitment> enroll() async {
    final embedding = await createEmbedding();
    debugPrint(
      '[KFace][Finalization][LDPC] mode=ENROLL initialization=STARTED',
    );
    await ldpc.initialize();
    debugPrint('[KFace][Finalization][LDPC] mode=ENROLL processing=STARTED');
    final commitment = ldpc.enroll(embedding);
    debugPrint('[KFace][Finalization][LDPC] mode=ENROLL result=COMPLETED');
    return commitment;
  }

  Future<LdpcRecoveryResult> recover(FuzzyCommitment commitment) async {
    final embedding = await createEmbedding();
    debugPrint(
      '[KFace][Finalization][LDPC] mode=RECOVER initialization=STARTED',
    );
    await ldpc.initialize();
    debugPrint('[KFace][Finalization][LDPC] mode=RECOVER processing=STARTED');
    final recovery = ldpc.recover(embedding, commitment);
    debugPrint(
      '[KFace][Finalization][LDPC] mode=RECOVER '
      'result=${recovery.accepted ? 'ACCEPTED' : 'REJECTED'}',
    );
    return recovery;
  }

  void reset() => _alignedFaces.clear();

  Future<void> dispose() async {
    await retinaFace.dispose();
    await liveness.dispose();
    await adaFace.dispose();
  }

  bool _isInsideRetinaRing(FaceDetection face) {
    const center = OpenCvFacePreprocessor.retinaSize / 2;
    const radius = OpenCvFacePreprocessor.retinaSize * 0.375;

    bool inside(double x, double y) {
      final dx = x - center;
      final dy = y - center;
      return dx * dx + dy * dy <= radius * radius;
    }

    return inside(face.left, face.top) &&
        inside(face.right, face.top) &&
        inside(face.left, face.bottom) &&
        inside(face.right, face.bottom);
  }
}
