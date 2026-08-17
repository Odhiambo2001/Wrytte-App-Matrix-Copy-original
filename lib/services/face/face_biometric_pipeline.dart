import 'dart:async';
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

class BiometricEnrollmentResult {
  const BiometricEnrollmentResult({
    required this.commitment,
    required this.derivedKey,
  });

  final FuzzyCommitment commitment;
  final String derivedKey;
}

class _AcceptedAlignedFace {
  const _AcceptedAlignedFace({required this.sharpness, required this.bgr});

  final double sharpness;
  final Uint8List bgr;
}

class _SerialStageGate {
  Future<void> _tail = Future<void>.value();

  Future<void Function()> acquire() async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    return release.complete;
  }
}

class FaceBiometricPipeline {
  static const framesToUse = 5;
  static const targetConfidenceThreshold = 0.83;
  static const targetSizeGap = 0.20;
  static const fullBboxVisibleThreshold = 0.90;
  static const normalFaceSizeMinimum = 0.35;
  static const normalFaceSizeMaximum = 0.70;

  // --- Strict FPS gate -------------------------------------------------
  // Caps processing throughput at exactly this many frames per second.
  // Frames arriving faster than the interval below are dropped before any
  // detection/liveness/embedding work runs, so cost is effectively zero
  // for throttled frames.
  static const int targetFps = 15;
  static const Duration _minFrameInterval = Duration(
    microseconds: 1000000 ~/ targetFps,
  );
  DateTime? _lastFrameProcessedAt;
  // -----------------------------------------------------------------------

  final RetinaFaceDetector retinaFace = RetinaFaceDetector();
  final AdaFaceEmbedder adaFace = AdaFaceEmbedder();
  final LdpcFuzzyCommitment ldpc = LdpcFuzzyCommitment();
  final OpenCvFacePreprocessor openCv = OpenCvFacePreprocessor();
  final MiniFasNetLiveness liveness = MiniFasNetLiveness();
  final List<_AcceptedAlignedFace> _acceptedFaces = [];
  final _retinaStageGate = _SerialStageGate();
  final _downstreamStageGate = _SerialStageGate();
  int _frameSequence = 0;
  bool _collectionComplete = false;

  int get acceptedFrameCount => _acceptedFaces.length;

  Future<void> initializeDetector() async {
    await Future.wait([
      retinaFace.initialize(),
      liveness.initialize(),
      adaFace.initialize(),
    ]);
  }

  Future<FrameAnalysis> processFrame(img.Image cameraFrame) async {
    final now = DateTime.now();
    if (_lastFrameProcessedAt != null &&
        now.difference(_lastFrameProcessedAt!) < _minFrameInterval) {
      debugPrint(
        '[KFace][FPS] throttled target=${targetFps}fps '
        'minIntervalMs=${_minFrameInterval.inMilliseconds} '
        'sinceLastMs=${now.difference(_lastFrameProcessedAt!).inMilliseconds}',
      );
      return FrameAnalysis(
        faceDetected: false,
        targetFaceSelected: false,
        alignmentAccepted: false,
        originalWidth: cameraFrame.width,
        originalHeight: cameraFrame.height,
        cropSide: 0,
        wasResized: false,
        acceptedFrameCount: _acceptedFaces.length,
        liveness: null,
        completeness: FaceCompleteness.none,
        faceDistance: FaceDistance.none,
        adaFaceComputed: false,
        processingMilliseconds: 0,
      );
    }
    _lastFrameProcessedAt = now;

    final retinaQueueTimer = Stopwatch()..start();
    final releaseRetinaStage = await _retinaStageGate.acquire();
    retinaQueueTimer.stop();
    var retinaStageReleased = false;
    void Function()? releaseDownstreamStage;
    final stopwatch = Stopwatch()..start();
    final phaseStopwatch = Stopwatch()..start();
    final frameNumber = ++_frameSequence;
    final prepared = openCv.prepare(cameraFrame);
    try {
      final preprocessingMs = phaseStopwatch.elapsedMilliseconds;
      debugPrint(
        '[KFace][Frame $frameNumber][RetinaCrop] original='
        '${prepared.originalWidth}x${prepared.originalHeight} '
        'square=x${prepared.cropX},y${prepared.cropY},'
        '${prepared.cropSide}x${prepared.cropSide} output=640x640 '
        'resized=${prepared.wasResized}',
      );
      phaseStopwatch
        ..reset()
        ..start();
      final faces = await retinaFace.detectBgr(prepared.bgr);
      final retinaFaceMs = phaseStopwatch.elapsedMilliseconds;
      phaseStopwatch
        ..reset()
        ..start();
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
      final maximumDetectedSize = targetMetrics.fold<double>(
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
        final maximumPass = metrics.faceSizeRatio >= maximumDetectedSize;
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
        'bboxSizeGap=${targetSelection.sizeGap?.toStringAsFixed(3) ?? 'N/A'}',
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
      final faceEvaluationMs = phaseStopwatch.elapsedMilliseconds;
      releaseRetinaStage();
      retinaStageReleased = true;
      var downstreamQueueMs = 0;
      var runDownstream = false;
      if (targetResult != null) {
        final downstreamQueueTimer = Stopwatch()..start();
        releaseDownstreamStage = await _downstreamStageGate.acquire();
        downstreamQueueTimer.stop();
        downstreamQueueMs = downstreamQueueTimer.elapsedMilliseconds;
        runDownstream = !_collectionComplete;
      }
      debugPrint(
        '[KFace][Pipeline][Frame $frameNumber] '
        'retinaQueueMs=${retinaQueueTimer.elapsedMilliseconds} '
        'downstreamQueueMs=$downstreamQueueMs '
        'stages=RETINA_THEN_LIVENESS adaface=DEFERRED_UNTIL_PROFILE',
      );
      AlignedFace? aligned;
      DualLivenessResult? livenessResult;
      var livenessCropMs = 0;
      var livenessInferenceMs = 0;
      var alignmentMs = 0;
      var livenessAndAlignmentWallMs = 0;
      var alignedFaceStorageMs = 0;
      // RetinaFace must first select a target that satisfies every target-face
      // rule. Invalid/no-target frames never reach liveness or AdaFace.
      if (targetResult != null && runDownstream) {
        final selectedFace = targetResult.face;
        final selectedFaceNumber = targetSelection.targetFaceNumber!;
        phaseStopwatch
          ..reset()
          ..start();
        final crops = openCv.cropForMiniFasNet(prepared, selectedFace);
        livenessCropMs = phaseStopwatch.elapsedMilliseconds;
        debugPrint(
          '[KFace][Frame $frameNumber][Face $selectedFaceNumber][LivenessCrop] '
          'face=${selectedFace.left.toStringAsFixed(1)},'
          '${selectedFace.top.toStringAsFixed(1)},'
          '${selectedFace.right.toStringAsFixed(1)},'
          '${selectedFace.bottom.toStringAsFixed(1)} '
          'V2(scale=2.7,box=${_boxLog(crops.v2Box)},output=80x80) '
          'V1SE(scale=4.0,box=${_boxLog(crops.v1seBox)},output=80x80)',
        );
        final parallelStageTimer = Stopwatch()..start();
        // MiniFASNetV2 and MiniFASNetV1SE are executed in parallel inside
        // predict(). This downstream stage also overlaps the next frame's
        // serialized RetinaFace stage through the two independent stage gates.
        final livenessFuture = () async {
          final timer = Stopwatch()..start();
          final result = await liveness.predict(
            v2FaceBgr: crops.v2Bgr,
            v1seFaceBgr: crops.v1seBgr,
          );
          timer.stop();
          return (result: result, elapsedMs: timer.elapsedMilliseconds);
        }();

        // Alignment is independent of the liveness decision, so perform it while
        // the liveness models run. AdaFace is intentionally deferred until the
        // profile page is visible and locked.
        phaseStopwatch
          ..reset()
          ..start();
        aligned = openCv.align(prepared, selectedFace.landmarks);
        alignmentMs = phaseStopwatch.elapsedMilliseconds;

        final timedLiveness = await livenessFuture;
        livenessResult = timedLiveness.result;
        livenessInferenceMs = timedLiveness.elapsedMs;
        parallelStageTimer.stop();
        livenessAndAlignmentWallMs = parallelStageTimer.elapsedMilliseconds;
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
        if (aligned != null && livenessResult.isReal) {
          phaseStopwatch
            ..reset()
            ..start();
          _acceptedFaces.add(
            _AcceptedAlignedFace(
              sharpness: aligned.sharpness,
              bgr: aligned.bgr,
            ),
          );
          _acceptedFaces.sort((a, b) => b.sharpness.compareTo(a.sharpness));
          if (_acceptedFaces.length > framesToUse) {
            _acceptedFaces.removeLast();
          }
          _collectionComplete = _acceptedFaces.length >= framesToUse;
          alignedFaceStorageMs = phaseStopwatch.elapsedMilliseconds;
          debugPrint(
            '[KFace][Frame $frameNumber][AdaFace] '
            'status=DEFERRED_UNTIL_PROFILE_PAGE',
          );
        }
      } else {
        debugPrint(
          '[KFace][Frame $frameNumber][Liveness] '
          'status=NOT_RUN reason=NO_TARGET_FACE',
        );
      }
      stopwatch.stop();
      phaseStopwatch.stop();
      final measuredMs =
          preprocessingMs +
          retinaFaceMs +
          faceEvaluationMs +
          livenessCropMs +
          livenessAndAlignmentWallMs +
          alignedFaceStorageMs;
      final unaccountedMs = math.max(
        0,
        stopwatch.elapsedMilliseconds - measuredMs,
      );
      final openCvMs = preprocessingMs + livenessCropMs + alignmentMs;
      debugPrint(
        '[KFace][Timing][Frame $frameNumber] '
        'preprocessMs=$preprocessingMs '
        'retinaFaceMs=$retinaFaceMs '
        'faceEvaluationAndTargetSelectionMs=$faceEvaluationMs '
        'livenessCropMs=$livenessCropMs '
        'livenessInferenceMs=$livenessInferenceMs '
        'alignmentMs=$alignmentMs '
        'adaFaceMs=DEFERRED '
        'livenessAndAlignmentWallMs=$livenessAndAlignmentWallMs '
        'alignedFaceStorageMs=$alignedFaceStorageMs '
        'unaccountedAndLoggingMs=$unaccountedMs '
        'totalMs=${stopwatch.elapsedMilliseconds}',
      );
      debugPrint(
        '[KFace][Timing][OpenCV][Frame $frameNumber] '
        'preprocessMs=$preprocessingMs '
        'livenessCropMs=$livenessCropMs '
        'alignmentMs=$alignmentMs '
        'totalMs=$openCvMs '
        'fps=${openCvMs == 0 ? 'inf' : (1000 / openCvMs).toStringAsFixed(2)} '
        'target15Fps=${openCvMs <= 67 ? 'PASS' : 'MISS'}',
      );
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
        'adaFace=DEFERRED_UNTIL_PROFILE '
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
        acceptedFrameCount: _acceptedFaces.length,
        liveness: livenessResult,
        completeness: completeness,
        faceDistance: faceDistance,
        adaFaceComputed: false,
        processingMilliseconds: stopwatch.elapsedMilliseconds,
      );
    } finally {
      releaseDownstreamStage?.call();
      if (!retinaStageReleased) releaseRetinaStage();
      prepared.dispose();
    }
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
    if (faces.length == 1 && qualifying.length == 1) {
      return TargetFaceSelection(
        targetFaceNumber: qualifying.first.faceNumber,
        reason: 'ONLY_QUALIFYING_FACE',
        qualifyingFaceNumbers: qualifyingNumbers,
        sizeGap: null,
      );
    }
    if (faces.length != 2) {
      return TargetFaceSelection(
        targetFaceNumber: null,
        reason: 'REQUIRES_EXACTLY_ONE_OR_TWO_FACES',
        qualifyingFaceNumbers: qualifyingNumbers,
        sizeGap: null,
      );
    }
    if (faces.every((face) => face.distanceLabel == 'NORMAL')) {
      return TargetFaceSelection(
        targetFaceNumber: null,
        reason: 'BOTH_FACES_NORMAL',
        qualifyingFaceNumbers: qualifyingNumbers,
        sizeGap: null,
      );
    }
    if (qualifying.length != 1) {
      return TargetFaceSelection(
        targetFaceNumber: null,
        reason: 'NO_UNIQUE_FULL_NORMAL_FACE',
        qualifyingFaceNumbers: qualifyingNumbers,
        sizeGap: null,
      );
    }
    final target = qualifying.first;
    final other = faces.firstWhere(
      (face) => face.faceNumber != target.faceNumber,
    );
    final gap = target.faceSizeRatio - other.faceSizeRatio;
    if (other.distanceLabel != 'FAR') {
      return TargetFaceSelection(
        targetFaceNumber: null,
        reason: 'SECOND_FACE_NOT_FAR',
        qualifyingFaceNumbers: qualifyingNumbers,
        sizeGap: gap,
      );
    }
    if (gap + 1e-9 < targetSizeGap) {
      return TargetFaceSelection(
        targetFaceNumber: null,
        reason: 'NORMAL_FAR_SIZE_GAP_BELOW_0.20',
        qualifyingFaceNumbers: qualifyingNumbers,
        sizeGap: gap,
      );
    }
    return TargetFaceSelection(
      targetFaceNumber: target.faceNumber,
      reason: 'NORMAL_TARGET_FAR_OTHER_GAP_AT_LEAST_0.20',
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
  /// FAR:    face occupies less than 35% of the Retina input dimension.
  /// NORMAL: face occupies 35% through 70%.
  /// CLOSE:  face occupies more than 70%.
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
    if (_acceptedFaces.length < framesToUse) {
      throw StateError('Five liveness-approved aligned faces are required.');
    }
    debugPrint(
      '[KFace][Finalization][AdaFace] status=STARTED_AFTER_PROFILE '
      'faces=$framesToUse',
    );
    final embeddings = <Float32List>[];
    final selectedFaces = _acceptedFaces
        .take(framesToUse)
        .toList(growable: false);
    for (var index = 0; index < selectedFaces.length; index++) {
      final timer = Stopwatch()..start();
      final embedding = await adaFace.embed(selectedFaces[index].bgr);
      timer.stop();
      embeddings.add(embedding);
      debugPrint(
        '[KFace][Finalization][AdaFace] embedding=${index + 1}/$framesToUse '
        'inferenceMs=${timer.elapsedMilliseconds}',
      );
    }
    debugPrint('[KFace][Finalization][AdaFace] averaging=STARTED');
    final averaged = adaFace.average(embeddings);
    debugPrint('[KFace][Finalization][AdaFace] averaging=COMPLETED');
    return averaged;
  }

  Future<BiometricEnrollmentResult> enroll() async {
    final embedding = await createEmbedding();
    final biometricBits = ldpc.embeddingToBitVector(embedding);
    debugPrint(
      '[KFace][Finalization][Quantization] dimensions=${embedding.length} '
      'scale=${LdpcFuzzyCommitment.quantScale} '
      'bitsPerDimension=${LdpcFuzzyCommitment.quantBits} '
      'outputBits=${biometricBits.length} ldpcUsedBits=${LdpcFuzzyCommitment.codeN}',
    );
    debugPrint(
      '[KFace][Finalization][LDPC] mode=ENROLL initialization=STARTED',
    );
    await ldpc.initialize();
    debugPrint('[KFace][Finalization][LDPC] mode=ENROLL processing=STARTED');
    final commitment = ldpc.enroll(embedding);
    final derivedKey = ldpc.deriveEnrollmentKey(embedding, commitment);
    debugPrint(
      '[KFace][Finalization][KDF] algorithm=${LdpcFuzzyCommitment.kdfAlgorithm} '
      'saltBytes=${commitment.kdfSalt.length} '
      'info=${LdpcFuzzyCommitment.kdfInfo} outputBytes=32 status=COMPLETED',
    );
    debugPrint('[KFace][Finalization][LDPC] mode=ENROLL result=COMPLETED');
    return BiometricEnrollmentResult(
      commitment: commitment,
      derivedKey: derivedKey,
    );
  }

  Future<LdpcRecoveryResult> recover(FuzzyCommitment commitment) async {
    final embedding = await createEmbedding();
    final biometricBits = ldpc.embeddingToBitVector(
      embedding,
      scale: commitment.quantScale,
    );
    debugPrint(
      '[KFace][Finalization][Quantization] dimensions=${embedding.length} '
      'scale=${commitment.quantScale} '
      'bitsPerDimension=${LdpcFuzzyCommitment.quantBits} '
      'outputBits=${biometricBits.length} ldpcUsedBits=${LdpcFuzzyCommitment.codeN}',
    );
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
    debugPrint(
      '[KFace][Finalization][KDF] algorithm=${LdpcFuzzyCommitment.kdfAlgorithm} '
      'status=${recovery.derivedKey == null ? 'NOT_DERIVED' : 'COMPLETED'}',
    );
    return recovery;
  }

  void reset() {
    _acceptedFaces.clear();
    _lastFrameProcessedAt = null;
    _collectionComplete = false;
  }

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
