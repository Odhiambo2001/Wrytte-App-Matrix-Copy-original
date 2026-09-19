import 'dart:io';
import 'package:wrytte/services/face/android_onnx_image_session.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

class FaceLandmarks {
  const FaceLandmarks({
    required this.leftEye,
    required this.rightEye,
    required this.nose,
    required this.leftMouth,
    required this.rightMouth,
  });

  final math.Point<double> leftEye;
  final math.Point<double> rightEye;
  final math.Point<double> nose;
  final math.Point<double> leftMouth;
  final math.Point<double> rightMouth;
}

class FaceDetection {
  const FaceDetection({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.confidence,
    required this.landmarks,
    this.rawLeft,
    this.rawTop,
    this.rawRight,
    this.rawBottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;
  final FaceLandmarks landmarks;
  final double? rawLeft;
  final double? rawTop;
  final double? rawRight;
  final double? rawBottom;

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
}

/// Runs the bundled MobileNetV2 RetinaFace model.
///
/// Detection coordinates are returned in the original image's pixel space.
class RetinaFaceDetector {
  RetinaFaceDetector({
    this.inputSize = 640,
    this.confidenceThreshold = 0.60,
    this.nmsThreshold = 0.40,
    this.inferenceThreads = 4,
  });

  static const modelAsset = 'assets/models/retinaface_mv2.onnx';
  static const _steps = [8, 16, 32];
  static const _minSizes = [
    [16, 32],
    [64, 128],
    [256, 512],
  ];

  final int inputSize;
  final double confidenceThreshold;
  final double nmsThreshold;
  final int inferenceThreads;
  OrtSession? _session;
  AndroidOnnxImageSession? _android;
  late final Float32List _inputBuffer = Float32List(inputSize * inputSize * 3);
  final Map<int, List<_Prior>> _priorsBySize = {};

  bool get isReady => _session != null || _android != null;

  Future<void> initialize() async {
    if (isReady) return;
    if (Platform.isAndroid) {
      // RetinaFace is the dominant scan cost. The native bridge caps this to
      // available cores; four intra-op threads materially reduce latency on
      // current Android devices while preserving the required BGR contract.
      _android = await AndroidOnnxImageSession.create(
        modelAsset,
        threads: inferenceThreads,
        requireHardwareAcceleration: true,
      );
      // ignore: avoid_print
      print(
        '[BiometricTiming] pipeline=RetinaFace '
        'stage=execution_provider provider=${_android!.executionProvider}',
      );
      try {
        _validateNames(_android!.inputNames, _android!.outputNames);
      } catch (_) {
        await _android!.close();
        _android = null;
        rethrow;
      }
      return;
    }
    // Preprocessing supplies packed BGR pixels for this model's NCHW input.
    // The Android ONNX Runtime binary bundled with this app aborts during
    // XNNPACK session creation on the Redmi 25028RN03A. Keep the compatible
    // CPU provider and use four intra-op threads for this single inference.
    _session = await OnnxRuntime().createSessionFromAsset(
      modelAsset,
      options: OrtSessionOptions(
        intraOpNumThreads: inferenceThreads,
        interOpNumThreads: 1,
        providers: const <OrtProvider>[OrtProvider.CPU],
        useArena: true,
      ),
    );
    final session = _session!;
    try {
      _validateNames(session.inputNames, session.outputNames);
    } catch (_) {
      await session.close();
      _session = null;
      rethrow;
    }
  }

  Future<List<FaceDetection>> detect(img.Image image) async {
    final resized = img.copyResize(
      image,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.linear,
    );
    if (_android != null) {
      final bytes = resized.getBytes(order: img.ChannelOrder.bgr);
      try {
        return await detectBgr(bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    }
    final tensorData = _toBgrTensor(resized);
    return _run(tensorData, image.width, image.height);
  }

  Future<List<FaceDetection>> detectBgr(Uint8List bgr) async {
    if (bgr.length != inputSize * inputSize * 3) {
      throw ArgumentError(
        'RetinaFace requires a ${inputSize}x$inputSize packed BGR image; '
        'received ${bgr.length} bytes.',
      );
    }
    final android = _android;
    if (android != null) {
      final outputs = await android.runBgr(
        bgr: bgr,
        width: inputSize,
        height: inputSize,
        mode: 'retina',
      );
      try {
        return _decode(
          outputs['loc']!,
          outputs['conf']!,
          outputs['landmarks']!,
          inputSize,
          inputSize,
          _priorsForSize(inputSize),
        );
      } finally {
        for (final output in outputs.values) {
          output.fillRange(0, output.length, 0);
        }
      }
    }
    final plane = inputSize * inputSize;
    // Reuse the ~4.7 MiB RetinaFace tensor instead of allocating it for every
    // camera frame. Frames are processed serially by the scan page.
    final tensorData = _inputBuffer;
    for (var pixel = 0; pixel < plane; pixel++) {
      final offset = pixel * 3;
      tensorData[pixel] = bgr[offset].toDouble() - 104.0;
      tensorData[plane + pixel] = bgr[offset + 1].toDouble() - 117.0;
      tensorData[(plane * 2) + pixel] = bgr[offset + 2].toDouble() - 123.0;
    }
    try {
      return await _run(tensorData, inputSize, inputSize);
    } finally {
      tensorData.fillRange(0, tensorData.length, 0);
    }
  }

  double _bestFaceConfidence(List<dynamic>? values) {
    if (values == null) return 0;
    var best = 0.0;
    for (var i = 1; i < values.length; i += 2) {
      final value = (values[i] as num).toDouble();
      if (value > best) best = value;
    }
    return best;
  }

  Future<List<FaceDetection>> _run(
    Float32List tensorData,
    int outputWidth,
    int outputHeight,
  ) async {
    final session = _session;
    if (session == null) {
      throw StateError('RetinaFaceDetector.initialize() must be called first.');
    }
    final input = await OrtValue.fromList(tensorData, [
      1,
      3,
      inputSize,
      inputSize,
    ]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({'input': input});
      final locations = await outputs['loc']!.asFlattenedList();
      final scores = await outputs['conf']!.asFlattenedList();
      final landmarks = await outputs['landmarks']!.asFlattenedList();
      // ignore: avoid_print
      print(
        '[BiometricTiming] pipeline=RetinaFace stage=onnx_diagnostics '
        'input_floats=${tensorData.length} loc=${locations.length} '
        'conf=${scores.length} landmarks=${landmarks.length} '
        'best_face_conf=${_bestFaceConfidence(scores).toStringAsFixed(4)}',
      );
      return _decode(
        locations,
        scores,
        landmarks,
        outputWidth,
        outputHeight,
        _priorsForSize(inputSize),
      );
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final value in outputs.values) {
          await value.dispose();
        }
      }
    }
  }

  Future<void> dispose() async {
    final android = _android;
    _android = null;
    if (android != null) await android.close();
    final session = _session;
    _session = null;
    await Future.wait([if (session != null) session.close()]);
  }

  static void _validateNames(List<String> inputs, List<String> outputs) {
    if (!inputs.contains('input') ||
        !outputs.toSet().containsAll(const {'loc', 'conf', 'landmarks'})) {
      throw StateError(
        'Unexpected RetinaFace tensors. Expected input and '
        'loc/conf/landmarks outputs.',
      );
    }
  }

  Float32List _toBgrTensor(img.Image image) {
    final plane = inputSize * inputSize;
    final result = Float32List(plane * 3);
    var pixelIndex = 0;
    for (var y = 0; y < inputSize; y++) {
      for (var x = 0; x < inputSize; x++) {
        final pixel = image.getPixel(x, y);
        // This RetinaFace export uses BGR and the common RetinaFace means.
        result[pixelIndex] = pixel.b.toDouble() - 104.0;
        result[plane + pixelIndex] = pixel.g.toDouble() - 117.0;
        result[(plane * 2) + pixelIndex] = pixel.r.toDouble() - 123.0;
        pixelIndex++;
      }
    }
    return result;
  }

  List<FaceDetection> _decode(
    List<dynamic> locations,
    List<dynamic> scores,
    List<dynamic> landmarkValues,
    int originalWidth,
    int originalHeight,
    List<_Prior> priors,
  ) {
    double valueAt(List<dynamic> values, int index) =>
        (values[index] as num).toDouble();
    final count = math.min(
      priors.length,
      math.min(locations.length ~/ 4, scores.length ~/ 2),
    );
    final candidates = <FaceDetection>[];
    for (var index = 0; index < count; index++) {
      final confidence = valueAt(scores, (index * 2) + 1);
      if (confidence < confidenceThreshold) continue;

      final prior = priors[index];
      final locationOffset = index * 4;
      final centerX =
          prior.centerX +
          valueAt(locations, locationOffset) * 0.1 * prior.width;
      final centerY =
          prior.centerY +
          valueAt(locations, locationOffset + 1) * 0.1 * prior.height;
      final width =
          prior.width * math.exp(valueAt(locations, locationOffset + 2) * 0.2);
      final height =
          prior.height * math.exp(valueAt(locations, locationOffset + 3) * 0.2);
      final rawLeft = (centerX - width / 2) * originalWidth;
      final rawTop = (centerY - height / 2) * originalHeight;
      final rawRight = (centerX + width / 2) * originalWidth;
      final rawBottom = (centerY + height / 2) * originalHeight;

      math.Point<double> landmark(int point) {
        final offset = (index * 10) + (point * 2);
        return math.Point<double>(
          (prior.centerX +
                  valueAt(landmarkValues, offset) * 0.1 * prior.width) *
              originalWidth,
          (prior.centerY +
                  valueAt(landmarkValues, offset + 1) * 0.1 * prior.height) *
              originalHeight,
        );
      }

      candidates.add(
        FaceDetection(
          left: rawLeft.clamp(0.0, originalWidth.toDouble()),
          top: rawTop.clamp(0.0, originalHeight.toDouble()),
          right: rawRight.clamp(0.0, originalWidth.toDouble()),
          bottom: rawBottom.clamp(0.0, originalHeight.toDouble()),
          confidence: confidence,
          rawLeft: rawLeft,
          rawTop: rawTop,
          rawRight: rawRight,
          rawBottom: rawBottom,
          landmarks: FaceLandmarks(
            leftEye: landmark(0),
            rightEye: landmark(1),
            nose: landmark(2),
            leftMouth: landmark(3),
            rightMouth: landmark(4),
          ),
        ),
      );
    }

    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    final selected = <FaceDetection>[];
    for (final candidate in candidates) {
      if (selected.every((face) => _iou(candidate, face) <= nmsThreshold)) {
        selected.add(candidate);
      }
    }
    return selected;
  }

  List<_Prior> _priorsForSize(int size) =>
      _priorsBySize.putIfAbsent(size, () => _createPriors(size));

  List<_Prior> _createPriors(int size) {
    final priors = <_Prior>[];
    for (var level = 0; level < _steps.length; level++) {
      final step = _steps[level];
      final featureSize = (size / step).ceil();
      for (var y = 0; y < featureSize; y++) {
        for (var x = 0; x < featureSize; x++) {
          for (final minSize in _minSizes[level]) {
            priors.add(
              _Prior(
                centerX: (x + 0.5) * step / size,
                centerY: (y + 0.5) * step / size,
                width: minSize / size,
                height: minSize / size,
              ),
            );
          }
        }
      }
    }
    return priors;
  }

  static double _iou(FaceDetection a, FaceDetection b) {
    final intersectionWidth = math.max(
      0.0,
      math.min(a.right, b.right) - math.max(a.left, b.left),
    );
    final intersectionHeight = math.max(
      0.0,
      math.min(a.bottom, b.bottom) - math.max(a.top, b.top),
    );
    final intersection = intersectionWidth * intersectionHeight;
    final union = (a.width * a.height) + (b.width * b.height) - intersection;
    return union <= 0 ? 0 : intersection / union;
  }
}

class _Prior {
  const _Prior({
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
  });

  final double centerX;
  final double centerY;
  final double width;
  final double height;
}
