import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:wrytte/services/face/android_onnx_image_session.dart';

class MiniFasNetScore {
  const MiniFasNetScore({required this.probabilities});

  static const double realThreshold = 0.50;

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

  /// A model passes only when its class-1 (Real) probability is strictly
  /// greater than 50%. Exactly 50% is rejected.
  bool get isReal => realProbability > realThreshold;
}

class DualLivenessResult {
  const DualLivenessResult({required this.v2, required this.v1se});

  final MiniFasNetScore v2;
  final MiniFasNetScore v1se;

  /// Both models must independently report more than 50% Real.
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
  AndroidOnnxImageSession? _androidV2Session;
  AndroidOnnxImageSession? _androidV1seSession;
  final Float32List _v2InputBuffer = Float32List(inputSize * inputSize * 3);
  final Float32List _v1seInputBuffer = Float32List(inputSize * inputSize * 3);

  Future<void> initialize() async {
    if ((_v2Session != null && _v1seSession != null) ||
        (_androidV2Session != null && _androidV1seSession != null)) {
      return;
    }
    if (Platform.isAndroid) {
      final sessions = await Future.wait([
        // Each model runs concurrently, so one thread per session avoids four
        // inference workers competing with RetinaFace and AdaFace.
        AndroidOnnxImageSession.create(v2ModelAsset, threads: 1),
        AndroidOnnxImageSession.create(v1seModelAsset, threads: 1),
      ]);
      _androidV2Session = sessions[0];
      _androidV1seSession = sessions[1];
      return;
    }
    final sessions = await Future.wait([
      OnnxRuntime().createSessionFromAsset(
        v2ModelAsset,
        options: OrtSessionOptions(intraOpNumThreads: 1),
      ),
      OnnxRuntime().createSessionFromAsset(
        v1seModelAsset,
        options: OrtSessionOptions(intraOpNumThreads: 1),
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
    final androidV2 = _androidV2Session;
    final androidV1se = _androidV1seSession;
    if (androidV2 != null && androidV1se != null) {
      final results = await Future.wait([
        _runAndroid(androidV2, v2FaceBgr, 'MiniFASNetV2'),
        _runAndroid(androidV1se, v1seFaceBgr, 'MiniFASNetV1SE'),
      ]);
      return DualLivenessResult(v2: results[0], v1se: results[1]);
    }
    final v2 = _v2Session;
    final v1se = _v1seSession;
    if (v2 == null || v1se == null) {
      throw StateError('MiniFasNetLiveness.initialize() must be called first.');
    }
    final results = await Future.wait([
      _run(v2, v2FaceBgr, _v2InputBuffer, 'MiniFASNetV2'),
      _run(v1se, v1seFaceBgr, _v1seInputBuffer, 'MiniFASNetV1SE'),
    ]);
    return DualLivenessResult(v2: results[0], v1se: results[1]);
  }

  Future<MiniFasNetScore> _runAndroid(
    AndroidOnnxImageSession session,
    Uint8List faceBgr,
    String modelName,
  ) async {
    final stopwatch = Stopwatch()..start();
    if (faceBgr.length != inputSize * inputSize * 3) {
      throw ArgumentError('MiniFASNet requires an 80x80 BGR face crop.');
    }
    final outputs = await session.runBgr(
      bgr: faceBgr,
      width: inputSize,
      height: inputSize,
      mode: 'mini_fas_rgb',
    );
    final logits = outputs[session.outputNames.first]!;
    if (logits.length != 3) {
      throw StateError('MiniFASNet returned ${logits.length} values, not 3.');
    }
    final score = MiniFasNetScore(probabilities: _softmax(logits));
    stopwatch.stop();
    debugPrint(
      '[KFace][Timing][LivenessModel] model=$modelName '
      'inferenceAndPostprocessMs=${stopwatch.elapsedMilliseconds}',
    );
    return score;
  }

  Future<MiniFasNetScore> _run(
    OrtSession session,
    Uint8List faceBgr,
    Float32List tensor,
    String modelName,
  ) async {
    final stopwatch = Stopwatch()..start();
    if (faceBgr.length != inputSize * inputSize * 3) {
      throw ArgumentError('MiniFASNet requires an 80x80 BGR face crop.');
    }
    final plane = inputSize * inputSize;
    for (var pixel = 0; pixel < plane; pixel++) {
      final source = pixel * 3;
      tensor[pixel] = faceBgr[source + 2].toDouble();
      tensor[plane + pixel] = faceBgr[source + 1].toDouble();
      tensor[(plane * 2) + pixel] = faceBgr[source].toDouble();
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
      final score = MiniFasNetScore(probabilities: _softmax(logits));
      stopwatch.stop();
      debugPrint(
        '[KFace][Timing][LivenessModel] model=$modelName '
        'tensorInferenceAndPostprocessMs=${stopwatch.elapsedMilliseconds}',
      );
      return score;
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
    if (logits.length != 3) {
      throw ArgumentError('MiniFASNet softmax requires exactly 3 logits.');
    }
    final maximum = math.max(logits[0], math.max(logits[1], logits[2]));
    final first = math.exp(logits[0] - maximum);
    final second = math.exp(logits[1] - maximum);
    final third = math.exp(logits[2] - maximum);
    final total = first + second + third;
    return <double>[first / total, second / total, third / total];
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
    final androidV2 = _androidV2Session;
    final androidV1se = _androidV1seSession;
    _v2Session = null;
    _v1seSession = null;
    _androidV2Session = null;
    _androidV1seSession = null;
    await Future.wait([
      if (v2 != null) v2.close(),
      if (v1se != null) v1se.close(),
      if (androidV2 != null) androidV2.close(),
      if (androidV1se != null) androidV1se.close(),
    ]);
  }
}
