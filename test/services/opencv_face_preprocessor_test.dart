import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/opencv_face_preprocessor.dart';

void main() {
  test('shifts a V1SE crop down to preserve context at the top edge', () {
    final crop = OpenCvFacePreprocessor.calculateMiniFasNetCropBox(
      sourceWidth: 720,
      sourceHeight: 480,
      x: 300,
      y: 150,
      boxWidth: 120,
      boxHeight: 140,
      scale: 4.0,
    );

    expect(crop.left, 154);
    expect(crop.top, 0);
    expect(crop.right, 565);
    expect(crop.bottom, 479);
    expect(crop.height, 480);
  });

  test('shifts a V2 crop right to preserve context at the left edge', () {
    final crop = OpenCvFacePreprocessor.calculateMiniFasNetCropBox(
      sourceWidth: 720,
      sourceHeight: 480,
      x: 0,
      y: 100,
      boxWidth: 100,
      boxHeight: 100,
      scale: 2.7,
    );

    expect(crop.left, 0);
    expect(crop.right, 270);
    expect(crop.width, 271);
  });
}
