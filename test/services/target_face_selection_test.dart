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
    final result = FaceBiometricPipeline.selectTargetFace([face(1, size: 0.4)]);
    expect(result.targetFaceNumber, 1);
    expect(result.reason, 'ONLY_QUALIFYING_FACE');
  });

  test('selects normal target when far face is at least 0.20 smaller', () {
    final result = FaceBiometricPipeline.selectTargetFace([
      face(1, size: 0.45),
      face(2, faceLabel: 'PARTIAL', distance: 'FAR', size: 0.25),
    ]);
    expect(result.targetFaceNumber, 1);
    expect(result.sizeGap, closeTo(0.20, 0.000001));
  });

  test('rejects normal and far faces when size gap is below 0.20', () {
    final result = FaceBiometricPipeline.selectTargetFace([
      face(1, size: 0.45),
      face(2, faceLabel: 'PARTIAL', distance: 'FAR', size: 0.26),
    ]);
    expect(result.targetFaceNumber, isNull);
    expect(result.reason, 'NORMAL_FAR_SIZE_GAP_BELOW_0.20');
  });

  test('rejects both faces when both distances are normal', () {
    final result = FaceBiometricPipeline.selectTargetFace([
      face(1, size: 0.45),
      face(2, size: 0.35),
    ]);
    expect(result.targetFaceNumber, isNull);
    expect(result.reason, 'BOTH_FACES_NORMAL');
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
