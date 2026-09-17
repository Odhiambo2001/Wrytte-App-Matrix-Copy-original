import 'package:flutter/foundation.dart';

/// Duration-only diagnostics. Stage names must never include user data.
class BiometricStageTiming {
  static T measure<T>(String pipeline, String stage, T Function() action) {
    final timer = Stopwatch()..start();
    var success = false;
    try {
      final result = action();
      success = true;
      return result;
    } finally {
      log(pipeline, stage, timer, success: success);
    }
  }

  static Future<T> measureAsync<T>(
    String pipeline,
    String stage,
    Future<T> Function() action,
  ) async {
    final timer = Stopwatch()..start();
    var success = false;
    try {
      final result = await action();
      success = true;
      return result;
    } finally {
      log(pipeline, stage, timer, success: success);
    }
  }

  static void log(
    String pipeline,
    String stage,
    Stopwatch timer, {
    bool success = true,
  }) {
    timer.stop();
    debugPrint(
      '[BiometricTiming] pipeline=$pipeline stage=$stage '
      'elapsed_ms=${timer.elapsedMilliseconds} '
      'outcome=${success ? 'completed' : 'error'}',
    );
  }
}
