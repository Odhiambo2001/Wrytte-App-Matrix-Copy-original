import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/face/biometric_stage_timing.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';
import 'package:wrytte/utils/wrytte_id.dart';

/// Sends each valid RetinaFace target frame plus its landmarks and matching
/// liveness source frame as soon as the camera produces it. The backend
/// selects five live candidates, calculates Umeyama, runs AdaFace, and
/// performs quantization. Flutter receives only the 832 packed quantization
/// bits needed for its local LDPC commitment; it never receives an embedding,
/// liveness score, or image from the backend.
class BiometricLdpcInput {
  const BiometricLdpcInput._({
    required this.accepted,
    required this.ldpcBits,
    required this.pending,
    this.enrollmentTicket,
  });

  BiometricLdpcInput.rejected()
    : accepted = false,
      ldpcBits = Uint8List(0),
      pending = false,
      enrollmentTicket = null;

  BiometricLdpcInput.pending()
    : accepted = false,
      ldpcBits = Uint8List(0),
      pending = true,
      enrollmentTicket = null;

  final bool accepted;
  final Uint8List ldpcBits;
  final bool pending;
  final String? enrollmentTicket;
}

/// The signup response returned after five live candidates. These credentials
/// are consumed internally by the app; the screen never displays them. The
/// opaque [ldpcInputTicket] is exchanged once for the compact LDPC input.
class BiometricEnrollmentProvision {
  const BiometricEnrollmentProvision({
    required this.userId,
    required this.username,
    required this.phone,
    required this.secret,
    required this.token,
    this.deviceId = '',
    required this.ldpcInputTicket,
  });

  final String userId;
  final String username;
  final String phone;
  final String secret;
  final String token;
  final String deviceId;
  final String ldpcInputTicket;
}

/// The fifth live sign-in response contains the compact backend template and
/// a one-time challenge. It never contains the account secret or session
/// token; those are returned only after the device proves possession below.
class BiometricVerificationBootstrap {
  const BiometricVerificationBootstrap({
    required this.input,
    required this.kmap,
    required this.challenge,
  });

  final BiometricLdpcInput input;
  final Map<String, dynamic> kmap;
  final String challenge;
}

/// Result of one immediately uploaded camera candidate. The backend returns
/// no image, score, or embedding. Signup receives provisional credentials on
/// the fifth live candidate; sign-in receives an LDPC verification bootstrap.
class BiometricCandidateResult {
  const BiometricCandidateResult._({
    required this.accepted,
    required this.captureSessionId,
    required this.index,
    required this.acceptedCandidates,
    this.completedInput,
    this.enrollmentProvision,
    this.verificationBootstrap,
  }) : errorCode = null;

  const BiometricCandidateResult.rejected({
    this.captureSessionId,
    required this.index,
    required this.acceptedCandidates,
    required this.errorCode,
  }) : accepted = false,
       completedInput = null,
       enrollmentProvision = null,
       verificationBootstrap = null;

  final bool accepted;
  final String? captureSessionId;
  final int index;
  final int acceptedCandidates;

  /// Legacy batch compatibility; continuous sign-in uses the validated
  /// [verificationBootstrap] instead.
  final BiometricLdpcInput? completedInput;
  final BiometricEnrollmentProvision? enrollmentProvision;
  final BiometricVerificationBootstrap? verificationBootstrap;
  final String? errorCode;

  bool get complete =>
      completedInput != null ||
      enrollmentProvision != null ||
      verificationBootstrap != null;
}

class _UploadReservation {
  _UploadReservation(this.previous, this._done);

  final Future<void> previous;
  final Completer<void> _done;

  void release() {
    if (!_done.isCompleted) _done.complete();
  }
}

class BiometricApiService {
  // JPEG preserves the face detail required by the backend models while
  // avoiding the large CPU and transport cost of lossless PNG frames.
  static const _jpegQuality = 85;
  static Future<void> _uploadTail = Future<void>.value();
  static final Set<String> _completedCaptureSessions = <String>{};

  static _UploadReservation _reserveUpload() {
    final previous = _uploadTail;
    final done = Completer<void>();
    _uploadTail = done.future;
    return _UploadReservation(previous, done);
  }

  static Future<T> _serializeUpload<T>(Future<T> Function() upload) {
    final result = _uploadTail.then((_) => upload());
    _uploadTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }
  static const ldpcInputBitCount = 832;
  static const _packedLdpcInputByteCount = ldpcInputBitCount ~/ 8;
  // MiniFASNet receives a small face crop on the backend. An 800x450 source
  // retains enough context for the fixed 80x80 model crop while reducing
  // JPEG work and transport pixels by 31% from the verified 960x540 size.
  static const _maximumLivenessFrameWidth = 800;
  static const _maximumLivenessFrameHeight = 800;
  static const _maximumLivenessFramePixels = 360000;

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
    final backendWrytteId = WrytteId.forBackend(wrytteId);
    final response = await _send(
      '/api/biometrics/enroll/new',
      captures,
      fields: {'wrytteId': backendWrytteId},
    );
    return _ldpcInputFromResponse(response, needsEnrollmentTicket: true);
  }

  static Future<BiometricLdpcInput> verify({
    required String userId,
    required List<BiometricCropSet> captures,
  }) async {
    final response = await _send(
      '/api/biometrics/verify',
      captures,
      fields: {'userId': userId},
    );
    return _ldpcInputFromResponse(response);
  }

  /// Sends one target-face candidate as soon as Flutter selects it.
  /// [candidateIndex] is a unique client submission number, not the final
  /// biometric slot: concurrent liveness requests may finish in a different
  /// order. The backend assigns accepted slots 0 through 4 as frames pass.
  static Future<BiometricCandidateResult> enrollNewCandidate({
    required String wrytteId,
    required int candidateIndex,
    String? captureSessionId,
    String? deviceModel,
    String? language,
    String? region,
    required BiometricCropSet capture,
  }) async {
    final response = await _sendCandidate(
      '/api/biometrics/enroll/new/candidate',
      wrytteId: WrytteId.forBackend(wrytteId),
      candidateIndex: candidateIndex,
      captureSessionId: captureSessionId,
      deviceModel: deviceModel,
      language: language,
      region: region,
      capture: capture,
    );
    return _candidateResultFromResponse(response, isEnrollment: true);
  }

  static Future<BiometricCandidateResult> enrollExistingCandidate({
    required String userId,
    required String token,
    required int candidateIndex,
    String? captureSessionId,
    required BiometricCropSet capture,
  }) async {
    final response = await _sendCandidate(
      '/api/biometrics/enroll/user/candidate',
      userId: userId,
      token: token,
      candidateIndex: candidateIndex,
      captureSessionId: captureSessionId,
      capture: capture,
    );
    return _candidateResultFromResponse(response, existingEnrollment: true);
  }

  /// Opens one opaque session before Flutter begins up to five concurrent
  /// liveness uploads. The session is tied to the normalized Wrytte ID, but
  /// reveals neither account existence nor biometric information.
  static Future<String?> startEnrollmentCaptureSession({
    required String wrytteId,
  }) async {
    final response = await ApiService.postMultipart(
      '/api/biometrics/enroll/new/session',
      <String, String>{'wrytteId': WrytteId.forBackend(wrytteId)},
    );
    if (response is! Map || response['accepted'] != true) return null;
    final sessionId = response['captureSessionId']?.toString().trim() ?? '';
    return sessionId.isEmpty || sessionId.length > 256 ? null : sessionId;
  }

  static Future<String?> startExistingEnrollmentCaptureSession({
    required String userId,
    required String token,
  }) async {
    final response = await ApiService.postMultipart(
      '/api/biometrics/enroll/user/session',
      <String, String>{'userId': userId},
      token: token,
    );
    if (response is! Map || response['accepted'] != true) return null;
    final sessionId = response['captureSessionId']?.toString().trim() ?? '';
    return sessionId.isEmpty || sessionId.length > 256 ? null : sessionId;
  }

  /// Opens the same bounded continuous capture session for sign-in. The
  /// backend binds this opaque ID to the already-found internal account ID.
  static Future<String?> startVerifyCaptureSession({
    required String userId,
  }) async {
    final response = await ApiService.postMultipart(
      '/api/biometrics/verify/session',
      <String, String>{'userId': userId},
    );
    if (response is! Map || response['accepted'] != true) return null;
    final sessionId = response['captureSessionId']?.toString().trim() ?? '';
    return sessionId.isEmpty || sessionId.length > 256 ? null : sessionId;
  }

  static Future<BiometricCandidateResult> verifyCandidate({
    required String userId,
    required int candidateIndex,
    String? captureSessionId,
    required BiometricCropSet capture,
  }) async {
    final response = await _sendCandidate(
      '/api/biometrics/verify/candidate',
      userId: userId,
      candidateIndex: candidateIndex,
      captureSessionId: captureSessionId,
      capture: capture,
    );
    return _candidateResultFromResponse(response);
  }

  /// Gets the one-time LDPC input after signup credentials have been returned
  /// internally. The server retains only 104 packed bytes until this call.
  static Future<BiometricLdpcInput> claimEnrollmentLdpcInput({
    required String wrytteId,
    required String ldpcInputTicket,
  }) async {
    final response = await ApiService.postMultipart(
      '/api/biometrics/enroll/new/ldpc',
      <String, String>{
        'wrytteId': WrytteId.forBackend(wrytteId),
        'ldpcInputTicket': ldpcInputTicket,
      },
    );
    return _ldpcInputFromResponse(response, needsEnrollmentTicket: true);
  }

  static BiometricCandidateResult _candidateResultFromResponse(
    dynamic response, {
    bool isEnrollment = false,
    bool existingEnrollment = false,
  }) {
    if (response is! Map) {
      return const BiometricCandidateResult.rejected(
        index: -1,
        acceptedCandidates: 0,
        errorCode: null,
      );
    }
    final index = _asInt(response['index']) ?? -1;
    final acceptedCandidates = _asInt(response['acceptedCandidates']) ?? 0;
    final sessionId = response['captureSessionId']?.toString().trim();
    final normalizedSessionId =
        sessionId == null || sessionId.isEmpty ? null : sessionId;
    final realAnswer =
        response['real'] ?? response['isReal'] ?? response['live'];
    if (response['accepted'] != true || realAnswer == false) {
      return BiometricCandidateResult.rejected(
        captureSessionId: normalizedSessionId,
        index: index,
        acceptedCandidates: acceptedCandidates,
        errorCode:
            realAnswer == false
                ? 'FACE_NOT_LIVE'
                : _errorCode(response['rejectionCode'] ?? response['error']),
      );
    }
    if (index < 0 ||
        index > 299 ||
        acceptedCandidates < 1 ||
        acceptedCandidates > FaceBiometricPipeline.framesToUse ||
        normalizedSessionId == null) {
      return const BiometricCandidateResult.rejected(
        index: -1,
        acceptedCandidates: 0,
        errorCode: null,
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
    if (existingEnrollment) {
      final completed = _ldpcInputFromResponse(response);
      if (!completed.accepted) {
        return const BiometricCandidateResult.rejected(
          index: -1,
          acceptedCandidates: 0,
          errorCode: null,
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
    if (isEnrollment) {
      final provision = _enrollmentProvisionFromResponse(response);
      if (provision == null) {
        return const BiometricCandidateResult.rejected(
          index: -1,
          acceptedCandidates: 0,
          errorCode: null,
        );
      }
      return BiometricCandidateResult._(
        accepted: true,
        captureSessionId: normalizedSessionId,
        index: index,
        acceptedCandidates: acceptedCandidates,
        enrollmentProvision: provision,
      );
    }
    final completed = _ldpcInputFromResponse(response);
    final bootstrap = _verificationBootstrapFromResponse(response, completed);
    if (bootstrap == null) {
      return const BiometricCandidateResult.rejected(
        index: -1,
        acceptedCandidates: 0,
        errorCode: null,
      );
    }
    return BiometricCandidateResult._(
      accepted: true,
      captureSessionId: normalizedSessionId,
      index: index,
      acceptedCandidates: acceptedCandidates,
      completedInput: completed,
      verificationBootstrap: bootstrap,
    );
  }

  static BiometricVerificationBootstrap? _verificationBootstrapFromResponse(
    Map<dynamic, dynamic> response,
    BiometricLdpcInput input,
  ) {
    if (!input.accepted) return null;
    final challenge = response['challenge']?.toString().trim() ?? '';
    if (challenge.isEmpty) return null;
    final rawKmap = response['kmap'];
    Map<String, dynamic> kmap;
    try {
      if (rawKmap is Map) {
        kmap = Map<String, dynamic>.from(rawKmap);
      } else {
        final decoded = jsonDecode(rawKmap?.toString() ?? '');
        if (decoded is! Map) return null;
        kmap = Map<String, dynamic>.from(decoded);
      }
      FuzzyCommitment.fromJson(kmap);
      // The registered Ed25519 public key remains server-side. It is not
      // needed by the client to recover the key or sign the challenge.
      // Older commitments may still contain this optional field in storage;
      // the backend strips it before sending the recovery kmap to the FE.
    } catch (_) {
      return null;
    }
    return BiometricVerificationBootstrap(
      input: input,
      kmap: kmap,
      challenge: challenge,
    );
  }

  static String? _errorCode(Object? value) {
    final code = value?.toString().trim();
    return code == null || code.isEmpty ? null : code;
  }

  static BiometricEnrollmentProvision? _enrollmentProvisionFromResponse(
    Map<dynamic, dynamic> response,
  ) {
    final userId =
        (response['userid'] ?? response['userId'] ?? '').toString().trim();
    final username = response['username']?.toString().trim() ?? '';
    final phone = response['phone']?.toString().trim() ?? '';
    final secret = response['secret']?.toString().trim() ?? '';
    final token = response['token']?.toString().trim() ?? '';
    final deviceId = response['deviceId']?.toString().trim() ?? '';
    final ldpcInputTicket =
        response['ldpcInputTicket']?.toString().trim() ?? '';
    if (userId.isEmpty ||
        secret.isEmpty ||
        token.isEmpty ||
        ldpcInputTicket.isEmpty ||
        ldpcInputTicket.length > 256) {
      return null;
    }
    return BiometricEnrollmentProvision(
      userId: userId,
      username: username,
      phone: phone,
      secret: secret,
      token: token,
      deviceId: deviceId,
      ldpcInputTicket: ldpcInputTicket,
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
    if (response is! Map) {
      return BiometricLdpcInput.rejected();
    }
    if (response['accepted'] != true) {
      return response['pending'] == true
          ? BiometricLdpcInput.pending()
          : BiometricLdpcInput.rejected();
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
        pending: false,
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
    // JPEG encoding a full camera frame is deliberately moved off the UI
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
            filename: 'retina-face.jpg',
            contentType: MediaType('image', 'jpeg'),
          ),
        )
        ..add(
          http.MultipartFile.fromBytes(
            'livenessFrames',
            capture['livenessFrame']! as Uint8List,
            filename: 'liveness-frame.jpg',
            contentType: MediaType('image', 'jpeg'),
          ),
        );
    }
    // Correlates duration-only frontend and backend diagnostics. It identifies
    // neither the person nor their biometric data.
    final requestId = _requestId();
    print(
      '[BiometricTiming] pipeline=Upload stage=batch_payload_ready '
      'candidates=${encodedCaptures.length} '
      'total_bytes=${files.fold<int>(0, (sum, file) => sum + file.length)}',
    );
    final stopwatch = Stopwatch()..start();
    try {
      return await _serializeUpload(() => ApiService.postMultipart(
        path,
        {
          ...fields,
          'livenessGeometry': jsonEncode(livenessGeometry),
          'adafaceLandmarks': jsonEncode(adafaceLandmarks),
        },
        files: files,
        token: token,
        headers: {'X-Biometric-Request-Id': requestId},
      ));
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
    String? wrytteId,
    String? userId,
    String? token,
    required int candidateIndex,
    required String? captureSessionId,
    String? deviceModel,
    String? language,
    String? region,
    required BiometricCropSet capture,
  }) async {
    // Five *accepted* candidates are required. A liveness-rejected upload is
    // replaced with a new submission number, so a bounded continuous scan can
    // submit up to 300 valid target frames rather than only the first five.
    if (candidateIndex < 0 || candidateIndex > 299) {
      throw ArgumentError('Invalid biometric candidate index.');
    }
    // Reserve the HTTP slot before encoding. Encoding can overlap the previous
    // upload, while the request itself waits for earlier candidates.
    final uploadReservation = _reserveUpload();
    // JPEG encoding remains off the UI isolate while the camera preview keeps
    // running. This is a single candidate pair, not a five-frame batch.
    final encoded = await BiometricStageTiming.measureAsync(
      'Upload',
      'jpeg_encoding',
      () => compute(_encodeCapture, <String, Object>{
        'retinaFace': capture.retinaFaceBgr,
        'landmarks': _landmarks(capture.adafaceLandmarks),
        'livenessFrame': capture.livenessFrameBgr,
        'livenessFrameWidth': capture.livenessFrameWidth,
        'livenessFrameHeight': capture.livenessFrameHeight,
        'x': capture.livenessFaceBox.x,
        'y': capture.livenessFaceBox.y,
        'width': capture.livenessFaceBox.width,
        'height': capture.livenessFaceBox.height,
      }),
    );
    final requestId = _requestId();
    print(
      '[BiometricTiming] pipeline=Upload stage=candidate_payload_ready '
      'index=$candidateIndex retina_face_bytes=${(encoded['retinaFace']! as Uint8List).length} '
      'liveness_frame_bytes=${(encoded['livenessFrame']! as Uint8List).length}',
    );
    final stopwatch = Stopwatch()..start();
    try {
      final uploadGateWait = Stopwatch()..start();
      await uploadReservation.previous;
      uploadGateWait.stop();
      // This isolates ordered-request queueing from JPEG preparation and the
      // network request below; it contains no biometric or account data.
      // ignore: avoid_print
      print(
        '[BiometricTiming] pipeline=Upload stage=candidate_upload_gate '
        'index=$candidateIndex wait_ms=${uploadGateWait.elapsedMilliseconds}',
      );
      if (captureSessionId != null &&
          _completedCaptureSessions.contains(captureSessionId)) {
        print(
          '[BiometricTiming] pipeline=Upload stage=candidate_upload_cancelled '
          'index=$candidateIndex reason=session_completed',
        );
        return <String, Object>{
          'accepted': false,
          'index': candidateIndex,
          'acceptedCandidates': FaceBiometricPipeline.framesToUse,
          'captureSessionId': captureSessionId,
          'error': 'CLIENT_SESSION_COMPLETE',
        };
      }
      final response = await ApiService.postMultipart(
        path,
        <String, String>{
          if (wrytteId != null && wrytteId.trim().isNotEmpty)
            'wrytteId': wrytteId.trim(),
          if (userId != null && userId.trim().isNotEmpty)
            'userId': userId.trim(),
          'candidateIndex': '$candidateIndex',
          if (captureSessionId != null && captureSessionId.isNotEmpty)
            'captureSessionId': captureSessionId,
          if (deviceModel != null && deviceModel.trim().isNotEmpty)
            'deviceModel': deviceModel.trim(),
          if (language != null && language.trim().isNotEmpty)
            'language': language.trim(),
          if (region != null && region.trim().isNotEmpty)
            'region': region.trim(),
          'livenessGeometry': jsonEncode(<Object>[encoded['geometry']!]),
          'adafaceLandmarks': jsonEncode(<Object>[encoded['landmarks']!]),
        },
        files: <http.MultipartFile>[
          http.MultipartFile.fromBytes(
            'retinaFaceFrame',
            encoded['retinaFace']! as Uint8List,
            filename: 'retina-face.jpg',
            contentType: MediaType('image', 'jpeg'),
          ),
          http.MultipartFile.fromBytes(
            'livenessFrame',
            encoded['livenessFrame']! as Uint8List,
            filename: 'liveness-frame.jpg',
            contentType: MediaType('image', 'jpeg'),
          ),
        ],
        token: token,
        headers: <String, String>{'X-Biometric-Request-Id': requestId},
      );
      if (captureSessionId != null &&
          response is Map &&
          (response['completed'] == true ||
              _asInt(response['acceptedCandidates']) ==
                  FaceBiometricPipeline.framesToUse)) {
        _completedCaptureSessions.add(captureSessionId);
      }
      return response;
    } finally {
      uploadReservation.release();
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

  static Uint8List _jpeg(Uint8List bgr, int width, int height) {
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bgr.buffer,
      numChannels: 3,
      order: img.ChannelOrder.bgr,
    );
    return Uint8List.fromList(img.encodeJpg(image, quality: _jpegQuality));
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
      'retinaFace': _jpeg(capture['retinaFace']! as Uint8List, 640, 640),
      'landmarks': capture['landmarks']! as Map<String, double>,
      'livenessFrame': Uint8List.fromList(
        img.encodeJpg(livenessImage, quality: _jpegQuality),
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
