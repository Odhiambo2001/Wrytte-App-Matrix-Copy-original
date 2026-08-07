import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

void main() {
  FaceDetection face({
    double confidence = 0.90,
    double left = 180,
    double top = 160,
    double right = 420,
    double bottom = 440,
    double? rawLeft,
    double? rawTop,
    double? rawRight,
    double? rawBottom,
    FaceLandmarks landmarks = const FaceLandmarks(
      leftEye: math.Point(240, 240),
      rightEye: math.Point(360, 240),
      nose: math.Point(300, 300),
      leftMouth: math.Point(260, 360),
      rightMouth: math.Point(340, 360),
    ),
  }) => FaceDetection(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    rawLeft: rawLeft,
    rawTop: rawTop,
    rawRight: rawRight,
    rawBottom: rawBottom,
    confidence: confidence,
    landmarks: landmarks,
  );

  test('classifies a face as full only when every boundary passes', () {
    final result = FaceBiometricPipeline.measureFaceCompleteness(face());
    expect(result.label, 'FULL');
    expect(result.value, 1);
    expect(result.geometryScore, 1);
  });

  test('classifies geometry 0.75 as partial even with value 0.95', () {
    final result = FaceBiometricPipeline.measureFaceCompleteness(
      face(
        landmarks: const FaceLandmarks(
          leftEye: math.Point(240, 240),
          rightEye: math.Point(360, 240),
          nose: math.Point(300, 380),
          leftMouth: math.Point(260, 360),
          rightMouth: math.Point(340, 360),
        ),
      ),
    );
    expect(result.geometryScore, 0.75);
    expect(result.value, closeTo(0.95, 0.000001));
    expect(result.label, 'PARTIAL');
  });

  test('classifies confidence below 0.83 as partial', () {
    final result = FaceBiometricPipeline.measureFaceCompleteness(
      face(confidence: 0.829),
    );
    expect(result.label, 'PARTIAL');
  });

  test('classifies a far face as partial', () {
    final result = FaceBiometricPipeline.measureFaceCompleteness(
      face(right: 280, bottom: 280),
    );
    expect(result.label, 'PARTIAL');
  });

  test('classifies bbox visibility below 0.995 as partial', () {
    final result = FaceBiometricPipeline.measureFaceCompleteness(
      face(left: 0, rawLeft: -20, rawRight: 420),
    );
    expect(result.boundingBoxVisibleFraction, lessThan(0.995));
    expect(result.label, 'PARTIAL');
  });
}
