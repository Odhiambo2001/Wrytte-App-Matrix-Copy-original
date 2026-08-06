import 'dart:math' as math;
import 'dart:typed_data';

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
  });

  final Uint8List bgr;
  final Uint8List originalBgr;
  final int originalWidth;
  final int originalHeight;
  final int cropX;
  final int cropY;
  final int cropSide;
  final bool wasResized;
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

  RetinaFrame prepare(img.Image image) {
    final originalWidth = image.width;
    final originalHeight = image.height;
    final bgr = Uint8List(originalWidth * originalHeight * 3);
    var offset = 0;
    for (var y = 0; y < originalHeight; y++) {
      for (var x = 0; x < originalWidth; x++) {
        final pixel = image.getPixel(x, y);
        bgr[offset++] = pixel.b.toInt();
        bgr[offset++] = pixel.g.toInt();
        bgr[offset++] = pixel.r.toInt();
      }
    }

    final source = cv.Mat.fromList(
      originalHeight,
      originalWidth,
      cv.MatType.CV_8UC3,
      bgr,
    );
    final cropSide =
        originalWidth >= retinaSize && originalHeight >= retinaSize
            ? retinaSize
            : math.min(originalWidth, originalHeight);
    final cropX = (originalWidth - cropSide) ~/ 2;
    final cropY = (originalHeight - cropSide) ~/ 2;
    final roi = cv.Rect(cropX, cropY, cropSide, cropSide);
    final cropped = cv.Mat.fromMat(source, copy: true, roi: roi);
    cv.Mat? resized;
    try {
      final output =
          cropSide == retinaSize
              ? cropped
              : (resized = cv.resize(cropped, (
                retinaSize,
                retinaSize,
              ), interpolation: cv.INTER_LINEAR));
      return RetinaFrame(
        bgr: Uint8List.fromList(output.data),
        originalBgr: bgr,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        cropX: cropX,
        cropY: cropY,
        cropSide: cropSide,
        wasResized: cropSide != retinaSize,
      );
    } finally {
      resized?.dispose();
      cropped.dispose();
      roi.dispose();
      source.dispose();
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

    final source = cv.Mat.fromList(
      frame.originalHeight,
      frame.originalWidth,
      cv.MatType.CV_8UC3,
      frame.originalBgr,
    );
    Uint8List resizeCrop(MiniFasNetCropBox cropBox) {
      final roi = cv.Rect(
        cropBox.left,
        cropBox.top,
        cropBox.width,
        cropBox.height,
      );
      final cropped = cv.Mat.fromMat(source, copy: true, roi: roi);
      final resized = cv.resize(cropped, (
        outputSize,
        outputSize,
      ), interpolation: cv.INTER_LINEAR);
      try {
        return Uint8List.fromList(resized.data);
      } finally {
        resized.dispose();
        cropped.dispose();
        roi.dispose();
      }
    }

    try {
      return MiniFasNetCrops(
        v2Bgr: resizeCrop(v2Box),
        v1seBgr: resizeCrop(v1seBox),
        v2Box: v2Box,
        v1seBox: v1seBox,
      );
    } finally {
      source.dispose();
    }
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

    final source = cv.Mat.fromList(
      retinaSize,
      retinaSize,
      cv.MatType.CV_8UC3,
      frame.bgr,
    );
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
        bgr: Uint8List.fromList(aligned.data),
        sharpness: sharpness,
      );
    } finally {
      laplacian.dispose();
      gray.dispose();
      aligned.dispose();
      matrix.dispose();
      source.dispose();
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
