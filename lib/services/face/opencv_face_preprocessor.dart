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
  Uint8List cropForMiniFasNet(
    RetinaFrame frame,
    FaceDetection face, {
    required double contextScale,
  }) {
    const outputSize = 80;
    final retinaToOriginal = frame.cropSide / retinaSize;
    // The reference first converts xyxy to integer xywh.
    final mappedLeft = frame.cropX + (face.left * retinaToOriginal);
    final mappedTop = frame.cropY + (face.top * retinaToOriginal);
    final left = mappedLeft.toInt();
    final top = mappedTop.toInt();
    final boxWidth = math.max(1, (face.width * retinaToOriginal).toInt());
    final boxHeight = math.max(1, (face.height * retinaToOriginal).toInt());
    final scale = math.min(
      contextScale,
      math.min(
        (frame.originalHeight - 1) / boxHeight,
        (frame.originalWidth - 1) / boxWidth,
      ),
    );
    final centerX = left + boxWidth / 2;
    final centerY = top + boxHeight / 2;
    final x1 = math.max(0, (centerX - (boxWidth * scale / 2)).toInt());
    final y1 = math.max(0, (centerY - (boxHeight * scale / 2)).toInt());
    final x2 = math.min(
      frame.originalWidth - 1,
      (centerX + (boxWidth * scale / 2)).toInt(),
    );
    final y2 = math.min(
      frame.originalHeight - 1,
      (centerY + (boxHeight * scale / 2)).toInt(),
    );

    final source = cv.Mat.fromList(
      frame.originalHeight,
      frame.originalWidth,
      cv.MatType.CV_8UC3,
      frame.originalBgr,
    );
    final roi = cv.Rect(x1, y1, x2 - x1 + 1, y2 - y1 + 1);
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
      source.dispose();
    }
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
