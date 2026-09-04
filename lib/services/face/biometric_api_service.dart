import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';

/// Sends only OpenCV/RetinaFace-prepared PNG crops. The device never runs or
/// stores AdaFace, MiniFASNet, quantization, or a fuzzy commitment.
class BiometricApiService {
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
    final files = <http.MultipartFile>[];
    for (final capture in captures) {
      files
        ..add(
          http.MultipartFile.fromBytes(
            'adafaceCrops',
            _png(capture.adafaceBgr, 112, 112),
            filename: 'face.png',
            contentType: MediaType('image', 'png'),
          ),
        )
        ..add(
          http.MultipartFile.fromBytes(
            'livenessV2Crops',
            _png(capture.livenessV2Bgr, 80, 80),
            filename: 'live-v2.png',
            contentType: MediaType('image', 'png'),
          ),
        )
        ..add(
          http.MultipartFile.fromBytes(
            'livenessV1seCrops',
            _png(capture.livenessV1seBgr, 80, 80),
            filename: 'live-v1se.png',
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
        fields,
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
    final random = Random.secure();
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
}
