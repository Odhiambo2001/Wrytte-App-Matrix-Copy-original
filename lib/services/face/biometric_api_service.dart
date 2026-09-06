import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

/// Sends five RetinaFace frames plus their landmarks and five shared liveness
/// source frames. The backend calculates Umeyama, derives both MiniFASNet
/// crops, runs AdaFace, and performs quantization. Flutter receives only the
/// 832 packed quantization bits needed for its local LDPC commitment; it never
/// receives an embedding, liveness score, or image from the backend.
class BiometricLdpcInput {
  const BiometricLdpcInput._({
    required this.accepted,
    required this.ldpcBits,
    this.enrollmentTicket,
  });

  BiometricLdpcInput.rejected()
    : accepted = false,
      ldpcBits = Uint8List(0),
      enrollmentTicket = null;

  final bool accepted;
  final Uint8List ldpcBits;
  final String? enrollmentTicket;
}

/// Result of one immediately uploaded camera candidate. The backend returns
/// LDPC material only after it has accepted candidate index four; earlier
/// responses contain no embedding, score, image, or biometric template.
class BiometricCandidateResult {
  const BiometricCandidateResult._({
    required this.accepted,
    required this.captureSessionId,
    required this.index,
    required this.acceptedCandidates,
    this.completedInput,
  });

  const BiometricCandidateResult.rejected({
    this.captureSessionId,
    required this.index,
    required this.acceptedCandidates,
  }) : accepted = false,
       completedInput = null;

  final bool accepted;
  final String? captureSessionId;
  final int index;
  final int acceptedCandidates;
  final BiometricLdpcInput? completedInput;

  bool get complete => completedInput != null;
}

class BiometricApiService {
  static const ldpcInputBitCount = 832;
  static const _packedLdpcInputByteCount = ldpcInputBitCount ~/ 8;
  static const _maximumLivenessFrameWidth = 1280;
  static const _maximumLivenessFrameHeight = 1280;
  static const _maximumLivenessFramePixels = 921600;

  static Future<BiometricLdpcInput> enroll({
    required String token,
    required List<BiometricCropSet> captures,
  }) async {
    final response = await _send(
      '/api/biometrics/enroll',
      captures,
      token: token,
    );
    return _ldpcInputFromResponse(response);
  }

  /// Validates a capture and returns a short-lived enrolment ticket. Flutter
  /// must create the local LDPC commitment before exchanging that ticket for
  /// an account; a rejected scan creates neither account nor session.
  static Future<BiometricLdpcInput> enrollNew({
    required String wrytteId,
    required List<BiometricCropSet> captures,
  }) async {
    final response = await _send(
      '/api/biometrics/enroll/new',
      captures,
      fields: {'wrytteId': wrytteId},
    );
    return _ldpcInputFromResponse(response, needsEnrollmentTicket: true);
  }

  static Future<BiometricLdpcInput> verify({
    required String wrytteId,
    required List<BiometricCropSet> captures,
  }) async {
    final response = await _send(
      '/api/biometrics/verify',
      captures,
      fields: {'wrytteId': wrytteId},
    );
    return _ldpcInputFromResponse(response);
  }

  /// Sends one target-face candidate as soon as Flutter selects it. The
  /// backend liveness-checks the pair, associates it with [candidateIndex],
  /// and retains only an in-memory AdaFace vector until all five indexes pass.
  static Future<BiometricCandidateResult> enrollNewCandidate({
    required String wrytteId,
    required int candidateIndex,
    String? captureSessionId,
    required BiometricCropSet capture,
  }) async {
    final response = await _sendCandidate(
      '/api/biometrics/enroll/new/candidate',
      wrytteId: wrytteId,
      candidateIndex: candidateIndex,
      captureSessionId: captureSessionId,
      capture: capture,
    );
    return _candidateResultFromResponse(response, needsEnrollmentTicket: true);
  }

  static Future<BiometricCandidateResult> verifyCandidate({
    required String wrytteId,
    required int candidateIndex,
    String? captureSessionId,
    required BiometricCropSet capture,
  }) async {
    final response = await _sendCandidate(
      '/api/biometrics/verify/candidate',
      wrytteId: wrytteId,
      candidateIndex: candidateIndex,
      captureSessionId: captureSessionId,
      capture: capture,
    );
    return _candidateResultFromResponse(response);
  }

  static BiometricCandidateResult _candidateResultFromResponse(
    dynamic response, {
    bool needsEnrollmentTicket = false,
  }) {
    if (response is! Map) {
      return const BiometricCandidateResult.rejected(
        index: -1,
        acceptedCandidates: 0,
      );
    }
    final index = _asInt(response['index']) ?? -1;
    final acceptedCandidates = _asInt(response['acceptedCandidates']) ?? 0;
    final sessionId = response['captureSessionId']?.toString().trim();
    final normalizedSessionId =
        sessionId == null || sessionId.isEmpty ? null : sessionId;
    if (response['accepted'] != true) {
      return BiometricCandidateResult.rejected(
        captureSessionId: normalizedSessionId,
        index: index,
        acceptedCandidates: acceptedCandidates,
      );
    }
    if (index < 0 ||
        index >= FaceBiometricPipeline.framesToUse ||
        acceptedCandidates < 1 ||
        acceptedCandidates > FaceBiometricPipeline.framesToUse ||
        normalizedSessionId == null) {
      return const BiometricCandidateResult.rejected(
        index: -1,
        acceptedCandidates: 0,
      );
    }
    if (acceptedCandidates < FaceBiometricPipeline.framesToUse) {
      return BiometricCandidateResult._(
        accepted: true,
        captureSessionId: normalizedSessionId,
        index: index,
        acceptedCandidates: acceptedCandidates,
      );
    }
    final completed = _ldpcInputFromResponse(
      response,
      needsEnrollmentTicket: needsEnrollmentTicket,
    );
    if (!completed.accepted) {
      return const BiometricCandidateResult.rejected(
        index: -1,
        acceptedCandidates: 0,
      );
    }
    return BiometricCandidateResult._(
      accepted: true,
      captureSessionId: normalizedSessionId,
      index: index,
      acceptedCandidates: acceptedCandidates,
      completedInput: completed,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  static BiometricLdpcInput _ldpcInputFromResponse(
    dynamic response, {
    bool needsEnrollmentTicket = false,
  }) {
    if (response is! Map || response['accepted'] != true) {
      return BiometricLdpcInput.rejected();
    }
    try {
      final encoded = response['ldpcBits']?.toString() ?? '';
      if (encoded.length > 1024) throw const FormatException();
      final packed = base64Decode(encoded);
      if (packed.length != _packedLdpcInputByteCount) {
        throw const FormatException();
      }
      final ticket = response['enrollmentTicket']?.toString().trim();
      if (needsEnrollmentTicket && (ticket == null || ticket.isEmpty)) {
        throw const FormatException();
      }
      final normalizedTicket = ticket == null || ticket.isEmpty ? null : ticket;
      return BiometricLdpcInput._(
        accepted: true,
        ldpcBits: _unpackLdpcBits(Uint8List.fromList(packed)),
        enrollmentTicket: normalizedTicket,
      );
    } catch (_) {
      // Treat a malformed biometric response exactly like a generic denial.
      return BiometricLdpcInput.rejected();
    }
  }

  @visibleForTesting
  static Uint8List unpackLdpcBits(Uint8List packed) => _unpackLdpcBits(packed);

  static Uint8List _unpackLdpcBits(Uint8List packed) {
    if (packed.length != _packedLdpcInputByteCount) {
      throw const FormatException('Invalid biometric response.');
    }
    final bits = Uint8List(ldpcInputBitCount);
    for (var index = 0; index < bits.length; index++) {
      bits[index] = (packed[index ~/ 8] >> (7 - index % 8)) & 1;
    }
    return bits;
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
              'retinaFace': capture.retinaFaceBgr,
              'landmarks': _landmarks(capture.adafaceLandmarks),
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
    final adafaceLandmarks = <Map<String, double>>[];
    for (final capture in encodedCaptures) {
      livenessGeometry.add(capture['geometry']! as Map<String, int>);
      adafaceLandmarks.add(capture['landmarks']! as Map<String, double>);
      files
        ..add(
          http.MultipartFile.fromBytes(
            'retinaFaceFrames',
            capture['retinaFace']! as Uint8List,
            filename: 'retina-face.png',
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
        {
          ...fields,
          'livenessGeometry': jsonEncode(livenessGeometry),
          'adafaceLandmarks': jsonEncode(adafaceLandmarks),
        },
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

  static Future<dynamic> _sendCandidate(
    String path, {
    required String wrytteId,
    required int candidateIndex,
    required String? captureSessionId,
    required BiometricCropSet capture,
  }) async {
    if (candidateIndex < 0 ||
        candidateIndex >= FaceBiometricPipeline.framesToUse) {
      throw ArgumentError('Invalid biometric candidate index.');
    }
    // PNG encoding remains off the UI isolate while the camera preview keeps
    // running. This is a single candidate pair, not a five-frame batch.
    final encoded = await compute(_encodeCapture, <String, Object>{
      'retinaFace': capture.retinaFaceBgr,
      'landmarks': _landmarks(capture.adafaceLandmarks),
      'livenessFrame': capture.livenessFrameBgr,
      'livenessFrameWidth': capture.livenessFrameWidth,
      'livenessFrameHeight': capture.livenessFrameHeight,
      'x': capture.livenessFaceBox.x,
      'y': capture.livenessFaceBox.y,
      'width': capture.livenessFaceBox.width,
      'height': capture.livenessFaceBox.height,
    });
    final requestId = _requestId();
    final stopwatch = Stopwatch()..start();
    try {
      return await ApiService.postMultipart(
        path,
        <String, String>{
          'wrytteId': wrytteId,
          'candidateIndex': '$candidateIndex',
          if (captureSessionId != null && captureSessionId.isNotEmpty)
            'captureSessionId': captureSessionId,
          'livenessGeometry': jsonEncode(<Object>[encoded['geometry']!]),
          'adafaceLandmarks': jsonEncode(<Object>[encoded['landmarks']!]),
        },
        files: <http.MultipartFile>[
          http.MultipartFile.fromBytes(
            'retinaFaceFrame',
            encoded['retinaFace']! as Uint8List,
            filename: 'retina-face.png',
            contentType: MediaType('image', 'png'),
          ),
          http.MultipartFile.fromBytes(
            'livenessFrame',
            encoded['livenessFrame']! as Uint8List,
            filename: 'liveness-frame.png',
            contentType: MediaType('image', 'png'),
          ),
        ],
        headers: <String, String>{'X-Biometric-Request-Id': requestId},
      );
    } finally {
      stopwatch.stop();
      // No image, embedding, Wrytte ID, session ID, score, or token is logged.
      // ignore: avoid_print
      print(
        '[BiometricTiming] request=$requestId stage=candidate_upload_and_response '
        'index=$candidateIndex elapsed_ms=${stopwatch.elapsedMilliseconds}',
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
      'retinaFace': _png(capture['retinaFace']! as Uint8List, 640, 640),
      'landmarks': capture['landmarks']! as Map<String, double>,
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

  static Map<String, double> _landmarks(FaceLandmarks landmarks) =>
      <String, double>{
        'leftEyeX': landmarks.leftEye.x,
        'leftEyeY': landmarks.leftEye.y,
        'rightEyeX': landmarks.rightEye.x,
        'rightEyeY': landmarks.rightEye.y,
        'noseX': landmarks.nose.x,
        'noseY': landmarks.nose.y,
        'leftMouthX': landmarks.leftMouth.x,
        'leftMouthY': landmarks.leftMouth.y,
        'rightMouthX': landmarks.rightMouth.x,
        'rightMouthY': landmarks.rightMouth.y,
      };

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
