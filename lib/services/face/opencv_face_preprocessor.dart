import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:wrytte/services/face/retinaface_detector.dart';

class RetinaFrame {
  const RetinaFrame({
    required this.bgr,
    required this.originalBgr,
    required this.originalWidth,
    required this.originalHeight,
    required this.cropX,
    required this.cropY,
    required this.cropSide,
    required this.wasResized,
    required this.originalMat,
    required this.retinaMat,
    required this.sourceBuffer,
  });

  final Uint8List bgr;
  final Uint8List originalBgr;
  final int originalWidth;
  final int originalHeight;
  final int cropX;
  final int cropY;
  final int cropSide;
  final bool wasResized;
  final cv.Mat originalMat;
  final cv.Mat retinaMat;
  final ffi.Pointer<ffi.Uint8> sourceBuffer;

  void dispose() {
    retinaMat.dispose();
    originalMat.dispose();
    calloc.free(sourceBuffer);
  }
}

class AlignedFace {
  const AlignedFace({required this.bgr, required this.sharpness});

  final Uint8List bgr;
  final double sharpness;
}

class MiniFasNetCropBox {
  const MiniFasNetCropBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left + 1;
  int get height => bottom - top + 1;
}

class MiniFasNetCrops {
  const MiniFasNetCrops({
    required this.v2Bgr,
    required this.v1seBgr,
    required this.v2Box,
    required this.v1seBox,
  });

  final Uint8List v2Bgr;
  final Uint8List v1seBgr;
  final MiniFasNetCropBox v2Box;
  final MiniFasNetCropBox v1seBox;
}

class OpenCvFacePreprocessor {
  static const retinaSize = 640;
  static const faceSize = 112;
  static const _reference = <math.Point<double>>[
    math.Point(38.2946, 51.6963),
    math.Point(73.5318, 51.6963),
    math.Point(56.0252, 71.7366),
    math.Point(41.5493, 92.3655),
    math.Point(70.7299, 92.3655),
  ];

  ffi.Pointer<ffi.Uint8> _copyToOwnedSourceBuffer(Uint8List bytes) {
    final buffer = calloc<ffi.Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    return buffer;
  }

  RetinaFrame prepare(img.Image image) {
    final originalWidth = image.width;
    final originalHeight = image.height;
    // Keep the camera image's native RGB layout. Crop, resize and affine warp
    // are channel-agnostic; the Android tensor builder performs the final
    // channel placement next to ONNX Runtime. This removes a full-frame RGB
    // to BGR traversal and allocation from every analyzed frame.
    final bgr = image.toUint8List();

    final sourceBytes = _copyToOwnedSourceBuffer(bgr);
    final source = cv.Mat.fromBuffer(
      originalHeight,
      originalWidth,
      cv.MatType.CV_8UC3,
      sourceBytes.cast<ffi.Void>(),
    );
    final cropSide =
        originalWidth >= retinaSize && originalHeight >= retinaSize
            ? retinaSize
            : math.min(originalWidth, originalHeight);
    final cropX = (originalWidth - cropSide) ~/ 2;
    final cropY = (originalHeight - cropSide) ~/ 2;
    final roi = cv.Rect(cropX, cropY, cropSide, cropSide);
    // ROI matrices are lightweight views. resize reads them synchronously, so
    // copying the complete square before resizing is unnecessary.
    final cropped = cv.Mat.fromMat(source, roi: roi);
    cv.Mat? resized;
    var retainCroppedAsRetinaMat = false;
    try {
      final output =
          cropSide == retinaSize
              ? cropped
              : (resized = cv.resize(cropped, (
                retinaSize,
                retinaSize,
              ), interpolation: cv.INTER_LINEAR));
      retainCroppedAsRetinaMat = resized == null;
      return RetinaFrame(
        // data already returns an owned Dart Uint8List. Wrapping it in
        // fromList duplicated the complete 640x640 image on every frame.
        bgr: output.data,
        originalBgr: bgr,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        cropX: cropX,
        cropY: cropY,
        cropSide: cropSide,
        wasResized: cropSide != retinaSize,
        originalMat: source,
        retinaMat: output,
        sourceBuffer: sourceBytes,
      );
    } catch (_) {
      resized?.dispose();
      source.dispose();
      calloc.free(sourceBytes);
      rethrow;
    } finally {
      if (!retainCroppedAsRetinaMat) cropped.dispose();
      roi.dispose();
    }
  }

  /// Reproduces the MiniFASNet repository's context crop from the original
  /// camera frame, then resizes it to the models' 80x80 BGR input.
  MiniFasNetCrops cropForMiniFasNet(RetinaFrame frame, FaceDetection face) {
    const outputSize = 80;
    final retinaToOriginal = frame.cropSide / retinaSize;
    // The reference first converts xyxy to integer xywh.
    final mappedLeft = frame.cropX + (face.left * retinaToOriginal);
    final mappedTop = frame.cropY + (face.top * retinaToOriginal);
    final left = mappedLeft.toInt();
    final top = mappedTop.toInt();
    final boxWidth = math.max(1, (face.width * retinaToOriginal).toInt());
    final boxHeight = math.max(1, (face.height * retinaToOriginal).toInt());
    MiniFasNetCropBox box(double scale) => calculateMiniFasNetCropBox(
      sourceWidth: frame.originalWidth,
      sourceHeight: frame.originalHeight,
      x: left,
      y: top,
      boxWidth: boxWidth,
      boxHeight: boxHeight,
      scale: scale,
    );
    final v2Box = box(2.7);
    final v1seBox = box(4.0);

    final source = frame.originalMat;
    Uint8List resizeCrop(MiniFasNetCropBox cropBox) {
      final roi = cv.Rect(
        cropBox.left,
        cropBox.top,
        cropBox.width,
        cropBox.height,
      );
      final cropped = cv.Mat.fromMat(source, roi: roi);
      final resized = cv.resize(cropped, (
        outputSize,
        outputSize,
      ), interpolation: cv.INTER_LINEAR);
      try {
        // The Mat is disposed below, so retain an owned Dart copy for the
        // asynchronous native ONNX call. This copy is only 80x80x3 bytes.
        return Uint8List.fromList(resized.data);
      } finally {
        resized.dispose();
        cropped.dispose();
        roi.dispose();
      }
    }

    return MiniFasNetCrops(
      v2Bgr: resizeCrop(v2Box),
      v1seBgr: resizeCrop(v1seBox),
      v2Box: v2Box,
      v1seBox: v1seBox,
    );
  }

  /// Exact port of Minivision CropImage._get_new_box().
  ///
  /// When the scaled crop crosses an edge, the opposite edge is shifted by
  /// the same amount. This preserves the requested context instead of
  /// shortening and stretching a clipped crop.
  static MiniFasNetCropBox calculateMiniFasNetCropBox({
    required int sourceWidth,
    required int sourceHeight,
    required int x,
    required int y,
    required int boxWidth,
    required int boxHeight,
    required double scale,
  }) {
    if (sourceWidth <= 1 || sourceHeight <= 1) {
      throw ArgumentError('The source image must be at least 2x2 pixels.');
    }
    if (boxWidth <= 0 || boxHeight <= 0) {
      throw ArgumentError('The face bounding box must have positive size.');
    }

    final boundedScale = math.min(
      (sourceHeight - 1) / boxHeight,
      math.min((sourceWidth - 1) / boxWidth, scale),
    );
    final newWidth = boxWidth * boundedScale;
    final newHeight = boxHeight * boundedScale;
    final centerX = x + boxWidth / 2;
    final centerY = y + boxHeight / 2;

    var left = centerX - newWidth / 2;
    var top = centerY - newHeight / 2;
    var right = centerX + newWidth / 2;
    var bottom = centerY + newHeight / 2;

    if (left < 0) {
      right -= left;
      left = 0;
    }
    if (top < 0) {
      bottom -= top;
      top = 0;
    }
    if (right > sourceWidth - 1) {
      left -= right - sourceWidth + 1;
      right = sourceWidth - 1;
    }
    if (bottom > sourceHeight - 1) {
      top -= bottom - sourceHeight + 1;
      bottom = sourceHeight - 1;
    }

    return MiniFasNetCropBox(
      left: left.toInt(),
      top: top.toInt(),
      right: right.toInt(),
      bottom: bottom.toInt(),
    );
  }

  AlignedFace? align(RetinaFrame frame, FaceLandmarks landmarks) {
    final sourcePoints = <math.Point<double>>[
      landmarks.leftEye,
      landmarks.rightEye,
      landmarks.nose,
      landmarks.leftMouth,
      landmarks.rightMouth,
    ];
    final matrixValues = _umeyama(sourcePoints, _reference);
    if (matrixValues == null) return null;

    final source = frame.retinaMat;
    final matrix = cv.Mat.fromList(2, 3, cv.MatType.CV_32FC1, matrixValues);
    final aligned = cv.warpAffine(
      source,
      matrix,
      (faceSize, faceSize),
      flags: cv.INTER_LANCZOS4,
      borderMode: cv.BORDER_REFLECT,
    );
    final gray = cv.cvtColor(aligned, cv.COLOR_BGR2GRAY);
    final laplacian = cv.laplacian(gray, cv.MatType.CV_64F);
    try {
      final (_, standardDeviation) = cv.meanStdDev(laplacian);
      final sharpness = standardDeviation.val1 * standardDeviation.val1;
      return AlignedFace(
        // The aligned Mat is disposed below. AdaFace executes asynchronously,
        // so it requires an owned 112x112x3 copy.
        bgr: Uint8List.fromList(aligned.data),
        sharpness: sharpness,
      );
    } finally {
      laplacian.dispose();
      gray.dispose();
      aligned.dispose();
      matrix.dispose();
    }
  }

  List<double>? _umeyama(
    List<math.Point<double>> source,
    List<math.Point<double>> destination,
  ) {
    if (source.length != destination.length || source.isEmpty) return null;
    final count = source.length;
    final sourceMeanX = source.fold<double>(0, (sum, p) => sum + p.x) / count;
    final sourceMeanY = source.fold<double>(0, (sum, p) => sum + p.y) / count;
    final destinationMeanX =
        destination.fold<double>(0, (sum, p) => sum + p.x) / count;
    final destinationMeanY =
        destination.fold<double>(0, (sum, p) => sum + p.y) / count;

    var denominator = 0.0;
    var rotationScaleA = 0.0;
    var rotationScaleB = 0.0;
    for (var index = 0; index < count; index++) {
      final sx = source[index].x - sourceMeanX;
      final sy = source[index].y - sourceMeanY;
      final dx = destination[index].x - destinationMeanX;
      final dy = destination[index].y - destinationMeanY;
      denominator += sx * sx + sy * sy;
      rotationScaleA += sx * dx + sy * dy;
      rotationScaleB += sx * dy - sy * dx;
    }
    if (denominator < 1e-10) return null;

    final a = rotationScaleA / denominator;
    final b = rotationScaleB / denominator;
    final translateX = destinationMeanX - a * sourceMeanX + b * sourceMeanY;
    final translateY = destinationMeanY - b * sourceMeanX - a * sourceMeanY;
    return [a, -b, translateX, b, a, translateY];
  }
}
