import 'dart:io';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class CameraFrameConverter {
  const CameraFrameConverter._();

  static img.Image convert(
    CameraImage frame, {
    required int sensorOrientation,
  }) {
    final image = Platform.isIOS ? _fromBgra(frame) : _fromYuv420(frame);
    final rotation = sensorOrientation % 360;
    return rotation == 0 ? image : img.copyRotate(image, angle: rotation);
  }

  static img.Image _fromBgra(CameraImage frame) {
    final plane = frame.planes.first;
    final image = img.Image(width: frame.width, height: frame.height);
    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        final offset = y * plane.bytesPerRow + x * 4;
        image.setPixelRgba(
          x,
          y,
          plane.bytes[offset + 2],
          plane.bytes[offset + 1],
          plane.bytes[offset],
          plane.bytes[offset + 3],
        );
      }
    }
    return image;
  }

  static img.Image _fromYuv420(CameraImage frame) {
    final image = img.Image(width: frame.width, height: frame.height);
    final yPlane = frame.planes[0];
    final singlePlaneNv21 = frame.planes.length == 1;
    final uPlane = singlePlaneNv21 ? null : frame.planes[1];
    final vPlane = singlePlaneNv21 ? null : frame.planes[2];

    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        final yValue = yPlane.bytes[y * yPlane.bytesPerRow + x];
        late final int uValue;
        late final int vValue;
        if (singlePlaneNv21) {
          final uvStart = yPlane.bytesPerRow * frame.height;
          final uvOffset =
              uvStart + (y ~/ 2) * yPlane.bytesPerRow + (x ~/ 2) * 2;
          vValue = yPlane.bytes[uvOffset];
          uValue = yPlane.bytes[uvOffset + 1];
        } else {
          final uvPixelStride = uPlane!.bytesPerPixel ?? 1;
          final uvOffset =
              (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * uvPixelStride;
          uValue = uPlane.bytes[uvOffset];
          vValue = vPlane!.bytes[uvOffset];
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
}
