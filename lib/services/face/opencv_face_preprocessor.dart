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

/// Integer face geometry in the correctly-oriented original camera frame.
/// The backend receives this together with the source frame and reproduces
/// the fixed V2 and V1SE context crops from it.
class LivenessFaceBox {
  const LivenessFaceBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
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

  ffi.Pointer<ffi.Uint8> _copyToOwnedSourceBuffer(Uint8List bytes) {
    final buffer = calloc<ffi.Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    return buffer;
  }

  RetinaFrame prepare(img.Image image) {
    final originalWidth = image.width;
    final originalHeight = image.height;
    // All downstream consumers (RetinaFace, MiniFASNet and PNG encoding)
    // share packed, three-channel BGR bytes.
    final bgr = image.getBytes(order: img.ChannelOrder.bgr);

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
    // A ROI retains the source row stride. Clone it even at native size so
    // Mat.data exposes packed rows rather than interleaved source margins.
    final cropped = cv.Mat.fromMat(source, roi: roi);
    try {
      final output =
          cropSide != retinaSize
              ? cv.resize(cropped, (
                retinaSize,
                retinaSize,
              ), interpolation: cv.INTER_LINEAR)
              : cropped.clone();
      return RetinaFrame(
        // This view remains valid until RetinaFrame.dispose().
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
      source.dispose();
      calloc.free(sourceBytes);
      rethrow;
    } finally {
      cropped.dispose();
      roi.dispose();
    }
  }

  /// Reproduces the MiniFASNet repository's context crop from the original
  /// camera frame, then resizes it to the models' 80x80 BGR input.
  MiniFasNetCrops cropForMiniFasNet(RetinaFrame frame, FaceDetection face) {
    const outputSize = 80;
    final faceBox = mapFaceToOriginalBox(frame, face);
    MiniFasNetCropBox box(double scale) => calculateMiniFasNetCropBox(
      sourceWidth: frame.originalWidth,
      sourceHeight: frame.originalHeight,
      x: faceBox.x,
      y: faceBox.y,
      boxWidth: faceBox.width,
      boxHeight: faceBox.height,
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

  /// Maps a RetinaFace box from the fixed 640x640 detector image back to the
  /// original camera frame. These exact integer values travel with the shared
  /// liveness source image so the backend can apply the same model-specific
  /// context scales without receiving two near-duplicate images.
  LivenessFaceBox mapFaceToOriginalBox(RetinaFrame frame, FaceDetection face) =>
      mapRetinaFaceToOriginalBox(
        cropX: frame.cropX,
        cropY: frame.cropY,
        cropSide: frame.cropSide,
        faceLeft: face.left,
        faceTop: face.top,
        faceWidth: face.width,
        faceHeight: face.height,
      );

  static LivenessFaceBox mapRetinaFaceToOriginalBox({
    required int cropX,
    required int cropY,
    required int cropSide,
    required double faceLeft,
    required double faceTop,
    required double faceWidth,
    required double faceHeight,
  }) {
    final retinaToOriginal = cropSide / retinaSize;
    return LivenessFaceBox(
      x: (cropX + (faceLeft * retinaToOriginal)).toInt(),
      y: (cropY + (faceTop * retinaToOriginal)).toInt(),
      width: math.max(1, (faceWidth * retinaToOriginal).toInt()),
      height: math.max(1, (faceHeight * retinaToOriginal).toInt()),
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
}
