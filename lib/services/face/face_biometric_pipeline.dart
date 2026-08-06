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
    required this.faceInsideRing,
    required this.alignmentAccepted,
    required this.originalWidth,
    required this.originalHeight,
    required this.cropSide,
    required this.wasResized,
    required this.acceptedFrameCount,
    required this.liveness,
  });

  final bool faceDetected;
  final bool faceInsideRing;
  final bool alignmentAccepted;
  final int originalWidth;
  final int originalHeight;
  final int cropSide;
  final bool wasResized;
  final int acceptedFrameCount;
  final DualLivenessResult? liveness;
}

class FaceBiometricPipeline {
  static const framesToUse = 20;

  final RetinaFaceDetector retinaFace = RetinaFaceDetector();
  final AdaFaceEmbedder adaFace = AdaFaceEmbedder();
  final LdpcFuzzyCommitment ldpc = LdpcFuzzyCommitment();
  final OpenCvFacePreprocessor openCv = OpenCvFacePreprocessor();
  final MiniFasNetLiveness liveness = MiniFasNetLiveness();
  final List<AlignedFace> _alignedFaces = [];
  int _frameSequence = 0;

  int get acceptedFrameCount => _alignedFaces.length;

  Future<void> initializeDetector() async {
    await Future.wait([retinaFace.initialize(), liveness.initialize()]);
  }

  Future<FrameAnalysis> processFrame(img.Image cameraFrame) async {
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
    final inside =
        faces.where(_isInsideRetinaRing).toList()
          ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    AlignedFace? aligned;
    DualLivenessResult? livenessResult;
    if (inside.isNotEmpty) {
      final selectedFace = inside.first;
      final crops = openCv.cropForMiniFasNet(prepared, selectedFace);
      debugPrint(
        '[KFace][Frame $frameNumber][LivenessCrop] '
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
        '[KFace][Frame $frameNumber][Liveness] '
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
        _alignedFaces.add(aligned);
        _alignedFaces.sort((a, b) => b.sharpness.compareTo(a.sharpness));
        if (_alignedFaces.length > framesToUse) _alignedFaces.removeLast();
      }
    }
    return FrameAnalysis(
      faceDetected: faces.isNotEmpty,
      faceInsideRing: inside.isNotEmpty,
      alignmentAccepted: aligned != null,
      originalWidth: prepared.originalWidth,
      originalHeight: prepared.originalHeight,
      cropSide: prepared.cropSide,
      wasResized: prepared.wasResized,
      acceptedFrameCount: _alignedFaces.length,
      liveness: livenessResult,
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
