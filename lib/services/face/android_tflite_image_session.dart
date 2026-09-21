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
  String? lastFrameProvider;
  double? lastNativeTotalMilliseconds;
  double? lastInvokeMilliseconds;

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

  Future<List<Map<String, dynamic>>> runBgr({
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
    lastFrameProvider = value['executionProvider'] as String?;
    lastNativeTotalMilliseconds =
        (value['nativeTotalMs'] as num?)?.toDouble();
    lastInvokeMilliseconds = (value['invokeMs'] as num?)?.toDouble();
    final faces = value['faces'];
    if (faces is! List) {
      throw StateError('Native LiteRT inference did not return face results.');
    }
    return faces
        .map((face) => Map<String, dynamic>.from(face as Map))
        .toList(growable: false);
  }

  Future<void> close() => _channel.invokeMethod<void>(
    'closeSession',
    <String, Object>{'sessionId': id},
  );
}
