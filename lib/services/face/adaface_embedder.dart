import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

class AdaFaceEmbedder {
  static const modelAsset = 'assets/models/adaface_ir_101.onnx';
  static const faceSize = 112;
  static const embeddingSize = 512;

  OrtSession? _session;

  Future<void> initialize() async {
    if (_session != null) return;
    _session = await OnnxRuntime().createSessionFromAsset(
      modelAsset,
      options: OrtSessionOptions(intraOpNumThreads: 2),
    );
  }

  Future<Float32List> embed(Uint8List faceBgr) async {
    final session = _session;
    if (session == null) {
      throw StateError('AdaFaceEmbedder.initialize() must be called first.');
    }
    if (faceBgr.length != faceSize * faceSize * 3) {
      throw ArgumentError('AdaFace requires a 112x112 BGR face.');
    }

    final plane = faceSize * faceSize;
    final inputData = Float32List(plane * 3);
    for (var pixel = 0; pixel < plane; pixel++) {
      final source = pixel * 3;
      // BGR -> RGB and (value / 255 - .5) / .5.
      inputData[pixel] = (faceBgr[source + 2] / 127.5) - 1.0;
      inputData[plane + pixel] = (faceBgr[source + 1] / 127.5) - 1.0;
      inputData[(plane * 2) + pixel] = (faceBgr[source] / 127.5) - 1.0;
    }

    final input = await OrtValue.fromList(inputData, [
      1,
      3,
      faceSize,
      faceSize,
    ]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({session.inputNames.first: input});
      final values =
          await outputs[session.outputNames.first]!.asFlattenedList();
      return normalize(
        Float32List.fromList(
          values.map((value) => (value as num).toDouble()).toList(),
        ),
      );
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    }
  }

  Float32List average(List<Float32List> embeddings) {
    if (embeddings.isEmpty) throw ArgumentError('No embeddings supplied.');
    final result = Float32List(embeddingSize);
    for (final embedding in embeddings) {
      if (embedding.length != embeddingSize) {
        throw ArgumentError('Expected a $embeddingSize-value embedding.');
      }
      for (var index = 0; index < embeddingSize; index++) {
        result[index] += embedding[index];
      }
    }
    for (var index = 0; index < embeddingSize; index++) {
      result[index] /= embeddings.length;
    }
    return normalize(result);
  }

  Float32List normalize(Float32List values) {
    var squaredNorm = 0.0;
    for (final value in values) {
      squaredNorm += value * value;
    }
    final norm = math.sqrt(squaredNorm);
    if (norm < 1e-10) throw StateError('Embedding has near-zero norm.');
    return Float32List.fromList(values.map((value) => value / norm).toList());
  }

  Future<void> dispose() async {
    final session = _session;
    _session = null;
    await session?.close();
  }
}
