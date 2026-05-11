// lib/utils/apk_debug_logger.dart
//
// A ring-buffer logger that keeps the last 200 lines in memory so they can
// be rendered in the APK UI without needing logcat.

import 'package:flutter/foundation.dart';

class ApkDebugLogger {
  ApkDebugLogger._();
  static final ApkDebugLogger instance = ApkDebugLogger._();

  static const int _maxLines = 200;
  final List<String> _lines = [];

  // Listeners are notified every time a line is added.
  final List<VoidCallback> _listeners = [];

  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);

  List<String> get lines => List.unmodifiable(_lines);

  void log(String tag, String msg) {
    final ts = DateTime.now();
    final stamp =
        '${ts.hour.toString().padLeft(2, '0')}:'
        '${ts.minute.toString().padLeft(2, '0')}:'
        '${ts.second.toString().padLeft(2, '0')}.'
        '${ts.millisecond.toString().padLeft(3, '0')}';
    final line = '[$stamp][$tag] $msg';

    // Also print to logcat for USB sessions.
    debugPrint(line);

    _lines.add(line);
    if (_lines.length > _maxLines) _lines.removeAt(0);

    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  void clear() {
    _lines.clear();
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }
}

// Convenience shortcut — use this everywhere.
final _log = ApkDebugLogger.instance;
void apkLog(String tag, String msg) => _log.log(tag, msg);
