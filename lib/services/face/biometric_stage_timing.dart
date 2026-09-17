import 'dart:async';

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
    (Zone.current[FrontendTimingTotal.zoneKey] as FrontendTimingTotal?)?.record(
      pipeline,
      stage,
      timer.elapsed,
    );
    debugPrint(
      '[BiometricTiming] pipeline=$pipeline stage=$stage '
      'elapsed_ms=${timer.elapsedMilliseconds} '
      'outcome=${success ? 'completed' : 'error'}',
    );
  }
}

/// Sum of non-overlapping, instrumented local stages, not CPU time or scan
/// wall time. Network calls, UI waits and nested inference timers are excluded.
class FrontendTimingTotal {
  static final zoneKey = Object();
  static const localStages = {
    'Models.initialize',
    'Camera.enumerate',
    'Camera.initialize',
    'Camera.convert_and_rotate',
    'Camera.stop_stream',
    'FaceFrame.processing',
    'Upload.jpeg_encoding',
    'Upload.device_metadata',
    'Verification.sign_challenge',
    'LDPC.local_enrollment',
    'LDPC.local_recovery',
  };
  final Map<String, int> _microseconds = {};

  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {zoneKey: this});

  void record(String pipeline, String stage, Duration elapsed) {
    final key = '$pipeline.$stage';
    if (!localStages.contains(key)) return;
    _microseconds.update(
      key,
      (value) => value + elapsed.inMicroseconds,
      ifAbsent: () => elapsed.inMicroseconds,
    );
  }

  int get totalMicroseconds =>
      _microseconds.values.fold(0, (sum, value) => sum + value);

  void log(String destination) {
    debugPrint(
      '[BiometricTiming] pipeline=FE stage=local_processing_total '
      'destination=$destination elapsed_ms=${totalMicroseconds ~/ 1000} '
      'elapsed_seconds=${(totalMicroseconds / 1000000).toStringAsFixed(3)} '
      'scope=instrumented_local_stages excludes=network_ui_waits_background '
      'breakdown_ms=${_microseconds.map((key, value) => MapEntry(key, value ~/ 1000))}',
    );
  }
}
