import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/biometric_stage_timing.dart';

void main() {
  test('local total excludes network, waits and nested inference timing', () {
    final total = FrontendTimingTotal();
    total.record('FaceFrame', 'processing', const Duration(seconds: 2));
    total.record('MiniFASNet', 'inference', const Duration(seconds: 1));
    total.record('Upload', 'jpeg_encoding', const Duration(milliseconds: 500));
    total.record(
      'Upload',
      'batch_to_backend_acceptance',
      const Duration(seconds: 25),
    );
    total.record('UI', 'completion_wait', const Duration(seconds: 3));
    expect(total.totalMicroseconds, 2500000);
  });

  test('late work stays attributed to its original attempt', () async {
    final first = FrontendTimingTotal();
    final second = FrontendTimingTotal();
    await first.run(() async {
      await Future<void>.value();
      BiometricStageTiming.log(
        'Camera',
        'convert_and_rotate',
        Stopwatch()..start(),
      );
      expect(
        identical(first, Zone.current[FrontendTimingTotal.zoneKey]),
        isTrue,
      );
    });
    expect(second.totalMicroseconds, 0);
  });
}
