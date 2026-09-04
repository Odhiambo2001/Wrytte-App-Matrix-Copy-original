import 'package:flutter/foundation.dart';

/// In-memory, duration-only measurement for a new biometric enrollment.
/// It deliberately has no identity, token, image, score, or embedding data.
class BiometricEnrollmentTiming {
  BiometricEnrollmentTiming._();

  static Stopwatch? _timer;

  static void start() {
    _timer = Stopwatch()..start();
  }

  static void cancel() {
    _timer?.stop();
    _timer = null;
  }

  static void logHomeNavigation() {
    final timer = _timer;
    if (timer == null) return;
    timer.stop();
    debugPrint(
      '[BiometricTiming] stage=enrollment_capture_to_home_navigation '
      'elapsed_ms=${timer.elapsedMilliseconds}',
    );
    _timer = null;
  }
}
