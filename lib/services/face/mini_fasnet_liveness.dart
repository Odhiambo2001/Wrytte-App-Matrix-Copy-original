import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

class MiniFasNetScore {
  const MiniFasNetScore({required this.probabilities});

  /// Class 1 is Real; classes 0 and 2 are presentation attacks.
  final List<double> probabilities;

  double get realProbability => probabilities[1];
  double get fakeProbability => probabilities[0] + probabilities[2];
  int get labelIndex {
    var best = 0;
    for (var index = 1; index < probabilities.length; index++) {
      if (probabilities[index] > probabilities[best]) best = index;
    }
    return best;
  }

  bool get isReal => labelIndex == 1;
}

class DualLivenessResult {
  const DualLivenessResult({required this.v2, required this.v1se});

  final MiniFasNetScore v2;
  final MiniFasNetScore v1se;

  /// Conservative two-model rule: neither model may classify the face fake.
  bool get isReal => v2.isReal && v1se.isReal;
  double get combinedRealProbability =>
      math.min(v2.realProbability, v1se.realProbability);
}

/// Passive presentation-attack detection matching yakhyo/face-anti-spoofing.
///
/// Inputs are raw FP32 BGR pixels in NCHW layout. The model produces three
/// logits; softmax converts them to probabilities and class 1 means Real.
class MiniFasNetLiveness {
  static const inputSize = 80;
  static const v2ModelAsset = 'assets/models/MiniFASNetV2.onnx';
  static const v1seModelAsset = 'assets/models/MiniFASNetV1SE.onnx';
  static const v2CropScale = 2.7;
  static const v1seCropScale = 4.0;

  OrtSession? _v2Session;
  OrtSession? _v1seSession;

  Future<void> initialize() async {
    if (_v2Session != null && _v1seSession != null) return;
    final sessions = await Future.wait([
      OnnxRuntime().createSessionFromAsset(
        v2ModelAsset,
        options: OrtSessionOptions(intraOpNumThreads: 2),
      ),
      OnnxRuntime().createSessionFromAsset(
        v1seModelAsset,
        options: OrtSessionOptions(intraOpNumThreads: 2),
      ),
    ]);
    _v2Session = sessions[0];
    _v1seSession = sessions[1];
    try {
      _validate(_v2Session!, 'MiniFASNetV2');
      _validate(_v1seSession!, 'MiniFASNetV1SE');
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<DualLivenessResult> predict({
    required Uint8List v2FaceBgr,
    required Uint8List v1seFaceBgr,
  }) async {
    final v2 = _v2Session;
    final v1se = _v1seSession;
    if (v2 == null || v1se == null) {
      throw StateError('MiniFasNetLiveness.initialize() must be called first.');
    }
    final results = await Future.wait([
      _run(v2, v2FaceBgr),
      _run(v1se, v1seFaceBgr),
    ]);
    return DualLivenessResult(v2: results[0], v1se: results[1]);
  }

  Future<MiniFasNetScore> _run(OrtSession session, Uint8List faceBgr) async {
    if (faceBgr.length != inputSize * inputSize * 3) {
      throw ArgumentError('MiniFASNet requires an 80x80 BGR face crop.');
    }
    final plane = inputSize * inputSize;
    final tensor = Float32List(plane * 3);
    for (var pixel = 0; pixel < plane; pixel++) {
      final source = pixel * 3;
      tensor[pixel] = faceBgr[source].toDouble();
      tensor[plane + pixel] = faceBgr[source + 1].toDouble();
      tensor[(plane * 2) + pixel] = faceBgr[source + 2].toDouble();
    }
    final input = await OrtValue.fromList(tensor, [1, 3, inputSize, inputSize]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({session.inputNames.first: input});
      final raw = await outputs[session.outputNames.first]!.asFlattenedList();
      final logits = raw.map((value) => (value as num).toDouble()).toList();
      if (logits.length != 3) {
        throw StateError('MiniFASNet returned ${logits.length} values, not 3.');
      }
      return MiniFasNetScore(probabilities: _softmax(logits));
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    }
  }

  static List<double> _softmax(List<double> logits) {
    final maximum = logits.reduce(math.max);
    final exponentials =
        logits.map((value) => math.exp(value - maximum)).toList();
    final total = exponentials.fold<double>(0, (sum, value) => sum + value);
    return exponentials.map((value) => value / total).toList(growable: false);
  }

  static void _validate(OrtSession session, String modelName) {
    if (session.inputNames.length != 1 || session.outputNames.length != 1) {
      throw StateError(
        '$modelName must have exactly one input and one output.',
      );
    }
  }

  Future<void> dispose() async {
    final v2 = _v2Session;
    final v1se = _v1seSession;
    _v2Session = null;
    _v1seSession = null;
    await Future.wait([
      if (v2 != null) v2.close(),
      if (v1se != null) v1se.close(),
    ]);
  }
}
