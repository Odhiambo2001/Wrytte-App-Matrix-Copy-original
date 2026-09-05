import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';

/// Sends five aligned AdaFace crops and five shared liveness source frames.
/// The backend derives the two MiniFASNet crops from every source frame. The
/// device never runs or stores AdaFace, MiniFASNet, quantization, or LDPC.
class BiometricApiService {
  static const _maximumLivenessFrameWidth = 1280;
  static const _maximumLivenessFrameHeight = 1280;
  static const _maximumLivenessFramePixels = 921600;

  static Future<bool> enroll({
    required String token,
    required List<BiometricCropSet> captures,
  }) async {
    final response = await _send(
      '/api/biometrics/enroll',
      captures,
      token: token,
    );
    return response is Map && response['accepted'] == true;
  }

  /// Atomically creates a Wrytte-ID account after, and only after, the
  /// server accepts its biometric enrollment. No session exists on rejection.
  static Future<Map<String, dynamic>> enrollNew({
    required String wrytteId,
    required List<BiometricCropSet> captures,
  }) async {
    final response = await _send(
      '/api/biometrics/enroll/new',
      captures,
      fields: {'wrytteId': wrytteId},
    );
    return response is Map ? Map<String, dynamic>.from(response) : const {};
  }

  static Future<Map<String, dynamic>> verify({
    required String wrytteId,
    required List<BiometricCropSet> captures,
  }) async {
    final response = await _send(
      '/api/biometrics/verify',
      captures,
      fields: {'wrytteId': wrytteId},
    );
    return response is Map ? Map<String, dynamic>.from(response) : const {};
  }

  static Future<dynamic> _send(
    String path,
    List<BiometricCropSet> captures, {
    String? token,
    Map<String, String> fields = const {},
  }) async {
    if (captures.length != FaceBiometricPipeline.framesToUse) {
      throw ArgumentError('Exactly five biometric crop sets are required.');
    }
    // PNG encoding a full camera frame is deliberately moved off the UI
    // isolate. The scan/result screen remains responsive while five captures
    // are prepared for upload.
    final encodedCaptures = await compute(
      _encodeCaptures,
      captures
          .map(
            (capture) => <String, Object>{
              'adaface': capture.adafaceBgr,
              'livenessFrame': capture.livenessFrameBgr,
              'livenessFrameWidth': capture.livenessFrameWidth,
              'livenessFrameHeight': capture.livenessFrameHeight,
              'x': capture.livenessFaceBox.x,
              'y': capture.livenessFaceBox.y,
              'width': capture.livenessFaceBox.width,
              'height': capture.livenessFaceBox.height,
            },
          )
          .toList(growable: false),
    );
    final files = <http.MultipartFile>[];
    final livenessGeometry = <Map<String, int>>[];
    for (final capture in encodedCaptures) {
      livenessGeometry.add(capture['geometry']! as Map<String, int>);
      files
        ..add(
          http.MultipartFile.fromBytes(
            'adafaceCrops',
            capture['adaface']! as Uint8List,
            filename: 'face.png',
            contentType: MediaType('image', 'png'),
          ),
        )
        ..add(
          http.MultipartFile.fromBytes(
            'livenessFrames',
            capture['livenessFrame']! as Uint8List,
            filename: 'liveness-frame.png',
            contentType: MediaType('image', 'png'),
          ),
        );
    }
    // Correlates duration-only frontend and backend diagnostics. It identifies
    // neither the person nor their biometric data.
    final requestId = _requestId();
    final stopwatch = Stopwatch()..start();
    try {
      return await ApiService.postMultipart(
        path,
        {...fields, 'livenessGeometry': jsonEncode(livenessGeometry)},
        files: files,
        token: token,
        headers: {'X-Biometric-Request-Id': requestId},
      );
    } finally {
      stopwatch.stop();
      // Deliberately no images, embeddings, scores, Wrytte ID, or token.
      // ignore: avoid_print
      print(
        '[BiometricTiming] request=$requestId stage=upload_and_response '
        'elapsed_ms=${stopwatch.elapsedMilliseconds}',
      );
    }
  }

  static String _requestId() {
    final random = math.Random.secure();
    final value =
        List<String>.generate(
          4,
          (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
        ).join();
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }

  static Uint8List _png(Uint8List bgr, int width, int height) {
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bgr.buffer,
      numChannels: 3,
      order: img.ChannelOrder.bgr,
    );
    return Uint8List.fromList(img.encodePng(image, level: 6));
  }

  /// This top-level-compatible static callback is run by [compute]. It keeps
  /// uploaded liveness source images inside the backend's documented limits,
  /// including on devices whose `medium` camera stream exceeds 1280x720.
  static List<Map<String, Object>> _encodeCaptures(
    List<Map<String, Object>> captures,
  ) {
    return captures.map(_encodeCapture).toList(growable: false);
  }

  static Map<String, Object> _encodeCapture(Map<String, Object> capture) {
    final sourceWidth = capture['livenessFrameWidth']! as int;
    final sourceHeight = capture['livenessFrameHeight']! as int;
    final sourceBgr = capture['livenessFrame']! as Uint8List;
    final sourceImage = img.Image.fromBytes(
      width: sourceWidth,
      height: sourceHeight,
      bytes: sourceBgr.buffer,
      numChannels: 3,
      order: img.ChannelOrder.bgr,
    );
    final target = livenessTargetSize(sourceWidth, sourceHeight);
    final livenessImage =
        target.$1 == sourceWidth && target.$2 == sourceHeight
            ? sourceImage
            : img.copyResize(
              sourceImage,
              width: target.$1,
              height: target.$2,
              interpolation: img.Interpolation.linear,
            );
    final sourceBox = <String, int>{
      'x': capture['x']! as int,
      'y': capture['y']! as int,
      'width': capture['width']! as int,
      'height': capture['height']! as int,
    };
    return <String, Object>{
      'adaface': _png(capture['adaface']! as Uint8List, 112, 112),
      'livenessFrame': Uint8List.fromList(
        img.encodePng(livenessImage, level: 6),
      ),
      'geometry': scaleLivenessFaceBox(
        sourceBox,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        targetWidth: target.$1,
        targetHeight: target.$2,
      ),
    };
  }

  @visibleForTesting
  static (int, int) livenessTargetSize(int sourceWidth, int sourceHeight) {
    if (sourceWidth < 1 || sourceHeight < 1) {
      throw ArgumentError('Invalid liveness frame dimensions.');
    }
    final pixelScale = math.sqrt(
      _maximumLivenessFramePixels / (sourceWidth * sourceHeight),
    );
    final scale = math.min(
      1,
      math.min(
        _maximumLivenessFrameWidth / sourceWidth,
        math.min(_maximumLivenessFrameHeight / sourceHeight, pixelScale),
      ),
    );
    var width = math.max(1, (sourceWidth * scale).floor());
    var height = math.max(1, (sourceHeight * scale).floor());
    while (width * height > _maximumLivenessFramePixels) {
      if (width >= height && width > 1) {
        width--;
      } else if (height > 1) {
        height--;
      } else {
        break;
      }
    }
    return (width, height);
  }

  @visibleForTesting
  static Map<String, int> scaleLivenessFaceBox(
    Map<String, int> box, {
    required int sourceWidth,
    required int sourceHeight,
    required int targetWidth,
    required int targetHeight,
  }) {
    final x = ((box['x']! * targetWidth) / sourceWidth).floor();
    final y = ((box['y']! * targetHeight) / sourceHeight).floor();
    final right =
        ((box['x']! + box['width']!) * targetWidth / sourceWidth)
            .ceil()
            .clamp(x + 1, targetWidth)
            .toInt();
    final bottom =
        ((box['y']! + box['height']!) * targetHeight / sourceHeight)
            .ceil()
            .clamp(y + 1, targetHeight)
            .toInt();
    return <String, int>{
      'x': x,
      'y': y,
      'width': right - x,
      'height': bottom - y,
    };
  }
}
