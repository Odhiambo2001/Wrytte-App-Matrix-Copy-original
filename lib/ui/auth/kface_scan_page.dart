import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wrytte/services/face/camera_frame_converter.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/face_commitment_store.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';
import 'package:wrytte/services/face/local_face_signature_service.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
import 'package:wrytte/ui/auth/kface_access_result_page.dart';

class KFaceScanPage extends StatefulWidget {
  const KFaceScanPage({super.key, required this.wrytteId});

  final String wrytteId;

  @override
  State<KFaceScanPage> createState() => _KFaceScanPageState();
}

class _KFaceScanPageState extends State<KFaceScanPage>
    with WidgetsBindingObserver {
  static const _analysisThrottle = Duration(microseconds: 66667);
  static const double _bottomPanelHeight = 250;
  static const int _tickRingCount = 72;
  final FaceBiometricPipeline _pipeline = FaceBiometricPipeline();
  final FaceCommitmentStore _commitmentStore = const FaceCommitmentStore();
  final LocalFaceSignatureService _signatureService =
      LocalFaceSignatureService();
  CameraController? _controller;
  Future<void>? _initializeFuture;
  Future<bool>? _finalizationFuture;
  Stopwatch? _firstFrameToKeyStopwatch;
  Stopwatch? _cameraStartupStopwatch;

  int _inFlightFrames = 0;
  bool _completed = false;
  bool _finalizing = false;
  bool _faceModelsReady = false;
  bool _enrollmentFlow = false;
  bool _profileOpened = false;
  bool _accessResultOpened = false;
  FuzzyCommitment? _storedCommitment;
  DateTime? _lastAnalysisAt;
  double _ringProgress = 0;
  String _status = 'Center your face inside the ring.';
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      _cameraStartupStopwatch = Stopwatch()..start();
      final processingReady = () async {
        _storedCommitment = await _commitmentStore.read(widget.wrytteId);
        _enrollmentFlow =
            _storedCommitment == null || _storedCommitment!.kdfSalt.isEmpty;
        _pipeline.configureAdaFacePipeline(
          runDuringCollection: !_enrollmentFlow,
        );
        await _pipeline.initializeDetector();
        _faceModelsReady = true;
        debugPrint(
          '[KFace][Startup] modelsReadyMs='
          '${_cameraStartupStopwatch?.elapsedMilliseconds}',
        );
      }();
      await _initializeCamera(processingReady: processingReady);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cameraError = error.toString();
        _status = 'Unable to initialize the face scanner.';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    final controller = _controller;
    _controller = null;
    _initializeFuture = null;
    unawaited(controller?.dispose());
    final finalization = _finalizationFuture;
    unawaited(
      finalization == null
          ? _pipeline.dispose()
          : finalization.whenComplete(_pipeline.dispose),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(controller.dispose());
      _controller = null;
      _initializeFuture = null;
      _inFlightFrames = 0;
      if (mounted) setState(() {});
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_initializeCamera());
    }
  }

  Future<void> _initializeCamera({Future<void>? processingReady}) async {
    final previousController = _controller;
    _controller = null;
    _initializeFuture = null;
    await previousController?.dispose();

    if (mounted) {
      setState(() {
        _cameraError = null;
        _status = 'Center your face inside the ring.';
      });
    }

    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      if (!mounted) return;
      setState(() {
        _cameraError = 'Camera permission is required.';
        _status = 'Camera permission is required.';
      });
      return;
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _cameraError = 'No camera was found on this device.';
          _status = 'Unable to initialize the camera.';
        });
        return;
      }

      final frontCameras =
          cameras
              .where(
                (camera) => camera.lensDirection == CameraLensDirection.front,
              )
              .toList();
      final front =
          frontCameras.isNotEmpty ? frontCameras.first : cameras.first;
      final controller = await _buildFrontCameraController(front);
      _controller = controller;
      _initializeFuture = Future<void>.value();

      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {});
      debugPrint(
        '[KFace][Startup] cameraPreviewReadyMs='
        '${_cameraStartupStopwatch?.elapsedMilliseconds}',
      );

      final cameraConfiguration = () async {
        await _safeLockPortrait(controller);
        await _safeSetAutomaticExposure(controller);
        await _safeSetMinZoom(controller);
      }();
      await cameraConfiguration;

      if (!mounted) return;
      await _startFaceTracking();
      debugPrint(
        '[KFace][Startup] cameraStreamStartedMs='
        '${_cameraStartupStopwatch?.elapsedMilliseconds}',
      );
      if (processingReady != null) await processingReady;
      _cameraStartupStopwatch?.stop();
      debugPrint(
        '[KFace][Startup] faceAnalysisReadyMs='
        '${_cameraStartupStopwatch?.elapsedMilliseconds}',
      );
      setState(() {});
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _cameraError = _formatCameraError(error);
        _status = 'Unable to initialize the camera.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cameraError = error.toString();
        _status = 'Unable to initialize the camera.';
      });
    }
  }

  Future<CameraController> _buildFrontCameraController(
    CameraDescription front,
  ) async {
    final presetsToTry = <ResolutionPreset>[
      ResolutionPreset.medium,
      ResolutionPreset.high,
      ResolutionPreset.veryHigh,
      ResolutionPreset.low,
    ];

    CameraException? lastCameraException;
    Object? lastError;
    for (final preset in presetsToTry) {
      final controller = CameraController(
        front,
        preset,
        enableAudio: false,
        imageFormatGroup:
            Platform.isIOS
                ? ImageFormatGroup.bgra8888
                : ImageFormatGroup.yuv420,
      );
      try {
        await controller.initialize();
        return controller;
      } on CameraException catch (error) {
        lastCameraException = error;
        await controller.dispose();
      } catch (error) {
        lastError = error;
        await controller.dispose();
      }
    }

    if (lastCameraException != null) throw lastCameraException;
    throw lastError ?? Exception('Unable to initialize the front camera.');
  }

  Future<void> _safeLockPortrait(CameraController controller) async {
    try {
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (error, stackTrace) {
      debugPrint('[Camera] lockCaptureOrientation failed: $error\n$stackTrace');
    }
  }

  Future<void> _safeSetAutomaticExposure(CameraController controller) async {
    try {
      await controller.setExposureMode(ExposureMode.auto);
      final maxExposure = await controller.getMaxExposureOffset();
      const targetOffset = 0.5;
      await controller.setExposureOffset(targetOffset.clamp(0.0, maxExposure));
    } catch (error, stackTrace) {
      debugPrint('[Camera] setExposureMode failed: $error\n$stackTrace');
    }
  }

  Future<void> _safeSetMinZoom(CameraController controller) async {
    try {
      final minZoom = await controller.getMinZoomLevel();
      await controller.setZoomLevel(minZoom);
    } catch (error, stackTrace) {
      debugPrint('[Camera] setZoomLevel failed: $error\n$stackTrace');
    }
  }

  String _formatCameraError(CameraException error) {
    final description = error.description?.trim();
    return description != null && description.isNotEmpty
        ? description
        : error.code;
  }

  Future<void> _startFaceTracking() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isStreamingImages ||
        _completed) {
      return;
    }

    _setStatus('Center your face inside the ring.');
    await controller.startImageStream((frame) async {
      // Start CameraX immediately so preview and frame delivery do not wait
      // for large ONNX sessions. Frames are dropped at zero conversion cost
      // until all face models are ready; the next fresh frame is then scanned.
      if (!_faceModelsReady) return;
      // Reserve one of the five collection slots for every admitted frame.
      // This preserves the two-stage overlap (Retina frame N+1 while
      // liveness/AdaFace process frame N), but prevents a sixth frame from
      // entering the pipeline while the fifth frame is still downstream.
      final reservedFrameCount = _pipeline.acceptedFrameCount + _inFlightFrames;
      if (_inFlightFrames >= 2 ||
          reservedFrameCount >= FaceBiometricPipeline.framesToUse ||
          _completed) {
        return;
      }

      final now = DateTime.now();
      final last = _lastAnalysisAt;
      if (last != null && now.difference(last) < _analysisThrottle) return;
      _lastAnalysisAt = now;

      _inFlightFrames++;
      _firstFrameToKeyStopwatch ??= Stopwatch()..start();
      try {
        final cameraFrameStopwatch = Stopwatch()..start();
        final image = CameraFrameConverter.convert(
          frame,
          sensorOrientation: controller.description.sensorOrientation,
        );
        final cameraConversionMs = cameraFrameStopwatch.elapsedMilliseconds;
        cameraFrameStopwatch
          ..reset()
          ..start();
        final analysis = await _pipeline.processFrame(image);
        final biometricPipelineMs = cameraFrameStopwatch.elapsedMilliseconds;
        if (!mounted || _completed) return;
        cameraFrameStopwatch
          ..reset()
          ..start();
        _updateProgress(analysis);
        final uiUpdateMs = cameraFrameStopwatch.elapsedMilliseconds;
        debugPrint(
          '[KFace][Timing][CameraFrame] '
          'cameraConversionMs=$cameraConversionMs '
          'biometricPipelineMs=$biometricPipelineMs '
          'uiUpdateMs=$uiUpdateMs '
          'totalMs=${cameraConversionMs + biometricPipelineMs + uiUpdateMs}',
        );
      } catch (error, stackTrace) {
        debugPrint('[FaceDetect] $error\n$stackTrace');
      } finally {
        _inFlightFrames = math.max(0, _inFlightFrames - 1);
      }
    });
  }

  void _updateProgress(FrameAnalysis analysis) {
    final completeness = analysis.completeness;
    if (completeness.label == 'NONE') {
      _setStatus('No face detected.');
      return;
    }
    if (completeness.label == 'PARTIAL') {
      _setStatus('Keep your whole face visible.');
      return;
    }
    if (!analysis.targetFaceSelected) {
      _setStatus(
        analysis.faceDetected
            ? 'Center your whole face inside the ring.'
            : 'Center your face inside the ring.',
      );
      return;
    }
    final liveness = analysis.liveness;
    if (liveness != null && !liveness.isReal) {
      _setStatus(
        'Possible spoof detected. '
        'V2 ${_percent(liveness.v2.realProbability)} real · '
        'V1SE ${_percent(liveness.v1se.realProbability)} real',
      );
      return;
    }
    if (!analysis.alignmentAccepted) {
      _setStatus('Hold still and look directly at the camera.');
      return;
    }

    final next = (analysis.acceptedFrameCount /
            FaceBiometricPipeline.framesToUse)
        .clamp(0.0, 1.0);
    setState(() {
      _ringProgress = next;
      _status =
          liveness == null
              ? 'Keep looking at the camera.'
              : 'Live face · V2 ${_percent(liveness.v2.realProbability)} real · '
                  'V1SE ${_percent(liveness.v1se.realProbability)} real';
      if (_ringProgress >= 1) {
        _completed = true;
        _status = 'Creating your secure face key…';
      }
    });
    if (_completed) {
      final firstFrameToGreenMs =
          _firstFrameToKeyStopwatch?.elapsedMilliseconds;
      debugPrint(
        '[KFace][Timing][Navigation] '
        'destination=${_enrollmentFlow ? 'PROFILE' : 'ACCESS_RESULT'} '
        'event=FIFTH_FRAME_COMPLETED firstFrameToGreenMs=$firstFrameToGreenMs',
      );
      final finalization = _finalizationFuture ??= _finishBiometricScan();
      unawaited(finalization);
      if (_enrollmentFlow) {
        unawaited(_openSignupProfilePage(finalization));
      }
    }
  }

  String _percent(double probability) =>
      '${(probability * 100).clamp(0, 100).toStringAsFixed(0)}%';

  Future<bool> _finishBiometricScan() async {
    if (_finalizing) return false;
    _finalizing = true;
    try {
      debugPrint('[KFace][Finalization] status=STARTED');
      await _stopImageStreamAfterPendingFrames();
      debugPrint('[KFace][Finalization] camera_stream=STOPPED');
      final stored = _storedCommitment;
      debugPrint(
        '[KFace][Finalization] operation='
        '${stored == null
            ? 'ENROLL'
            : stored.kdfSalt.isEmpty
            ? 'MIGRATE_TO_HKDF'
            : 'VERIFY'}',
      );
      if (stored == null || stored.kdfSalt.isEmpty) {
        if (stored != null) {
          debugPrint(
            '[KFace][Finalization][KDF] migration=LEGACY_SHA256_TO_HKDF',
          );
        }
        final enrollment = await _pipeline.enroll();
        final signatureEnrollment = await _signatureService.enroll(
          enrollment.derivedKey,
        );
        final commitment = enrollment.commitment.withSigningPublicKey(
          signatureEnrollment.publicKeyBase64,
        );
        await _commitmentStore.write(widget.wrytteId, commitment);
        _storedCommitment = commitment;
        _logFirstFrameToKeyDuration();
        _setStatus('Face enrollment complete.');
        debugPrint(
          '[KFace][Finalization][Signature] mode=ENROLL algorithm=Ed25519 '
          'provider=libsodium api=crypto_sign_seed_keypair '
          'publicKey=STORED_LOCAL privateKey=DISCARDED',
        );
        debugPrint('[KFace][Final] result=ENROLLED_SUCCESSFULLY');
        return true;
      } else {
        final recovery = await _pipeline.recover(stored);
        var signatureVerified = false;
        if (recovery.accepted && recovery.derivedKey != null) {
          final publicKey = stored.signingPublicKey;
          if (publicKey == null || publicKey.isEmpty) {
            debugPrint(
              '[KFace][Finalization][Signature] mode=LOGIN result=REJECTED '
              'reason=NO_ENROLLED_PUBLIC_KEY',
            );
          } else {
            final verification = await _signatureService.verifyRecoveredKey(
              identity: widget.wrytteId,
              hkdfKeyHex: recovery.derivedKey!,
              enrolledPublicKeyBase64: publicKey,
            );
            signatureVerified = verification.verified;
            debugPrint(
              '[KFace][Finalization][Signature] mode=LOGIN algorithm=Ed25519 '
              'provider=libsodium '
              'api=crypto_sign_detached+crypto_sign_verify_detached '
              'challengeBytes=${verification.challengeBytes} '
              'signatureBytes=${verification.signatureBytes} '
              'publicKey=ENROLLED_LOCAL privateKey=RECONSTRUCTED_AND_DISCARDED '
              'result=${signatureVerified ? 'VERIFIED' : 'REJECTED'}',
            );
          }
        }
        final accepted = recovery.accepted && signatureVerified;
        _logFirstFrameToKeyDuration();
        debugPrint(
          '[KFace][Final] result='
          '${accepted ? 'FACE_AND_SIGNATURE_VERIFIED_SUCCESSFULLY' : 'FACE_VERIFICATION_FAILED'}',
        );
        _setStatus(
          accepted
              ? 'Face verified successfully.'
              : 'Face verification failed. Start over and try again.',
        );
        _openAccessResultPage(accepted);
        return accepted;
      }
    } catch (error, stackTrace) {
      debugPrint('[KFace] Finalization failed: $error\n$stackTrace');
      _setStatus('Could not complete face verification. Try again.');
      if (!_enrollmentFlow) _openAccessResultPage(false);
      return false;
    } finally {
      _finalizing = false;
    }
  }

  Future<void> _openSignupProfilePage(Future<bool> biometricSetup) async {
    if (!mounted || _profileOpened) return;
    _profileOpened = true;
    final requestedAt = DateTime.now();
    final firstFrameToRequestMs =
        _firstFrameToKeyStopwatch?.elapsedMilliseconds;
    debugPrint(
      '[KFace][Timing][Navigation] destination=PROFILE event=REQUESTED '
      'firstFrameToRequestMs=$firstFrameToRequestMs',
    );
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder:
            (_) => AddProfilePage(
              isNewUser: true,
              biometricSetup: biometricSetup,
              lockNameAndDone: true,
              navigationRequestedAt: requestedAt,
              firstFrameToNavigationRequestMs: firstFrameToRequestMs,
            ),
      ),
    );
  }

  void _logFirstFrameToKeyDuration() {
    final timer = _firstFrameToKeyStopwatch;
    if (timer == null || !timer.isRunning) return;
    timer.stop();
    debugPrint(
      '[KFace][Timing][Total] firstFrameToKeyMs=${timer.elapsedMilliseconds} '
      'targetUnder15Seconds=${timer.elapsedMilliseconds < 15000 ? 'PASS' : 'MISS'}',
    );
  }

  Future<void> _stopImageStreamAfterPendingFrames() async {
    // Finalization can begin inside the fifth image-stream callback. Give its
    // finally block (and any older admitted callback) time to release before
    // detaching CameraX's ImageReader surfaces.
    while (_inFlightFrames > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final controller = _controller;
    if (controller != null && controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  }

  void _openAccessResultPage(bool accepted) {
    if (!mounted || _accessResultOpened) return;
    _accessResultOpened = true;
    unawaited(
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder:
              (_) => KFaceAccessResultPage(
                accepted: accepted,
                retryPageBuilder:
                    (_) => KFaceScanPage(wrytteId: widget.wrytteId),
              ),
        ),
      ),
    );
  }

  void _setStatus(String next) {
    if (!mounted || _status == next) return;
    setState(() => _status = next);
  }

  Future<void> _startOver() async {
    if (_finalizing) return;
    _finalizationFuture = null;
    _pipeline.reset();
    _firstFrameToKeyStopwatch = null;
    setState(() {
      _completed = false;
      _ringProgress = 0;
      _lastAnalysisAt = null;
      _status = 'Center your face inside the ring.';
    });
    await _startFaceTracking();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final previewHeight = size.height - _bottomPanelHeight;
    final ringSize = (size.width * 0.75).clamp(240.0, 340.0);
    final ringCentreFromTop = previewHeight * 0.50;
    final ringLeft = (size.width - ringSize) / 2;
    final ringTop = ringCentreFromTop - ringSize / 2;
    const tickRingMargin = 20.0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      bottomSheet: null,
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const SizedBox.expand(),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: _bottomPanelHeight,
            child: _FullScreenCamera(
              controller: _controller,
              initializeFuture: _initializeFuture,
              error: _cameraError,
              onRetry: _initializeCamera,
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
            width: ringSize + (tickRingMargin * 2),
            height: ringSize + (tickRingMargin * 2),
            child: _TickRing(
              size: ringSize + (tickRingMargin * 2),
              tickCount: _tickRingCount,
              tickWidth: 4,
              tickLength: 14,
              tickColor: const Color(0xFFBFC6CF),
              activeTickColor: const Color(0xFF00E676),
              activeTickFraction: _ringProgress,
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
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
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

class _FullScreenCamera extends StatelessWidget {
  const _FullScreenCamera({
    required this.controller,
    required this.initializeFuture,
    required this.error,
    required this.onRetry,
  });

  final CameraController? controller;
  final Future<void>? initializeFuture;
  final String? error;
  final VoidCallback onRetry;

  static const double _targetPreviewAspect = 3.0 / 4.0;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Container(
        color: const Color(0xFF1D2430),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.camera_alt_rounded,
                  color: Color(0x88FFFFFF),
                  size: 48,
                ),
                const SizedBox(height: 12),
                Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFBFC6CF),
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () async {
                    final status = await Permission.camera.status;
                    if (status.isPermanentlyDenied) {
                      await openAppSettings();
                      return;
                    }
                    onRetry();
                  },
                  child: const Text('Enable camera'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final camera = controller;
    final init = initializeFuture;
    if (camera == null || init == null) return const SizedBox.expand();

    return FutureBuilder<void>(
      future: init,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            !camera.value.isInitialized) {
          return const Center(
            child: SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          );
        }

        final previewSize = camera.value.previewSize;
        final previewAspect =
            previewSize == null
                ? _targetPreviewAspect
                : previewSize.height / previewSize.width;

        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 1000,
              height: 1000 / previewAspect,
              child: CameraPreview(camera),
            ),
          ),
        );
      },
    );
  }
}

class _TickRing extends StatelessWidget {
  const _TickRing({
    required this.size,
    required this.tickCount,
    required this.tickWidth,
    required this.tickLength,
    required this.tickColor,
    required this.activeTickColor,
    required this.activeTickFraction,
  });

  final double size;
  final int tickCount;
  final double tickWidth;
  final double tickLength;
  final Color tickColor;
  final Color activeTickColor;
  final double activeTickFraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _TickRingPainter(
          tickCount: tickCount,
          tickWidth: tickWidth,
          tickLength: tickLength,
          tickColor: tickColor,
          activeTickColor: activeTickColor,
          activeTickFraction: activeTickFraction,
        ),
      ),
    );
  }
}

class _TickRingPainter extends CustomPainter {
  const _TickRingPainter({
    required this.tickCount,
    required this.tickWidth,
    required this.tickLength,
    required this.tickColor,
    required this.activeTickColor,
    required this.activeTickFraction,
  });

  final int tickCount;
  final double tickWidth;
  final double tickLength;
  final Color tickColor;
  final Color activeTickColor;
  final double activeTickFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outerRadius = size.shortestSide / 2;
    final innerRadius = outerRadius - tickLength;
    final activeTicks = (activeTickFraction.clamp(0.0, 1.0) * tickCount).ceil();
    final paint =
        Paint()
          ..strokeWidth = tickWidth
          ..strokeCap = StrokeCap.round;

    for (var index = 0; index < tickCount; index++) {
      final angle = (2 * math.pi * index / tickCount) - math.pi / 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      paint.color = index < activeTicks ? activeTickColor : tickColor;
      canvas.drawLine(
        center + direction * innerRadius,
        center + direction * outerRadius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TickRingPainter oldDelegate) =>
      oldDelegate.activeTickFraction != activeTickFraction ||
      oldDelegate.tickColor != tickColor ||
      oldDelegate.activeTickColor != activeTickColor;
}
