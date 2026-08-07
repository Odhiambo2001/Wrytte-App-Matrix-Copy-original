import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:wrytte/services/face/android_onnx_image_session.dart';

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
  OrtSession? _session;
  AndroidOnnxImageSession? _androidSession;
  late final Float32List _inputBuffer = Float32List(inputSize * inputSize * 3);
  late final List<_Prior> _priors = _createPriors();

  bool get isReady => _session != null || _androidSession != null;

  Future<void> initialize() async {
    if (_session != null || _androidSession != null) return;
    if (Platform.isAndroid) {
      _androidSession = await AndroidOnnxImageSession.create(modelAsset);
      _validateNames(_androidSession!.inputNames, _androidSession!.outputNames);
      return;
    }
    _session = await OnnxRuntime().createSessionFromAsset(
      modelAsset,
      options: OrtSessionOptions(intraOpNumThreads: 2),
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
    final tensorData = _toBgrTensor(resized);
    return _run(tensorData, image.width, image.height);
  }

  Future<List<FaceDetection>> detectBgr(Uint8List bgr) async {
    if (bgr.length != inputSize * inputSize * 3) {
      throw ArgumentError(
        'RetinaFace requires ${inputSize}x$inputSize BGR bytes.',
      );
    }
    final android = _androidSession;
    if (android != null) {
      final outputs = await android.runBgr(
        bgr: bgr,
        width: inputSize,
        height: inputSize,
        mode: 'retina',
      );
      return _decode(
        outputs['loc']!,
        outputs['conf']!,
        outputs['landmarks']!,
        inputSize,
        inputSize,
      );
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
    return _run(tensorData, inputSize, inputSize);
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
      final locations = _numbers(await outputs['loc']!.asFlattenedList());
      final scores = _numbers(await outputs['conf']!.asFlattenedList());
      final landmarks = _numbers(await outputs['landmarks']!.asFlattenedList());
      return _decode(locations, scores, landmarks, outputWidth, outputHeight);
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
    final session = _session;
    final android = _androidSession;
    _session = null;
    _androidSession = null;
    await Future.wait([
      if (session != null) session.close(),
      if (android != null) android.close(),
    ]);
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
    List<double> locations,
    List<double> scores,
    List<double> landmarkValues,
    int originalWidth,
    int originalHeight,
  ) {
    final count = math.min(
      _priors.length,
      math.min(locations.length ~/ 4, scores.length ~/ 2),
    );
    final candidates = <FaceDetection>[];
    for (var index = 0; index < count; index++) {
      final confidence = scores[(index * 2) + 1];
      if (confidence < confidenceThreshold) continue;

      final prior = _priors[index];
      final locationOffset = index * 4;
      final centerX =
          prior.centerX + locations[locationOffset] * 0.1 * prior.width;
      final centerY =
          prior.centerY + locations[locationOffset + 1] * 0.1 * prior.height;
      final width = prior.width * math.exp(locations[locationOffset + 2] * 0.2);
      final height =
          prior.height * math.exp(locations[locationOffset + 3] * 0.2);
      final rawLeft = (centerX - width / 2) * originalWidth;
      final rawTop = (centerY - height / 2) * originalHeight;
      final rawRight = (centerX + width / 2) * originalWidth;
      final rawBottom = (centerY + height / 2) * originalHeight;

      math.Point<double> landmark(int point) {
        final offset = (index * 10) + (point * 2);
        return math.Point<double>(
          (prior.centerX + landmarkValues[offset] * 0.1 * prior.width) *
              originalWidth,
          (prior.centerY + landmarkValues[offset + 1] * 0.1 * prior.height) *
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

  List<_Prior> _createPriors() {
    final priors = <_Prior>[];
    for (var level = 0; level < _steps.length; level++) {
      final step = _steps[level];
      final featureSize = (inputSize / step).ceil();
      for (var y = 0; y < featureSize; y++) {
        for (var x = 0; x < featureSize; x++) {
          for (final minSize in _minSizes[level]) {
            priors.add(
              _Prior(
                centerX: (x + 0.5) * step / inputSize,
                centerY: (y + 0.5) * step / inputSize,
                width: minSize / inputSize,
                height: minSize / inputSize,
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

  static List<double> _numbers(List<dynamic> values) =>
      values.map((value) => (value as num).toDouble()).toList(growable: false);
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
