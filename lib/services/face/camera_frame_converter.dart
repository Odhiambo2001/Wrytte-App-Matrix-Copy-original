import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class CameraFrameConverter {
  const CameraFrameConverter._();

  /// Converts and rotates a camera frame off the UI isolate.
  ///
  /// CameraImage/Plane objects from the camera plugin cannot themselves be
  /// sent across an isolate boundary, and the plugin does not guarantee
  /// their underlying buffers stay valid once this frame callback returns.
  /// So plane bytes are copied into plain Uint8List/int fields here, on the
  /// calling (UI) isolate — that copy is cheap, just memcpy, not per-pixel
  /// math — and only then handed to [compute], which runs the actual
  /// per-pixel YUV/BGRA-to-RGB conversion and rotation on a background
  /// isolate. This is what was previously blocking the UI thread for
  /// 150-450ms per frame and causing the scan animation to stall.
  static Future<img.Image> convert(
    CameraImage frame, {
    required int sensorOrientation,
  }) {
    final payload = _CameraFramePayload.fromCameraImage(
      frame,
      isIOS: Platform.isIOS,
      rotation: sensorOrientation % 360,
    );
    return compute(_convertInBackground, payload);
  }
}

@immutable
class _CameraFramePayload {
  const _CameraFramePayload({
    required this.isIOS,
    required this.width,
    required this.height,
    required this.rotation,
    required this.planeBytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
  });

  factory _CameraFramePayload.fromCameraImage(
    CameraImage frame, {
    required bool isIOS,
    required int rotation,
  }) {
    final planeBytes = frame.planes
        .map((plane) => Uint8List.fromList(plane.bytes))
        .toList(growable: false);
    final bytesPerRow = frame.planes
        .map((plane) => plane.bytesPerRow)
        .toList(growable: false);
    final bytesPerPixel = frame.planes
        .map((plane) => plane.bytesPerPixel ?? 1)
        .toList(growable: false);
    return _CameraFramePayload(
      isIOS: isIOS,
      width: frame.width,
      height: frame.height,
      rotation: rotation,
      planeBytes: planeBytes,
      bytesPerRow: bytesPerRow,
      bytesPerPixel: bytesPerPixel,
    );
  }

  final bool isIOS;
  final int width;
  final int height;
  final int rotation;
  final List<Uint8List> planeBytes;
  final List<int> bytesPerRow;
  final List<int> bytesPerPixel;
}

/// Top-level function required by [compute]. Runs entirely on a background
/// isolate — no state is shared with the UI isolate during this call.
img.Image _convertInBackground(_CameraFramePayload payload) {
  final image = payload.isIOS ? _fromBgra(payload) : _fromYuv420(payload);
  final rotation = payload.rotation % 360;
  return rotation == 0 ? image : img.copyRotate(image, angle: rotation);
}

img.Image _fromBgra(_CameraFramePayload payload) {
  final bytes = payload.planeBytes.first;
  final bytesPerRow = payload.bytesPerRow.first;
  final image = img.Image(width: payload.width, height: payload.height);
  for (var y = 0; y < payload.height; y++) {
    for (var x = 0; x < payload.width; x++) {
      final offset = y * bytesPerRow + x * 4;
      image.setPixelRgba(
        x,
        y,
        bytes[offset + 2],
        bytes[offset + 1],
        bytes[offset],
        bytes[offset + 3],
      );
    }
  }
  return image;
}

img.Image _fromYuv420(_CameraFramePayload payload) {
  final image = img.Image(width: payload.width, height: payload.height);
  final yBytes = payload.planeBytes[0];
  final yRowStride = payload.bytesPerRow[0];
  final singlePlaneNv21 = payload.planeBytes.length == 1;
  final uBytes = singlePlaneNv21 ? null : payload.planeBytes[1];
  final vBytes = singlePlaneNv21 ? null : payload.planeBytes[2];
  final uRowStride = singlePlaneNv21 ? 0 : payload.bytesPerRow[1];
  final uPixelStride = singlePlaneNv21 ? 0 : payload.bytesPerPixel[1];

  for (var y = 0; y < payload.height; y++) {
    for (var x = 0; x < payload.width; x++) {
      final yValue = yBytes[y * yRowStride + x];
      late final int uValue;
      late final int vValue;
      if (singlePlaneNv21) {
        final uvStart = yRowStride * payload.height;
        final uvOffset = uvStart + (y ~/ 2) * yRowStride + (x ~/ 2) * 2;
        vValue = yBytes[uvOffset];
        uValue = yBytes[uvOffset + 1];
      } else {
        final uvOffset = (y ~/ 2) * uRowStride + (x ~/ 2) * uPixelStride;
        uValue = uBytes![uvOffset];
        vValue = vBytes![uvOffset];
      }
      final red = (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255);
      final green = (yValue -
              0.344136 * (uValue - 128) -
              0.714136 * (vValue - 128))
          .round()
          .clamp(0, 255);
      final blue = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);
      image.setPixelRgb(x, y, red, green, blue);
    }
  }
  return image;
}
