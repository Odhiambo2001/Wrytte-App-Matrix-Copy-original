import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:wrytte/services/face/adaface_embedder.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';
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
  });

  final bool faceDetected;
  final bool faceInsideRing;
  final bool alignmentAccepted;
  final int originalWidth;
  final int originalHeight;
  final int cropSide;
  final bool wasResized;
  final int acceptedFrameCount;
}

class FaceBiometricPipeline {
  static const framesToUse = 20;

  final RetinaFaceDetector retinaFace = RetinaFaceDetector();
  final AdaFaceEmbedder adaFace = AdaFaceEmbedder();
  final LdpcFuzzyCommitment ldpc = LdpcFuzzyCommitment();
  final OpenCvFacePreprocessor openCv = OpenCvFacePreprocessor();
  final List<AlignedFace> _alignedFaces = [];

  int get acceptedFrameCount => _alignedFaces.length;

  Future<void> initializeDetector() => retinaFace.initialize();

  Future<FrameAnalysis> processFrame(img.Image cameraFrame) async {
    final prepared = openCv.prepare(cameraFrame);
    final faces = await retinaFace.detectBgr(prepared.bgr);
    final inside =
        faces.where(_isInsideRetinaRing).toList()
          ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    AlignedFace? aligned;
    if (inside.isNotEmpty) {
      aligned = openCv.align(prepared, inside.first.landmarks);
      if (aligned != null) {
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
    );
  }

  Future<Float32List> createEmbedding() async {
    if (_alignedFaces.isEmpty) {
      throw StateError('No aligned faces were collected.');
    }
    await adaFace.initialize();
    final embeddings = <Float32List>[];
    for (final face in _alignedFaces.take(framesToUse)) {
      embeddings.add(await adaFace.embed(face.bgr));
    }
    return adaFace.average(embeddings);
  }

  Future<FuzzyCommitment> enroll() async {
    final embedding = await createEmbedding();
    await ldpc.initialize();
    return ldpc.enroll(embedding);
  }

  Future<LdpcRecoveryResult> recover(FuzzyCommitment commitment) async {
    final embedding = await createEmbedding();
    await ldpc.initialize();
    return ldpc.recover(embedding, commitment);
  }

  void reset() => _alignedFaces.clear();

  Future<void> dispose() async {
    await retinaFace.dispose();
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
