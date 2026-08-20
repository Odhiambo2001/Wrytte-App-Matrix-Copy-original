import 'dart:io';

import 'package:flutter/services.dart';

/// Plays the supervisory ringing sound heard by an outgoing caller.
class CallerRingbackService {
  CallerRingbackService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.wrytte/caller_ringback',
  );

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('start');
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stop');
  }
}
