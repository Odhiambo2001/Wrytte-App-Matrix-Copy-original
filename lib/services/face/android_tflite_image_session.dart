import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Android LiteRT bridge for the GPU-first RetinaFace model.
///
/// Pixels remain compact BGR bytes until they reach Android; the native side
/// applies the model's RetinaFace normalization and NHWC tensor layout.
class AndroidTfliteImageSession {
  AndroidTfliteImageSession._({
    required this.id,
    required this.executionProvider,
  });

  static const _channel = MethodChannel('com.example.wrytte/tflite_image');

  final String id;
  final String executionProvider;

  static Future<AndroidTfliteImageSession> create(
    String asset, {
    int threads = 4,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'createRetinaFaceSession',
      <String, Object>{'asset': asset, 'threads': threads},
    );
    if (value == null) {
      throw StateError('Native LiteRT session was not created.');
    }
    return AndroidTfliteImageSession._(
      id: value['sessionId'] as String,
      executionProvider: value['executionProvider'] as String? ?? 'cpu',
    );
  }

  Future<Map<String, Float32List>> runBgr({
    required Uint8List bgr,
    required int width,
    required int height,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>('runBgr', {
      'sessionId': id,
      'bgr': bgr,
      'width': width,
      'height': height,
    });
    if (value == null) {
      throw StateError('Native LiteRT inference returned null.');
    }
    return value.map((name, data) {
      if (data is Float32List) return MapEntry(name, data);
      return MapEntry(
        name,
        Float32List.fromList(
          List<num>.from(data).map((value) => value.toDouble()).toList(),
        ),
      );
    });
  }

  Future<void> close() => _channel.invokeMethod<void>(
    'closeSession',
    <String, Object>{'sessionId': id},
  );
}
