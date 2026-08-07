import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';

void main() {
  TargetFaceMetrics face(
    int number, {
    String faceLabel = 'FULL',
    int landmarks = 5,
    String distance = 'NORMAL',
    double bboxVisible = 1,
    double size = 0.4,
    double confidence = 0.9,
  }) => TargetFaceMetrics(
    faceNumber: number,
    faceLabel: faceLabel,
    visibleLandmarks: landmarks,
    distanceLabel: distance,
    boundingBoxVisibleFraction: bboxVisible,
    faceSizeRatio: size,
    confidence: confidence,
  );

  test('selects the only face that meets every requirement', () {
    final result = FaceBiometricPipeline.selectTargetFace([
      face(1, size: 0.4),
      face(2, landmarks: 4, size: 0.5),
    ]);
    expect(result.targetFaceNumber, 1);
    expect(result.reason, 'ONLY_QUALIFYING_FACE');
  });

  test('selects the larger qualifying face when gap is at least 0.15', () {
    final result = FaceBiometricPipeline.selectTargetFace([
      face(1, size: 0.55),
      face(2, size: 0.40),
    ]);
    expect(result.targetFaceNumber, 1);
    expect(result.sizeGap, closeTo(0.15, 0.000001));
  });

  test('rejects all qualifying faces when size gap is below 0.15', () {
    final result = FaceBiometricPipeline.selectTargetFace([
      face(1, size: 0.50),
      face(2, size: 0.40),
    ]);
    expect(result.targetFaceNumber, isNull);
    expect(result.reason, 'AMBIGUOUS_SIZE_GAP_BELOW_0.15');
  });

  test('rejects a face when any strict requirement fails', () {
    final cases = [
      face(1, faceLabel: 'PARTIAL'),
      face(2, landmarks: 4),
      face(3, distance: 'FAR'),
      face(4, bboxVisible: 0.89),
      face(5, confidence: 0.829),
    ];
    final result = FaceBiometricPipeline.selectTargetFace(cases);
    expect(result.targetFaceNumber, isNull);
    expect(result.qualifyingFaceNumbers, isEmpty);
  });
}
