import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Android-only CameraX scanner transport.
///
/// CameraX owns the preview and ImageAnalysis use cases.  In particular it
/// never sends a 640x640 image through Dart: the event contains only decoded
/// RetinaFace geometry and an opaque native frame id.  Dart later asks native
/// code for the 80x80 liveness crop or final JPEG for that id.
class NativeFaceCamera {
  NativeFaceCamera._();

  static const _events = EventChannel(
    'com.example.wrytte/native_face_camera/events',
  );
  static const _control = MethodChannel(
    'com.example.wrytte/native_face_camera',
  );

  static Stream<Map<String, dynamic>> get events {
    if (!Platform.isAndroid) return const Stream.empty();
    return _events.receiveBroadcastStream().map(
      (event) => Map<String, dynamic>.from(event as Map),
    );
  }

  static Future<void> stop() async {
    if (Platform.isAndroid) {
      await _control.invokeMethod<void>('stop');
    }
  }

  static Future<void> reset() async {
    if (Platform.isAndroid) await _control.invokeMethod<void>('reset');
  }

  static Future<Map<String, dynamic>> livenessCrop({
    required int frameId,
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) async => Map<String, dynamic>.from(
    await _control.invokeMapMethod<String, dynamic>('livenessCrop', {
          'frameId': frameId,
          'left': left,
          'top': top,
          'right': right,
          'bottom': bottom,
        }) ??
        const <String, dynamic>{},
  );

  static Future<Uint8List> takeJpeg(int frameId) async {
    final bytes = await _control.invokeMethod<Uint8List>('takeJpeg', {
      'frameId': frameId,
    });
    if (bytes == null)
      throw StateError('Native RetinaFace frame is unavailable.');
    return bytes;
  }

  static Future<void> discard(int frameId) async {
    if (Platform.isAndroid) {
      await _control.invokeMethod<void>('discard', {'frameId': frameId});
    }
  }
}

class NativeFaceCameraPreview extends StatelessWidget {
  const NativeFaceCameraPreview({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.expand();
    return const AndroidView(
      viewType: 'com.example.wrytte/native_face_camera/preview',
      layoutDirection: TextDirection.ltr,
    );
  }
}
