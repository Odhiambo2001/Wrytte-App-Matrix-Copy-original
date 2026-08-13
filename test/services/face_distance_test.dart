import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

void main() {
  FaceDetection face(double width, double height) => FaceDetection(
    left: 100,
    top: 100,
    right: 100 + width,
    bottom: 100 + height,
    confidence: 1,
    landmarks: const FaceLandmarks(
      leftEye: math.Point(0, 0),
      rightEye: math.Point(0, 0),
      nose: math.Point(0, 0),
      leftMouth: math.Point(0, 0),
      rightMouth: math.Point(0, 0),
    ),
  );

  test('classifies a small RetinaFace box as far', () {
    final result = FaceBiometricPipeline.measureFaceDistance(face(120, 140));
    expect(result.label, 'FAR');
    expect(result.sizeRatio, closeTo(140 / 640, 0.0001));
  });

  test('classifies an expected scanning-size box as normal', () {
    final result = FaceBiometricPipeline.measureFaceDistance(face(250, 300));
    expect(result.label, 'NORMAL');
  });

  test('includes 0.30 and 0.60 boundaries in normal', () {
    expect(
      FaceBiometricPipeline.measureFaceDistance(face(100, 192)).label,
      'NORMAL',
    );
    expect(
      FaceBiometricPipeline.measureFaceDistance(face(100, 384)).label,
      'NORMAL',
    );
  });

  test('classifies a large RetinaFace box as close', () {
    final result = FaceBiometricPipeline.measureFaceDistance(face(400, 430));
    expect(result.label, 'CLOSE');
    expect(result.sizeRatio, closeTo(430 / 640, 0.0001));
  });
}
