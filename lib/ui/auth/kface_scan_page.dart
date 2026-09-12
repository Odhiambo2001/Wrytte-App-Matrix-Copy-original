import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/device_metadata_service.dart';
import 'package:wrytte/services/face/biometric_api_service.dart';
import 'package:wrytte/services/face/biometric_enrollment_timing.dart';
import 'package:wrytte/services/face/camera_frame_converter.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';
import 'package:wrytte/services/face/local_face_signature_service.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
import 'package:wrytte/ui/auth/kface_access_result_page.dart';
import 'package:wrytte/ui/auth/kface_scan_overlay.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

/// Camera and RetinaFace stay on-device. The backend owns alignment, AdaFace,
/// liveness, and quantization; Flutter owns the local LDPC commitment and
/// proof-of-possession signature. This keeps the scan interface unchanged.
class KFaceScanPage extends StatefulWidget {
  const KFaceScanPage({
    super.key,
    required this.wrytteId,
    this.userId,
    this.recoveryData,
    required this.isEnrollment,
    this.attachToExistingUser = false,
  });
  final String wrytteId;

  /// Internal BE account ID returned by the Wrytte-ID search. It marks every
  /// sign-in capture; enrollment has no existing account ID.
  final String? userId;
  final KFaceRecoveryData? recoveryData;
  final bool isEnrollment;
  final bool attachToExistingUser;

  @override
  State<KFaceScanPage> createState() => _KFaceScanPageState();
}

class _KFaceScanPageState extends State<KFaceScanPage> {
  bool _scanStarted = false;
  bool _faceAligned = false;
  // A continuous scan can inspect far more than five target frames, but only
  // this many multipart uploads may consume device/network resources at once.
  static const _maxConcurrentCandidateUploads = 15;
  static const _maxBufferedCandidateCaptures = 30;
  static const _maxCandidateSubmissions = 300;
  final _pipeline = FaceBiometricPipeline();
  final _ldpc = LdpcFuzzyCommitment();
  final _signatureService = LocalFaceSignatureService();
  CameraController? _camera;
  bool _ready = false;
  bool _sending = false;
  int _inFlightCandidateUploads = 0;
  final Queue<BiometricCropSet> _pendingCandidateCaptures =
      Queue<BiometricCropSet>();
  bool _complete = false;
  int _acceptedCandidateCount = 0;
  int _nextCandidateSubmissionIndex = 0;
  String? _captureSessionId;
  Stopwatch? _captureToTransitionTimer;
  String _status = 'Center your face inside the ring.';
  String? _cameraError;

  bool get _enrolling => widget.isEnrollment;
  bool get _hasCandidateUploadCapacity =>
      _nextCandidateSubmissionIndex < _maxCandidateSubmissions &&
      _inFlightCandidateUploads + _pendingCandidateCaptures.length <
          _maxConcurrentCandidateUploads + _maxBufferedCandidateCaptures;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _pipeline.initializeDetector();
      final cameras = await availableCameras();
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        description,
        ResolutionPreset.medium,
        enableAudio: false,
        // Request a consistent scan cadence. The platform uses the nearest
        // supported range if this specific device cannot provide exactly 15.
        fps: 15,
        imageFormatGroup:
            Platform.isIOS
                ? ImageFormatGroup.bgra8888
                : ImageFormatGroup.yuv420,
      );
      await camera.initialize();
      await camera.startImageStream(_onFrame);
      if (!mounted) return;
      setState(() {
        _camera = camera;
        _ready = true;
      });
      unawaited(_startCaptureSession());
    } catch (_) {
      if (mounted) {
        setState(() {
          _cameraError = 'Unable to initialize the face scanner.';
          _status = 'Unable to initialize the face scanner.';
        });
      }
    }
  }

  Future<void> _onFrame(CameraImage frame) async {
    if (!_ready || _sending || _complete || !_hasCandidateUploadCapacity) {
      return;
    }
    if (_captureSessionId == null) return;
    try {
      final camera = _camera;
      if (camera == null) return;
      final image = CameraFrameConverter.convert(
        frame,
        sensorOrientation: camera.description.sensorOrientation,
      );
      final analysis = await _pipeline.processFrame(image);
      if (!mounted) return;
      // The image stream can invoke this callback while RetinaFace is still
      // processing the previous frame. Such a skipped frame has no timing and
      // must not replace the useful on-screen capture status with "No face".
      if (analysis.processingMilliseconds == 0) return;
      setState(() {
        _faceAligned =
            analysis.faceDetected &&
            analysis.targetFaceSelected &&
            analysis.alignmentAccepted;
        if (_faceAligned) _scanStarted = true;
      });
      if (!analysis.faceDetected) {
        setState(() => _status = 'No face detected.');
      } else if (!analysis.targetFaceSelected) {
        setState(() => _status = 'Keep one whole face centered in the ring.');
      } else if (!analysis.alignmentAccepted) {
        setState(() => _status = 'Hold still and look at the camera.');
      } else {
        final capture = analysis.capture;
        if (capture == null) return;
        if (_captureToTransitionTimer == null) {
          _captureToTransitionTimer = Stopwatch()..start();
          if (_enrolling) BiometricEnrollmentTiming.start();
        }
        // The BE selects the five live frames. Queue every local target
        // capture for both signup and sign-in, then drain up to fifteen
        // uploads concurrently. Submission numbers are not accepted slots.
        _pendingCandidateCaptures.addLast(capture);
        _dispatchPendingCandidateCaptures();
        setState(
          () => _status = 'Move your head slowly to complete the circle.',
        );
      }
    } catch (_) {
      // Frames are disposable; an invalid transient camera frame is ignored.
    }
  }

  /// The camera opens immediately. This tiny request only obtains the opaque
  /// backend session that lets valid target frames stream in a bounded queue.
  Future<void> _startCaptureSession() async {
    try {
      final sessionId =
          _enrolling
              ? widget.attachToExistingUser
                  ? await BiometricApiService.startExistingEnrollmentCaptureSession(
                    userId: widget.userId!,
                    token:
                        await AuthService.instance.getValidBackendToken() ?? '',
                  )
                  : await BiometricApiService.startEnrollmentCaptureSession(
                    wrytteId: widget.wrytteId,
                  )
              : await BiometricApiService.startVerifyCaptureSession(
                userId: widget.userId!,
              );
      if (!mounted || _complete || sessionId == null) return;
      _captureSessionId = sessionId;
      _dispatchPendingCandidateCaptures();
    } catch (_) {
      // Keep the scanner visible. A later restart obtains a fresh session.
    }
  }

  /// Sends every locally valid target frame for signup or sign-in. The BE
  /// selects whichever five submissions pass both liveness models; it is not
  /// restricted to the first five. Every local image buffer is cleared after
  /// upload.
  void _dispatchPendingCandidateCaptures() {
    if (_complete || _sending || _captureSessionId == null) {
      return;
    }
    if (_nextCandidateSubmissionIndex >= _maxCandidateSubmissions) {
      _discardPendingCandidateCaptures();
      return;
    }
    while (_inFlightCandidateUploads < _maxConcurrentCandidateUploads &&
        _pendingCandidateCaptures.isNotEmpty &&
        _nextCandidateSubmissionIndex < _maxCandidateSubmissions &&
        !_complete) {
      final capture = _pendingCandidateCaptures.removeFirst();
      final candidateIndex = _nextCandidateSubmissionIndex++;
      _inFlightCandidateUploads++;
      unawaited(_uploadCandidate(capture, candidateIndex));
    }
  }

  Future<void> _uploadCandidate(
    BiometricCropSet capture,
    int candidateIndex,
  ) async {
    try {
      DeviceMetadata? signupDeviceMetadata;
      if (_enrolling && !widget.attachToExistingUser) {
        try {
          signupDeviceMetadata = await DeviceMetadataService.instance.collect();
        } catch (error) {
          debugPrint(
            '[KFaceScan] Wrytte-ID device metadata unavailable: $error',
          );
        }
      }
      final result =
          _enrolling
              ? widget.attachToExistingUser
                  ? await BiometricApiService.enrollExistingCandidate(
                    userId: widget.userId!,
                    token:
                        await AuthService.instance.getValidBackendToken() ?? '',
                    candidateIndex: candidateIndex,
                    captureSessionId: _captureSessionId,
                    capture: capture,
                  )
                  : await BiometricApiService.enrollNewCandidate(
                    wrytteId: widget.wrytteId,
                    candidateIndex: candidateIndex,
                    captureSessionId: _captureSessionId,
                    deviceModel: signupDeviceMetadata?.model,
                    language: signupDeviceMetadata?.language,
                    region: signupDeviceMetadata?.region,
                    capture: capture,
                  )
              : await BiometricApiService.verifyCandidate(
                userId: widget.userId!,
                candidateIndex: candidateIndex,
                captureSessionId: _captureSessionId,
                capture: capture,
              );
      capture.clear();
      if (!mounted) return;
      if (_complete) return;

      final validAcceptedResult =
          result.accepted &&
          result.index >= 0 &&
          result.acceptedCandidates >= 1 &&
          result.acceptedCandidates <= FaceBiometricPipeline.framesToUse;
      if (!validAcceptedResult) {
        // A false result reveals neither liveness nor account information.
        // Keep a valid server session so the same index can be replaced; an
        // absent session means this client must start a fresh five-frame set.
        _captureSessionId = result.captureSessionId;
        _acceptedCandidateCount =
            result.captureSessionId == null
                ? 0
                : _enrolling
                ? math.max(_acceptedCandidateCount, result.acceptedCandidates)
                : result.acceptedCandidates;
        if (result.captureSessionId == null) {
          _scanStarted = false;
          _faceAligned = false;
          _discardPendingCandidateCaptures();
          _nextCandidateSubmissionIndex = 0;
          unawaited(_startCaptureSession());
        }
        setState(
          () =>
              _status =
                  result.errorCode == 'FACE_NOT_LIVE'
                      ? 'Face could not be verified. Try again.'
                      : 'Center your face inside the ring.',
        );
        return;
      }

      _captureSessionId = result.captureSessionId;
      _acceptedCandidateCount = math.max(
        _acceptedCandidateCount,
        result.acceptedCandidates,
      );
      if (!result.complete) {
        setState(
          () => _status = 'Move your head slowly to complete the circle.',
        );
        return;
      }

      // Stop OpenCV/RetinaFace extraction as soon as the backend has accepted
      // the five live candidates. Keep the camera stream open so the preview
      // remains visible while LDPC recovery and challenge signing complete.
      setState(() => _complete = true);
      _discardPendingCandidateCaptures();
      if (_enrolling) {
        if (widget.attachToExistingUser) {
          final input = result.completedInput;
          if (input == null || !input.accepted) {
            await _resumeAfterBiometricRejection();
            return;
          }
          await _completeExistingUserEnrollment(input);
          return;
        }
        final provision = result.enrollmentProvision;
        if (provision == null) {
          await _resumeAfterBiometricRejection();
          return;
        }
        await _openProfileWhileBiometricsFinalize(provision);
        return;
      }
      final verification = result.verificationBootstrap;
      if (verification == null || !verification.input.accepted) {
        await _resumeAfterBiometricRejection();
        return;
      }
      await _completeSubmission(verification);
    } catch (error) {
      // Type-only diagnostic: no request data, identity, image, or token.
      // ignore: avoid_print
      debugPrint(
        '[BiometricTiming] stage=candidate_failure type=${error.runtimeType}',
      );
      if (mounted) {
        setState(() => _status = 'Center your face inside the ring.');
      }
    } finally {
      capture.clear();
      _inFlightCandidateUploads = math.max(0, _inFlightCandidateUploads - 1);
      if (!_complete &&
          _nextCandidateSubmissionIndex >= _maxCandidateSubmissions &&
          _inFlightCandidateUploads == 0) {
        unawaited(_resumeAfterBiometricRejection());
      } else {
        _dispatchPendingCandidateCaptures();
      }
    }
  }

  Future<void> _completeExistingUserEnrollment(BiometricLdpcInput input) async {
    _sending = true;
    final camera = _camera;
    if (camera?.value.isStreamingImages == true) {
      await camera!.stopImageStream();
    }
    try {
      final enrollment = await _createLocalEnrollment(input.ldpcBits);
      var deviceId = await DeviceMetadataService.instance.rememberedDeviceId(
        userId: widget.userId!,
      );
      if (deviceId == null || deviceId.trim().isEmpty) {
        // Recover the device identity if the earlier signup response was not
        // persisted locally.
        final registered = await DeviceMetadataService.instance
            .registerWithBackend(userId: widget.userId);
        deviceId = (registered?['deviceId'] ?? '').toString().trim();
      }
      if (deviceId.trim().isEmpty) {
        throw StateError('Current device identity is unavailable.');
      }
      await AuthService.instance.savePhoneKFaceRecoveryData(
        userId: widget.userId!,
        deviceId: deviceId,
        kmap: enrollment.commitment.toJson(),
        publicKey: enrollment.publicKey,
      );
      if (!mounted) return;
      final currentUser = await AuthService.instance.getCurrentUser();
      if (!mounted) return;
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder:
              (_) => HomeScreen(
                currentUserId: widget.userId!,
                initialProfileName: currentUser?.username,
                initialPhone: currentUser?.phone ?? widget.wrytteId,
              ),
        ),
        (_) => false,
      );
    } catch (error) {
      debugPrint(
        '[BiometricTiming] stage=phone_enrollment_failure type=${error.runtimeType}',
      );
      await _resumeAfterBiometricRejection();
    } finally {
      _sending = false;
    }
  }

  void _discardPendingCandidateCaptures() {
    while (_pendingCandidateCaptures.isNotEmpty) {
      _pendingCandidateCaptures.removeFirst().clear();
    }
  }

  Future<BiometricLdpcInput?> _claimEnrollmentInput(
    BiometricEnrollmentProvision? provision,
  ) async {
    if (provision == null) return null;
    return BiometricApiService.claimEnrollmentLdpcInput(
      wrytteId: widget.wrytteId,
      ldpcInputTicket: provision.ldpcInputTicket,
    );
  }

  /// The fifth live candidate already has an authenticated backend session.
  /// Move to Profile Setup immediately; the one-time LDPC input is delivered
  /// later while the user names the account and enters Home.
  Future<void> _openProfileWhileBiometricsFinalize(
    BiometricEnrollmentProvision provision,
  ) async {
    _sending = true;
    final camera = _camera;
    if (camera?.value.isStreamingImages == true) {
      await camera!.stopImageStream();
    }
    await AuthService.instance.persistPhoneSession(
      userId: provision.userId,
      username:
          provision.username.isNotEmpty ? provision.username : widget.wrytteId,
      phone: provision.phone.isNotEmpty ? provision.phone : widget.wrytteId,
      secret: provision.secret,
      token: provision.token,
      preferMatrixRegisterFirst: true,
      deferNonEssentialInitialization: true,
    );
    if (provision.deviceId.trim().isNotEmpty) {
      try {
        await DeviceMetadataService.instance.rememberDeviceId(
          userId: provision.userId,
          deviceId: provision.deviceId,
        );
      } catch (error) {
        debugPrint(
          '[KFaceScan] Wrytte-ID device identity persistence deferred: $error',
        );
      }
    }
    try {
      await DeviceMetadataService.instance.registerWithBackend(
        userId: provision.userId,
      );
    } catch (error) {
      debugPrint('[KFaceScan] Wrytte-ID device registration deferred: $error');
    }
    // This task retains no image. It waits only for the opaque delivery ticket
    // and completes the client-owned LDPC commitment after navigation.
    unawaited(_completeEnrollmentInBackground(provision));
    if (!mounted) return;
    _logTransitionTiming('profile_setup');
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const AddProfilePage(isNewUser: true),
      ),
    );
  }

  Future<void> _completeEnrollmentInBackground(
    BiometricEnrollmentProvision provision,
  ) async {
    try {
      final biometric = await _waitForEnrollmentLdpcInput(provision);
      if (biometric == null ||
          !biometric.accepted ||
          biometric.enrollmentTicket == null) {
        throw StateError('Biometric finalization was not accepted.');
      }
      final enrollment = await _createLocalEnrollment(biometric.ldpcBits);
      await AuthService.instance.completeClientBiometricEnrollment(
        wrytteId: widget.wrytteId,
        biometricEnrollmentTicket: biometric.enrollmentTicket!,
        kmap: enrollment.commitment.toJson(),
        publicKey: enrollment.publicKey,
      );
      // Deliberately no identity, ticket, image, score, vector, or key data.
      // ignore: avoid_print
      print(
        '[BiometricTiming] stage=background_enrollment_finalization outcome=accepted',
      );
    } catch (error) {
      // The account session remains valid while a transient background task is
      // retried by the next app launch or explicit biometric recovery flow.
      // ignore: avoid_print
      print(
        '[BiometricTiming] stage=background_enrollment_finalization type=${error.runtimeType}',
      );
    }
  }

  Future<BiometricLdpcInput?> _waitForEnrollmentLdpcInput(
    BiometricEnrollmentProvision provision,
  ) async {
    // The endpoint is rate-limited. Ten six-second polls fit its one-minute
    // window while giving server-side Umeyama/AdaFace ample time to finish.
    for (var attempt = 0; attempt < 10; attempt++) {
      final input = await _claimEnrollmentInput(provision);
      if (input == null || input.accepted) return input;
      if (!input.pending) return null;
      await Future<void>.delayed(const Duration(seconds: 6));
    }
    return null;
  }

  Future<void> _completeSubmission(
    BiometricVerificationBootstrap verification,
  ) async {
    _sending = true;
    // Sign-in keeps the camera preview/stream alive, but [_complete] makes
    // [_onFrame] return before OpenCV/RetinaFace performs any more extraction.
    // The page disposes the camera normally after navigation.
    if (mounted) setState(() => _status = 'Verifying securely…');
    try {
      final recoveredKey = await _recoverLocalKey(
        verification.input.ldpcBits,
        verification.kmap,
      );
      if (recoveredKey == null) {
        await _resumeAfterBiometricRejection();
        return;
      }
      final signature = await _signatureService.signBackendChallenge(
        hkdfKeyHex: recoveredKey,
        challengeBase64Url: verification.challenge,
      );
      final signedInUser = await AuthService.instance.completeWrytteIdSignIn(
        userId: widget.userId!,
        wrytteId: widget.wrytteId,
        challenge: verification.challenge,
        signature: signature,
      );
      try {
        await DeviceMetadataService.instance.registerWithBackend(
          userId: signedInUser.userId,
        );
      } catch (error) {
        debugPrint('[KFaceScan] sign-in device registration deferred: $error');
      }
      if (!mounted) return;
      final user = await AuthService.instance.getCurrentUser();
      if (!mounted) return;
      _logTransitionTiming('home');
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder:
              (_) => HomeScreen(
                currentUserId: user!.userId,
                initialProfileName: user.username,
                initialPhone: user.phone,
              ),
        ),
        (_) => false,
      );
    } catch (error) {
      // Type-only diagnostic: no request data, identity, image, or token.
      // ignore: avoid_print
      print('[BiometricTiming] stage=submit_failure type=${error.runtimeType}');
      _pipeline.reset();
      if (mounted) {
        if (_enrolling) BiometricEnrollmentTiming.cancel();
        _logTransitionTiming('failure_result');
        await _showResult(false);
      }
    } finally {
      _sending = false;
    }
  }

  Future<_ClientEnrollment> _createLocalEnrollment(Uint8List ldpcBits) async {
    try {
      await _ldpc.initialize();
      final commitment = _ldpc.enrollQuantizedBits(ldpcBits);
      final key = _ldpc.deriveEnrollmentKeyFromQuantizedBits(
        ldpcBits,
        commitment,
      );
      final signing = await _signatureService.enroll(key);
      return _ClientEnrollment(
        commitment: commitment.withSigningPublicKey(signing.publicKeyBase64),
        publicKey: signing.publicKeyBase64,
      );
    } finally {
      ldpcBits.fillRange(0, ldpcBits.length, 0);
    }
  }

  Future<String?> _recoverLocalKey(
    Uint8List ldpcBits,
    Map<String, dynamic> serializedCommitment,
  ) async {
    try {
      await _ldpc.initialize();
      final result = _ldpc.recoverQuantizedBits(
        ldpcBits,
        FuzzyCommitment.fromJson(serializedCommitment),
      );
      return result.accepted ? result.derivedKey : null;
    } finally {
      ldpcBits.fillRange(0, ldpcBits.length, 0);
    }
  }

  /// A false biometric result is deliberately indistinguishable from a bad
  /// capture or an unknown Wrytte ID. Discard all candidates and continue the
  /// original scan rather than showing a result screen that reveals nothing.
  Future<void> _resumeAfterBiometricRejection() async {
    _pipeline.reset();
    if (_enrolling) BiometricEnrollmentTiming.cancel();
    _captureToTransitionTimer?.stop();
    _captureToTransitionTimer = null;
    _complete = false;
    _acceptedCandidateCount = 0;
    _scanStarted = false;
    _faceAligned = false;
    _nextCandidateSubmissionIndex = 0;
    _captureSessionId = null;
    _discardPendingCandidateCaptures();
    _sending = false;
    unawaited(_startCaptureSession());
    if (!mounted) return;
    setState(() => _status = 'Center your face inside the ring.');
    final camera = _camera;
    if (camera != null &&
        camera.value.isInitialized &&
        !camera.value.isStreamingImages) {
      await camera.startImageStream(_onFrame);
    }
  }

  void _logTransitionTiming(String destination) {
    final timer = _captureToTransitionTimer;
    if (timer == null) return;
    timer.stop();
    // No identity or biometric material is included in performance logs.
    // ignore: avoid_print
    print(
      '[BiometricTiming] stage=navigation destination=$destination '
      'elapsed_ms=${timer.elapsedMilliseconds}',
    );
  }

  Future<void> _showResult(bool accepted) =>
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder:
              (_) => KFaceAccessResultPage(
                accepted: accepted,
                retryPageBuilder:
                    (_) => KFaceScanPage(
                      wrytteId: widget.wrytteId,
                      userId: widget.userId,
                      recoveryData: widget.recoveryData,
                      isEnrollment: widget.isEnrollment,
                      attachToExistingUser: widget.attachToExistingUser,
                    ),
              ),
        ),
      );

  Future<void> _startOver() async {
    if (_sending || _inFlightCandidateUploads > 0) return;
    _pipeline.reset();
    setState(() {
      _complete = false;
      _acceptedCandidateCount = 0;
      _scanStarted = false;
      _faceAligned = false;
      _nextCandidateSubmissionIndex = 0;
      _captureSessionId = null;
      _status = 'Center your face inside the ring.';
    });
    _discardPendingCandidateCaptures();
    final camera = _camera;
    if (camera != null &&
        camera.value.isInitialized &&
        !camera.value.isStreamingImages) {
      await camera.startImageStream(_onFrame);
    }
    unawaited(_startCaptureSession());
  }

  @override
  void dispose() {
    _discardPendingCandidateCaptures();
    unawaited(_camera?.dispose());
    unawaited(_pipeline.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_acceptedCandidateCount /
            FaceBiometricPipeline.framesToUse)
        .clamp(0.0, 1.0);
    final size = MediaQuery.sizeOf(context);
    // The reference keeps the camera card in the upper half and reserves the
    // lower half for the instruction and controls.
    final cameraHeight = size.height * 0.52;
    final bottomPanelHeight = size.height - cameraHeight;
    final previewHeight = cameraHeight;
    final ringSize = (size.width * 0.75).clamp(240.0, 340.0);
    final ringTop = (previewHeight * 0.50) - (ringSize / 2);
    final ringLeft = (size.width - ringSize) / 2;
    const tickRingMargin = 20.0;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: bottomPanelHeight,
            child: _ScanCamera(
              controller: _camera,
              error: _cameraError,
              onRetry: _initialize,
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: bottomPanelHeight,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _ScanMaskPainter(
                  faceRect: Rect.fromLTWH(
                    ringLeft,
                    ringTop,
                    ringSize,
                    ringSize,
                  ),
                  topInset: 0,
                ),
              ),
            ),
          ),
          Positioned(
            left: ringLeft - tickRingMargin,
            top: ringTop - tickRingMargin,
            width: ringSize + tickRingMargin * 2,
            height: ringSize + tickRingMargin * 2,
            child: KFaceScanOverlay(
              faceDiameter: ringSize,
              showTicks: _scanStarted,
              scanning:
                  _faceAligned &&
                  !_complete &&
                  !_sending &&
                  _captureSessionId != null,
              progress: progress,
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              height: bottomPanelHeight,
              color: Colors.black,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                children: [
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _startOver,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF171717),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                      child: const Text(
                        'Start Over',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClientEnrollment {
  const _ClientEnrollment({required this.commitment, required this.publicKey});

  final FuzzyCommitment commitment;
  final String publicKey;
}

class _ScanCamera extends StatelessWidget {
  const _ScanCamera({
    required this.controller,
    required this.error,
    required this.onRetry,
  });
  final CameraController? controller;
  final String? error;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Container(
        color: const Color(0xFF1D2430),
        child: Center(
          child: Text(
            error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFBFC6CF), fontSize: 15),
          ),
        ),
      );
    }
    final camera = controller;
    if (camera == null || !camera.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      );
    }
    final preview = camera.value.previewSize;
    final aspect = preview == null ? 3 / 4 : preview.height / preview.width;
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 1000,
          height: 1000 / aspect,
          child: CameraPreview(camera),
        ),
      ),
    );
  }
}

class _ScanMaskPainter extends CustomPainter {
  const _ScanMaskPainter({required this.faceRect, required this.topInset});

  final Rect faceRect;
  final double topInset;

  @override
  void paint(Canvas canvas, Size size) {
    final mask =
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addOval(faceRect);
    canvas.drawPath(mask, Paint()..color = Colors.black);

    final frame = Rect.fromLTRB(
      8,
      topInset + 8,
      size.width - 8,
      size.height - 8,
    );
    if (frame.isEmpty) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, const Radius.circular(44)),
      Paint()
        ..color = const Color(0xFF282828)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _ScanMaskPainter oldDelegate) =>
      oldDelegate.faceRect != faceRect || oldDelegate.topInset != topInset;
}
