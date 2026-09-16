import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Android ONNX bridge optimized for image models.
///
/// Only compact Uint8 BGR pixels cross the platform channel. NCHW conversion
/// and Float32 normalization happen next to ONNX Runtime on Android.
class AndroidOnnxImageSession {
  AndroidOnnxImageSession._({
    required this.id,
    required this.inputNames,
    required this.outputNames,
  });

  static const _channel = MethodChannel('com.example.wrytte/onnx_image');

  final String id;
  final List<String> inputNames;
  final List<String> outputNames;

  static Future<AndroidOnnxImageSession> create(
    String asset, {
    // RetinaFace inference is CPU-bound on Android. Four workers materially
    // improve throughput on modern phones while avoiding excessive contention
    // on smaller devices. The native side caps this to the available cores.
    int threads = 4,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'createSession',
      {'asset': asset, 'threads': threads},
    );
    if (value == null) throw StateError('Native ONNX session was not created.');
    return AndroidOnnxImageSession._(
      id: value['sessionId'] as String,
      inputNames: List<String>.from(value['inputNames'] as List),
      outputNames: List<String>.from(value['outputNames'] as List),
    );
  }

  Future<Map<String, Float32List>> runBgr({
    required Uint8List bgr,
    required int width,
    required int height,
    required String mode,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>('runBgr', {
      'sessionId': id,
      'inputName': inputNames.first,
      'bgr': bgr,
      'width': width,
      'height': height,
      'mode': mode,
    });
    if (value == null) throw StateError('Native ONNX inference returned null.');
    return value.map((name, data) {
      if (data is Float32List) return MapEntry(name, data);
      return MapEntry(
        name,
        Float32List.fromList(
          List<num>.from(data).map((v) => v.toDouble()).toList(),
        ),
      );
    });
  }

  Future<void> close() =>
      _channel.invokeMethod<void>('closeSession', {'sessionId': id});
}
