import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/biometric_api_service.dart';

void main() {
  test('keeps a 1280x720 liveness frame at its capture size', () {
    expect(BiometricApiService.livenessTargetSize(1280, 720), (1280, 720));
  });

  test('constrains a larger device frame to the backend pixel limit', () {
    final size = BiometricApiService.livenessTargetSize(1280, 960);

    expect(size.$1, lessThanOrEqualTo(1280));
    expect(size.$2, lessThanOrEqualTo(1280));
    expect(size.$1 * size.$2, lessThanOrEqualTo(921600));
  });

  test(
    'rescales a liveness face box with inclusive right and bottom edges',
    () {
      final scaled = BiometricApiService.scaleLivenessFaceBox(
        const {'x': 128, 'y': 96, 'width': 256, 'height': 192},
        sourceWidth: 1280,
        sourceHeight: 960,
        targetWidth: 1108,
        targetHeight: 831,
      );

      expect(scaled, const {'x': 110, 'y': 83, 'width': 223, 'height': 167});
    },
  );
}
