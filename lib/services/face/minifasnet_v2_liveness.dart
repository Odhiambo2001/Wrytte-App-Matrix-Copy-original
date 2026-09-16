import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:wrytte/services/face/android_onnx_image_session.dart';

/// Frontend copy of the backend MiniFASNetV2 check.
/// The backend's class-1 softmax probability must exceed 0.50.
class MiniFasNetV2Liveness {
  static const modelAsset = 'assets/models/MiniFASNetV2.onnx';
  static const inputSize = 80;
  static const threshold = 0.50;

  OrtSession? _session;
  AndroidOnnxImageSession? _android;

  Future<void> initialize() async {
    if (_session != null || _android != null) return;
    if (Platform.isAndroid) {
      _android = await AndroidOnnxImageSession.create(modelAsset);
    } else {
      _session = await OnnxRuntime().createSessionFromAsset(
        modelAsset,
        options: OrtSessionOptions(intraOpNumThreads: 2),
      );
    }
  }

  Future<bool> isReal(Uint8List rgbBytes) async {
    if (rgbBytes.length != inputSize * inputSize * 3) {
      throw ArgumentError('MiniFASNetV2 requires an 80x80 RGB crop.');
    }
    final android = _android;
    if (android != null) {
      final output = await android.runBgr(
        bgr: rgbBytes,
        width: inputSize,
        height: inputSize,
        mode: 'mini_fas_rgb',
      );
      return _classOneProbability(output.values.first) > threshold;
    }
    final session = _session;
    if (session == null) throw StateError('MiniFASNetV2 is not initialized.');
    final plane = inputSize * inputSize;
    final tensor = Float32List(plane * 3);
    for (var i = 0; i < plane; i++) {
      tensor[i] = rgbBytes[i * 3].toDouble();
      tensor[plane + i] = rgbBytes[i * 3 + 1].toDouble();
      tensor[2 * plane + i] = rgbBytes[i * 3 + 2].toDouble();
    }
    final input = await OrtValue.fromList(tensor, [1, 3, inputSize, inputSize]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({session.inputNames.first: input});
      final values = await outputs.values.first.asFlattenedList();
      return _classOneProbability(
            Float32List.fromList(
              values.map<double>((v) => v.toDouble()).toList(),
            ),
          ) >
          threshold;
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final value in outputs.values) {
          await value.dispose();
        }
      }
    }
  }

  double _classOneProbability(Float32List logits) {
    if (logits.length != 3) throw StateError('Unexpected MiniFASNetV2 output.');
    final max = logits.reduce((a, b) => a > b ? a : b);
    final e0 = _exp(logits[0] - max),
        e1 = _exp(logits[1] - max),
        e2 = _exp(logits[2] - max);
    return e1 / (e0 + e1 + e2);
  }

  double _exp(double value) => math.exp(value);

  Future<void> dispose() async {
    final session = _session;
    final android = _android;
    _session = null;
    _android = null;
    if (session != null) await session.close();
    if (android != null) await android.close();
  }
}
