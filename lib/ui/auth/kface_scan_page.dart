import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/face/biometric_api_service.dart';
import 'package:wrytte/services/face/biometric_enrollment_timing.dart';
import 'package:wrytte/services/face/camera_frame_converter.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';
import 'package:wrytte/services/face/local_face_signature_service.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
import 'package:wrytte/ui/auth/kface_access_result_page.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

/// Camera and RetinaFace stay on-device. The backend owns alignment, AdaFace,
/// liveness, and quantization; Flutter owns the local LDPC commitment and
/// proof-of-possession signature. This keeps the scan interface unchanged.
class KFaceScanPage extends StatefulWidget {
  const KFaceScanPage({
    super.key,
    required this.wrytteId,
    this.recoveryData,
    required this.isEnrollment,
  });
  final String wrytteId;
  final KFaceRecoveryData? recoveryData;
  final bool isEnrollment;

  @override
  State<KFaceScanPage> createState() => _KFaceScanPageState();
}

class _KFaceScanPageState extends State<KFaceScanPage> {
  static const _bottomPanelHeight = 250.0;
  final _pipeline = FaceBiometricPipeline();
  final _ldpc = LdpcFuzzyCommitment();
  final _signatureService = LocalFaceSignatureService();
  CameraController? _camera;
  bool _ready = false;
  bool _sending = false;
  bool _uploadingCandidate = false;
  bool _complete = false;
  int _acceptedCandidateCount = 0;
  String? _captureSessionId;
  Stopwatch? _captureToTransitionTimer;
  DateTime? _lastFrame;
  String _status = 'Center your face inside the ring.';
  String? _cameraError;

  bool get _enrolling => widget.isEnrollment;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      if (!(await Permission.camera.request()).isGranted) {
        throw Exception('Camera permission is required.');
      }
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
    if (!_ready || _sending || _uploadingCandidate || _complete) return;
    final now = DateTime.now();
    if (_lastFrame != null &&
        now.difference(_lastFrame!) < const Duration(milliseconds: 100)) {
      return;
    }
    _lastFrame = now;
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
      if (!analysis.faceDetected) {
        setState(() => _status = 'No face detected.');
      } else if (!analysis.targetFaceSelected) {
        setState(() => _status = 'Keep one whole face centered in the ring.');
      } else if (!analysis.alignmentAccepted) {
        setState(() => _status = 'Hold still and look at the camera.');
      } else {
        final capture = analysis.capture;
        if (capture == null) return;
        final candidateIndex = _acceptedCandidateCount;
        _uploadingCandidate = true;
        if (candidateIndex == FaceBiometricPipeline.framesToUse - 1) {
          _captureToTransitionTimer = Stopwatch()..start();
          if (_enrolling) BiometricEnrollmentTiming.start();
        }
        setState(
          () =>
              _status =
                  'Capturing ${candidateIndex + 1} of ${FaceBiometricPipeline.framesToUse}…',
        );
        unawaited(_uploadCandidate(capture, candidateIndex));
      }
    } catch (_) {
      // Frames are disposable; an invalid transient camera frame is ignored.
    }
  }

  /// Sends each selected target frame immediately. A rejected candidate stays
  /// at the same index, while accepted candidates are deleted from device
  /// memory before the next frame is scanned.
  Future<void> _uploadCandidate(
    BiometricCropSet capture,
    int candidateIndex,
  ) async {
    try {
      final result =
          _enrolling
              ? await BiometricApiService.enrollNewCandidate(
                wrytteId: widget.wrytteId,
                candidateIndex: candidateIndex,
                captureSessionId: _captureSessionId,
                capture: capture,
              )
              : await BiometricApiService.verifyCandidate(
                wrytteId: widget.wrytteId,
                candidateIndex: candidateIndex,
                captureSessionId: _captureSessionId,
                capture: capture,
              );
      capture.clear();
      if (!mounted) return;

      if (!result.accepted ||
          result.index != candidateIndex ||
          result.acceptedCandidates != candidateIndex + 1) {
        // A false result reveals neither liveness nor account information.
        // Keep a valid server session so the same index can be replaced; an
        // absent session means this client must start a fresh five-frame set.
        _captureSessionId = result.captureSessionId;
        _acceptedCandidateCount =
            result.captureSessionId == null ? 0 : result.acceptedCandidates;
        if (candidateIndex == FaceBiometricPipeline.framesToUse - 1) {
          _captureToTransitionTimer?.stop();
          _captureToTransitionTimer = null;
          if (_enrolling) BiometricEnrollmentTiming.cancel();
        }
        setState(() => _status = 'Center your face inside the ring.');
        return;
      }

      _captureSessionId = result.captureSessionId;
      _acceptedCandidateCount = result.acceptedCandidates;
      if (!result.complete) {
        setState(
          () =>
              _status =
                  'Capturing $_acceptedCandidateCount of ${FaceBiometricPipeline.framesToUse}…',
        );
        return;
      }

      _complete = true;
      await _completeSubmission(result.completedInput!);
    } catch (error) {
      // Type-only diagnostic: no request data, identity, image, or token.
      // ignore: avoid_print
      print(
        '[BiometricTiming] stage=candidate_failure type=${error.runtimeType}',
      );
      if (candidateIndex == FaceBiometricPipeline.framesToUse - 1) {
        _captureToTransitionTimer?.stop();
        _captureToTransitionTimer = null;
        if (_enrolling) BiometricEnrollmentTiming.cancel();
      }
      if (mounted) {
        setState(() => _status = 'Center your face inside the ring.');
      }
    } finally {
      capture.clear();
      _uploadingCandidate = false;
    }
  }

  Future<void> _completeSubmission(BiometricLdpcInput biometric) async {
    _sending = true;
    final camera = _camera;
    if (camera?.value.isStreamingImages == true) {
      await camera!.stopImageStream();
    }
    if (mounted) setState(() => _status = 'Verifying securely…');
    try {
      if (_enrolling) {
        if (!biometric.accepted || biometric.enrollmentTicket == null) {
          await _resumeAfterBiometricRejection();
          return;
        }
        final enrollment = await _createLocalEnrollment(biometric.ldpcBits);
        await AuthService.instance.completeClientBiometricEnrollment(
          wrytteId: widget.wrytteId,
          biometricEnrollmentTicket: biometric.enrollmentTicket!,
          kmap: enrollment.commitment.toJson(),
          publicKey: enrollment.publicKey,
        );
        if (!mounted) return;
        _logTransitionTiming('profile_setup');
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => AddProfilePage(isNewUser: true),
          ),
        );
      } else {
        final recovery =
            widget.recoveryData ??
            await AuthService.instance.getKFaceRecoveryData(
              wrytteId: widget.wrytteId,
            );
        if (!biometric.accepted) {
          await _resumeAfterBiometricRejection();
          return;
        }
        final recoveredKey = await _recoverLocalKey(
          biometric.ldpcBits,
          recovery.kmap,
        );
        if (recoveredKey == null) {
          await _resumeAfterBiometricRejection();
          return;
        }
        final signature = await _signatureService.signBackendChallenge(
          hkdfKeyHex: recoveredKey,
          challengeBase64Url: recovery.challenge,
        );
        await AuthService.instance.completeWrytteIdSignIn(
          userId: recovery.userId,
          wrytteId: widget.wrytteId,
          challenge: recovery.challenge,
          signature: signature,
        );
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
      }
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
    _captureSessionId = null;
    _lastFrame = null;
    _sending = false;
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
                      recoveryData: widget.recoveryData,
                      isEnrollment: widget.isEnrollment,
                    ),
              ),
        ),
      );

  Future<void> _startOver() async {
    if (_sending || _uploadingCandidate) return;
    _pipeline.reset();
    setState(() {
      _complete = false;
      _acceptedCandidateCount = 0;
      _captureSessionId = null;
      _lastFrame = null;
      _status = 'Center your face inside the ring.';
    });
    final camera = _camera;
    if (camera != null &&
        camera.value.isInitialized &&
        !camera.value.isStreamingImages) {
      await camera.startImageStream(_onFrame);
    }
  }

  @override
  void dispose() {
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
    final previewHeight = size.height - _bottomPanelHeight;
    final ringSize = (size.width * 0.75).clamp(240.0, 340.0);
    final ringTop = (previewHeight * 0.50) - (ringSize / 2);
    final ringLeft = (size.width - ringSize) / 2;
    const tickRingMargin = 20.0;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: _bottomPanelHeight,
            child: _ScanCamera(
              controller: _camera,
              error: _cameraError,
              onRetry: _initialize,
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: ringLeft - tickRingMargin,
            top: ringTop - tickRingMargin,
            width: ringSize + tickRingMargin * 2,
            height: ringSize + tickRingMargin * 2,
            child: _TickRing(
              size: ringSize + tickRingMargin * 2,
              activeTickFraction: progress,
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              height: _bottomPanelHeight,
              color: Colors.black,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Look at the camera',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: Color(0xFFBFC6CF),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _startOver,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4285DF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                      child: const Text(
                        'Start over',
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

class _TickRing extends StatelessWidget {
  const _TickRing({required this.size, required this.activeTickFraction});
  final double size;
  final double activeTickFraction;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _TickRingPainter(activeTickFraction)),
  );
}

class _TickRingPainter extends CustomPainter {
  const _TickRingPainter(this.activeTickFraction);
  final double activeTickFraction;
  @override
  void paint(Canvas canvas, Size size) {
    const count = 72, length = 14.0, width = 4.0;
    final center = size.center(Offset.zero),
        outer = size.shortestSide / 2,
        inner = outer - length;
    final active = (activeTickFraction.clamp(0.0, 1.0) * count).ceil();
    final paint =
        Paint()
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round;
    for (var index = 0; index < count; index++) {
      final angle = 2 * math.pi * index / count - math.pi / 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      paint.color =
          index < active ? const Color(0xFF00E676) : const Color(0xFFBFC6CF);
      canvas.drawLine(
        center + direction * inner,
        center + direction * outer,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TickRingPainter old) =>
      old.activeTickFraction != activeTickFraction;
}
