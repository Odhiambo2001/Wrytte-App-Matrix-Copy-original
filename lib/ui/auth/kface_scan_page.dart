import 'package:wrytte/services/face/isolate_face_pipeline.dart';
import 'package:wrytte/services/face/biometric_stage_timing.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/device_metadata_service.dart';
import 'package:wrytte/services/face/biometric_api_service.dart';
import 'package:wrytte/services/face/biometric_enrollment_timing.dart';
import 'package:wrytte/services/face/camera_frame_converter.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';
import 'package:wrytte/services/face/local_face_signature_service.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
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

/// Immutable identity/session snapshot attached when a valid camera frame is
/// extracted. The upload path must never look up a newer screen/session value
/// for an already captured biometric candidate.
class _TaggedBiometricCapture {
  const _TaggedBiometricCapture({
    required this.capture,
    required this.wrytteId,
    required this.userId,
    required this.captureSessionId,
  });

  final BiometricCropSet capture;
  final String wrytteId;
  final String? userId;
  final String captureSessionId;

  void clear() => capture.clear();
}

/// A camera frame is marked with its signup identity before any biometric
/// processing. OpenCV, RetinaFace, liveness, JPEG, and upload therefore all
/// operate on a frame already owned by this WrytteID capture session.
class _TaggedRawBiometricFrame {
  const _TaggedRawBiometricFrame({
    required this.frame,
    required this.wrytteId,
    required this.userId,
    required this.captureSessionId,
  });

  final img.Image frame;
  final String wrytteId;
  final String? userId;
  final String captureSessionId;
}

class _TaggedLivenessCapture {
  const _TaggedLivenessCapture({
    required this.pending,
    required this.wrytteId,
    required this.userId,
    required this.captureSessionId,
  });

  final WorkerLivenessCapture pending;
  final String wrytteId;
  final String? userId;
  final String captureSessionId;

  void clear() => pending.clear();
}

class _TaggedCropCapture {
  const _TaggedCropCapture({
    required this.pending,
    required this.wrytteId,
    required this.userId,
    required this.captureSessionId,
  });

  final WorkerCropCapture pending;
  final String wrytteId;
  final String? userId;
  final String captureSessionId;

  void clear() => pending.clear();
}

class _KFaceScanPageState extends State<KFaceScanPage> {
  FrontendTimingTotal _frontendTiming = FrontendTimingTotal();
  final _scanTotalTimer = Stopwatch()..start();
  Stopwatch? _captureBatchTimer;
  Stopwatch? _normalFramesFrontendTimer;
  Stopwatch? _uploadBatchTimer;
  bool _scanStarted = false;
  bool _scanPhaseReady = false;
  bool _backendWaiting = false;
  bool _verificationFailed = false;
  Timer? _scanStartTimer;
  Timer? _frameRateTimer;
  int _framesThisSecond = 0;
  DateTime? _lastSelectedFrameAt;
  bool _faceAligned = false;
  double _headMovement = 0.5;
  // Keep three local pipeline stages moving: one request may be on the wire,
  // the next candidate may be encoding, and a third may pass RetinaFace and
  // local liveness. [BiometricApiService] still gates HTTP requests in index
  // order, so backend submissions cannot arrive out of order.
  static const _maxConcurrentCandidateUploads = 5;
  // Three candidates eliminate response-driven gaps between frames without
  // rebuilding the former unbounded speculative capture queue. Any work that
  // survives the fifth acceptance is cancelled before it enters HTTP.
  static const _maxCandidateSubmissions = 300;
  final _pipeline = IsolateFacePipeline();
  final _ldpc = LdpcFuzzyCommitment();
  final _signatureService = LocalFaceSignatureService();
  CameraController? _camera;
  bool _ready = false;
  bool _sending = false;
  int _inFlightCandidateUploads = 0;
  final Queue<_TaggedBiometricCapture> _pendingCandidateCaptures =
      Queue<_TaggedBiometricCapture>();
  final Queue<_TaggedLivenessCapture> _pendingLivenessCaptures =
      Queue<_TaggedLivenessCapture>();
  final Queue<_TaggedCropCapture> _pendingCropCaptures =
      Queue<_TaggedCropCapture>();
  // RetinaFace is a single ordered worker. Frames waiting for it are kept in
  // this bounded queue, so handing frame N to BBOX immediately admits frame
  // N+1 without waiting for BBOX or liveness.
  final Queue<_TaggedRawBiometricFrame> _pendingRetinaFrames =
      Queue<_TaggedRawBiometricFrame>();
  bool _retinaWorkerRunning = false;
  bool _processingCrop = false;
  bool _processingLiveness = false;
  bool _complete = false;
  int _acceptedCandidateCount = 0;
  bool _candidateExtractionClosed = false;
  // Set as soon as the fifth candidate is handed to the backend. This keeps
  // the camera preview alive while preventing any later stage from admitting
  // or publishing another frame.
  bool _processingPaused = false;
  int _nextCandidateSubmissionIndex = 0;
  String? _captureSessionId;
  bool _startingCaptureSession = false;
  Stopwatch? _captureToTransitionTimer;
  String _status = 'Position your face\nwithin the circle';
  String? _cameraError;

  bool get _enrolling => widget.isEnrollment;
  bool get _hasCandidateUploadCapacity =>
      _nextCandidateSubmissionIndex < _maxCandidateSubmissions &&
      _inFlightCandidateUploads +
              _pendingCandidateCaptures.length +
              _pendingCropCaptures.length +
              _pendingLivenessCaptures.length +
              (_processingCrop ? 1 : 0) +
              (_processingLiveness ? 1 : 0) <
          FaceBiometricPipeline.framesToUse -
              _nextCandidateSubmissionIndex +
              _inFlightCandidateUploads;

  @override
  void initState() {
    super.initState();
    BiometricApiService.onFrontendPayloadReady = (candidateIndex) {
      if (candidateIndex == FaceBiometricPipeline.framesToUse - 1 &&
          _normalFramesFrontendTimer != null) {
        final timer = _normalFramesFrontendTimer!;
        timer.stop();
        BiometricStageTiming.log('Frontend', 'five_normal_frames_only', timer);
      }
    };
    unawaited(_frontendTiming.run(_initialize));
  }

  Future<void> _initialize() async {
    try {
      await BiometricStageTiming.measureAsync(
        'Models',
        'initialize',
        () => _pipeline.initializeDetector(),
      );
      final cameras = await BiometricStageTiming.measureAsync(
        'Camera',
        'enumerate',
        () => availableCameras(),
      );
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      const capabilities = MethodChannel(
        'com.example.wrytte/camera_capabilities',
      );
      try {
        final ranges = await capabilities.invokeMethod<List<dynamic>>(
          'getFpsRanges',
          {'cameraId': description.name},
        );
        debugPrint(
          '[BiometricTiming] pipeline=Camera stage=supported_fps_ranges '
          'camera_id=${description.name} ranges=${ranges ?? const []} requested_fps=15',
        );
        final supports30 = (ranges ?? const []).any((range) {
          final values = List<dynamic>.from(range as List);
          return values.length >= 2 &&
              (values[0] as num).toInt() <= 30 &&
              (values[1] as num).toInt() >= 30;
        });
        if (!supports30) {
          throw StateError('This camera does not advertise 30 FPS support.');
        }
      } catch (error) {
        debugPrint(
          '[BiometricTiming] pipeline=Camera stage=supported_fps_ranges_error error=$error',
        );
      }
      final camera = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        // Request a consistent scan cadence. The platform uses the nearest
        // supported range if this specific device cannot provide exactly 15.
        fps: 30,
        imageFormatGroup:
            Platform.isIOS
                ? ImageFormatGroup.bgra8888
                : ImageFormatGroup.yuv420,
      );
      await BiometricStageTiming.measureAsync(
        'Camera',
        'initialize',
        () => camera.initialize(),
      );
      await _restoreCameraParameters(camera);
      await camera.startImageStream(_onFrame);
      if (!mounted) return;
      setState(() {
        _camera = camera;
        _ready = true;
      });
      _scanStartTimer?.cancel();
      final startupWaitTimer = Stopwatch()..start();
      _scanStartTimer = Timer(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        BiometricStageTiming.log('UI', 'startup_wait', startupWaitTimer);
        setState(() {
          _scanPhaseReady = true;
          _scanStarted = true;
          _status = 'Scanning…';
        });
        debugPrint('[BiometricTiming] pipeline=Camera stage=scan_phase_ready');
      });
      _frameRateTimer?.cancel();
      _frameRateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        debugPrint(
          '[BiometricTiming] pipeline=Camera stage=incoming_frames_per_second fps=$_framesThisSecond',
        );
        _framesThisSecond = 0;
      });
      unawaited(_startCaptureSession());
    } catch (error) {
      if (mounted) {
        setState(() {
          // Keep the scanner's approved status vocabulary even when camera
          // setup fails; the camera area remains available for retry.
          _cameraError = null;
          _status = 'Position your face\nwithin the circle';
        });
      }
    }
  }

  Future<void> _restoreCameraParameters(CameraController camera) async {
    try {
      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (error) {
      debugPrint('[Camera] lockCaptureOrientation failed: $error');
    }
    try {
      await camera.setExposureMode(ExposureMode.auto);
      final maxExposure = await camera.getMaxExposureOffset();
      await camera.setExposureOffset(0.5.clamp(0.0, maxExposure));
      await camera.setExposureMode(ExposureMode.locked);
    } catch (error) {
      debugPrint('[Camera] exposure setup failed: $error');
    }
    try {
      final minZoom = await camera.getMinZoomLevel();
      await camera.setZoomLevel(minZoom);
    } catch (error) {
      debugPrint('[Camera] setZoomLevel failed: $error');
    }
  }

  // Camera callbacks must not await BBOX/liveness work. Hand each callback to
  // the bounded RetinaFace admission path and return immediately so the
  // camera can deliver the next frame while the previous frame is cropping
  // or undergoing liveness.
  void _onFrame(CameraImage frame) {
    unawaited(_frontendTiming.run(() => _processCameraFrame(frame)));
  }

  Future<void> _processCameraFrame(CameraImage frame) async {
    _framesThisSecond++;
    if (!_ready ||
        !_scanPhaseReady ||
        _sending ||
        _complete ||
        _candidateExtractionClosed ||
        _processingPaused ||
        !_hasCandidateUploadCapacity) {
      return;
    }
    final now = DateTime.now();
    if (_lastSelectedFrameAt != null &&
        now.difference(_lastSelectedFrameAt!).inMilliseconds < 133) {
      return;
    }
    final sessionId = _captureSessionId;
    final camera = _camera;
    if (sessionId == null || camera == null) return;
    _lastSelectedFrameAt = now;
    _captureBatchTimer ??= Stopwatch()..start();
    try {
      final image = BiometricStageTiming.measure(
        'Camera',
        'convert_and_rotate',
        () => CameraFrameConverter.convert(
          frame,
          sensorOrientation: camera.description.sensorOrientation,
        ),
      );
      final tagged = _TaggedRawBiometricFrame(
        frame: image,
        wrytteId: widget.wrytteId,
        userId: widget.userId,
        captureSessionId: sessionId,
      );
      if (_pendingRetinaFrames.length >= 3) {
        _wipeCameraFrame(_pendingRetinaFrames.removeFirst().frame);
      }
      _pendingRetinaFrames.addLast(tagged);
      _drainRetinaFrames();
    } catch (error) {
      debugPrint(
        '[BiometricTiming] pipeline=Frame stage=retina_admission_error error=${error.runtimeType}',
      );
    }
  }

  void _drainRetinaFrames() {
    if (_retinaWorkerRunning ||
        _complete ||
        _processingPaused ||
        _candidateExtractionClosed ||
        _pendingRetinaFrames.isEmpty) {
      return;
    }
    final tagged = _pendingRetinaFrames.removeFirst();
    _retinaWorkerRunning = true;
    unawaited(
      _frontendTiming.run(() async {
        try {
          final retina = await BiometricStageTiming.measureAsync(
            'FaceFrame',
            'retina_and_bbox',
            () => _pipeline.processRetinaFrame(tagged.frame),
          );
          if (!mounted ||
              _complete ||
              _processingPaused ||
              tagged.captureSessionId != _captureSessionId) {
            retina.pendingCrop?.clear();
            return;
          }
          final analysis = retina.analysis;
          if (analysis.processingMilliseconds == 0) return;
          setState(() {
            _faceAligned =
                analysis.faceDetected &&
                analysis.targetFaceSelected &&
                analysis.alignmentAccepted;
            if (_faceAligned) _scanStarted = true;
            if (analysis.faceCenterX != null) {
              _headMovement = (analysis.faceCenterX! / 640).clamp(0.0, 1.0);
            }
          });
          final pendingCrop = retina.pendingCrop;
          if (pendingCrop == null) {
            if (!analysis.faceDetected) {
              setState(
                () =>
                    _status =
                        'Face not detected.\nPosition your face within the circle',
              );
            } else if (analysis.multipleFaces) {
              setState(
                () =>
                    _status =
                        'Multiple faces detected.\nCenter one face within the circle',
              );
            } else if (analysis.faceTooFar) {
              setState(() => _status = 'Move your face closer to the camera');
            } else if (analysis.faceTooClose) {
              setState(
                () => _status = 'Move your face farther from the camera',
              );
            }
            return;
          }
          // RetinaFace passed this target to the independent BBOX worker. The
          // next camera frame can now enter RetinaFace while this frame crops.
          _pendingCropCaptures.addLast(
            _TaggedCropCapture(
              pending: pendingCrop,
              wrytteId: tagged.wrytteId,
              userId: tagged.userId,
              captureSessionId: tagged.captureSessionId,
            ),
          );
          _normalFramesFrontendTimer ??= Stopwatch()..start();
          _drainCropCaptures();
        } catch (error) {
          debugPrint(
            '[BiometricTiming] pipeline=Frame stage=retina_error error=${error.runtimeType}',
          );
        } finally {
          _wipeCameraFrame(tagged.frame);
          _retinaWorkerRunning = false;
          _drainRetinaFrames();
        }
      }),
    );
  }

  void _drainCropCaptures() {
    if (_processingCrop ||
        _complete ||
        _processingPaused ||
        _candidateExtractionClosed ||
        _pendingCropCaptures.isEmpty) {
      return;
    }
    final tagged = _pendingCropCaptures.removeFirst();
    _processingCrop = true;
    unawaited(
      _frontendTiming.run(() async {
        try {
          // BBOX is its own conveyor stage: once N moves to liveness, N+1 can
          // immediately occupy BBOX while RetinaFace processes N+2.
          final pending = await BiometricStageTiming.measureAsync(
            'OpenCV',
            'bbox_to_liveness',
            () async => _pipeline.cropForLiveness(tagged.pending),
          );
          if (!mounted ||
              _complete ||
              _processingPaused ||
              tagged.captureSessionId != _captureSessionId) {
            pending.clear();
            return;
          }
          _pendingLivenessCaptures.addLast(
            _TaggedLivenessCapture(
              pending: pending,
              wrytteId: tagged.wrytteId,
              userId: tagged.userId,
              captureSessionId: tagged.captureSessionId,
            ),
          );
          // Hand the next slot to BBOX before waking liveness. This ordering
          // keeps the conveyor full: while N enters liveness, N+1 starts
          // cropping immediately.
          _drainLivenessCaptures();
        } catch (error) {
          tagged.clear();
          debugPrint(
            '[BiometricTiming] pipeline=OpenCV stage=bbox_error error=${error.runtimeType}',
          );
        } finally {
          // The normal hand-off above releases the worker early. Error and
          // stale-generation paths still release it here.
          _processingCrop = false;
          _drainCropCaptures();
        }
      }),
    );
  }

  void _drainLivenessCaptures() {
    if (_processingLiveness ||
        _complete ||
        _processingPaused ||
        _candidateExtractionClosed ||
        _pendingLivenessCaptures.isEmpty) {
      return;
    }
    final tagged = _pendingLivenessCaptures.removeFirst();
    _processingLiveness = true;
    unawaited(
      _frontendTiming.run(() async {
        var releasedWorker = false;
        try {
          // This worker is intentionally separate from RetinaFace. While it
          // evaluates frame N, the camera callback can run RetinaFace/BBOX for N+1.
          final live = await _pipeline.checkLiveness(tagged.pending);
          if (!mounted ||
              _complete ||
              _processingPaused ||
              tagged.captureSessionId != _captureSessionId) {
            unawaited(_pipeline.resolveRetinaOriginal(tagged.pending, false));
            tagged.pending.capture.clear();
            return;
          }
          // Free liveness as soon as its verdict exists. JPEG receives the
          // retained RetinaFace original in its own worker while frame N+1
          // starts liveness immediately.
          _processingLiveness = false;
          releasedWorker = true;
          _drainLivenessCaptures();
          unawaited(_completeLivenessResult(tagged, live));
        } catch (error) {
          tagged.pending.capture.clear();
          debugPrint(
            '[BiometricTiming] pipeline=Liveness stage=error error=${error.runtimeType}',
          );
        } finally {
          if (!releasedWorker) {
            _processingLiveness = false;
            _drainLivenessCaptures();
          }
        }
      }),
    );
  }

  Future<void> _prepareAndQueueCandidate(_TaggedLivenessCapture tagged) async {
    try {
      // JPEG belongs to its own isolate. The JPEG worker is ordered, so its
      // results preserve the liveness order even while later liveness work
      // runs concurrently.
      await _pipeline.prepareJpeg(tagged.pending.capture);
      if (!mounted ||
          _complete ||
          _processingPaused ||
          tagged.captureSessionId != _captureSessionId) {
        tagged.pending.capture.clear();
        return;
      }
      if (_captureToTransitionTimer == null) {
        _captureToTransitionTimer = Stopwatch()..start();
        if (_enrolling) BiometricEnrollmentTiming.start();
      }
      _pendingCandidateCaptures.addLast(
        _TaggedBiometricCapture(
          capture: tagged.pending.capture,
          wrytteId: tagged.wrytteId,
          userId: tagged.userId,
          captureSessionId: tagged.captureSessionId,
        ),
      );
      _uploadBatchTimer ??= Stopwatch()..start();
      if (mounted) setState(() => _status = 'Scanning…');
      _dispatchPendingCandidateCaptures();
    } catch (error) {
      tagged.pending.capture.clear();
      debugPrint(
        '[BiometricTiming] pipeline=JPEG stage=error error=${error.runtimeType}',
      );
    }
  }

  Future<void> _completeLivenessResult(
    _TaggedLivenessCapture tagged,
    bool live,
  ) async {
    try {
      await _pipeline.resolveRetinaOriginal(tagged.pending, live);
      if (!mounted ||
          _complete ||
          _processingPaused ||
          tagged.captureSessionId != _captureSessionId) {
        tagged.pending.capture.clear();
        return;
      }
      if (!live) {
        tagged.pending.capture.clear();
        setState(
          () =>
              _status =
                  'Face not detected.\nPosition your face within the circle',
        );
        return;
      }
      await _prepareAndQueueCandidate(tagged);
    } catch (error) {
      tagged.pending.capture.clear();
      debugPrint(
        '[BiometricTiming] pipeline=RetinaFace stage=original_error '
        'error=${error.runtimeType}',
      );
    }
  }

  /// The camera opens immediately. This tiny request only obtains the opaque
  /// backend session that lets valid target frames stream in a bounded queue.
  Future<void> _startCaptureSession() async {
    if (_startingCaptureSession || _captureSessionId != null || _complete) {
      return;
    }
    _startingCaptureSession = true;
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
    } finally {
      _startingCaptureSession = false;
    }
  }

  /// Sends locally valid target frames with bounded overlap. The next frame
  /// can encode while the current request waits on transport/backend work.
  void _dispatchPendingCandidateCaptures() {
    if (!mounted ||
        _candidateExtractionClosed ||
        _complete ||
        _sending ||
        _captureSessionId == null) {
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
      final taggedCapture = _pendingCandidateCaptures.removeFirst();
      final candidateIndex = _nextCandidateSubmissionIndex++;
      _inFlightCandidateUploads++;
      // Once the fifth real frame is committed to the ordered upload path,
      // there is no useful sixth target to retain locally. If the backend
      // rejects this batch, its response starts a fresh capture session.
      if (candidateIndex + 1 == FaceBiometricPipeline.framesToUse) {
        _candidateExtractionClosed = true;
        _discardPendingRetinaFrames();
        _discardPendingCropCaptures();
        _discardPendingLivenessCaptures();
      }
      unawaited(
        _frontendTiming.run(
          () => _uploadCandidate(taggedCapture, candidateIndex),
        ),
      );
    }
  }

  Future<void> _uploadCandidate(
    _TaggedBiometricCapture taggedCapture,
    int candidateIndex,
  ) async {
    final capture = taggedCapture.capture;
    final requestSessionId = taggedCapture.captureSessionId;
    try {
      if (candidateIndex + 1 == FaceBiometricPipeline.framesToUse) {
        _pauseFrontendProcessing();
      }
      DeviceMetadata? signupDeviceMetadata;
      if (_enrolling && !widget.attachToExistingUser) {
        try {
          signupDeviceMetadata = await BiometricStageTiming.measureAsync(
            'Upload',
            'device_metadata',
            () => DeviceMetadataService.instance.collect(),
          );
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
                    userId: taggedCapture.userId!,
                    token:
                        await AuthService.instance.getValidBackendToken() ?? '',
                    candidateIndex: candidateIndex,
                    captureSessionId: requestSessionId,
                    capture: capture,
                  )
                  : await BiometricApiService.enrollNewCandidate(
                    wrytteId: taggedCapture.wrytteId,
                    candidateIndex: candidateIndex,
                    captureSessionId: requestSessionId,
                    deviceModel: signupDeviceMetadata?.model,
                    language: signupDeviceMetadata?.language,
                    region: signupDeviceMetadata?.region,
                    capture: capture,
                  )
              : await BiometricApiService.verifyCandidate(
                userId: taggedCapture.userId!,
                candidateIndex: candidateIndex,
                captureSessionId: requestSessionId,
                capture: capture,
              );
      capture.clear();
      if (!mounted) return;
      if (_complete) return;

      // Candidate uploads complete out of order. A response from a different
      // backend session is stale and must never replace this scan's session.
      if (requestSessionId != _captureSessionId ||
          result.captureSessionId != null &&
              result.captureSessionId != requestSessionId) {
        return;
      }

      final validAcceptedResult =
          result.accepted &&
          result.index >= 0 &&
          result.acceptedCandidates >= 1 &&
          result.acceptedCandidates <= FaceBiometricPipeline.framesToUse;
      if (!validAcceptedResult) {
        // A false result reveals neither liveness nor account information.
        // Keep a valid server session so the same index can be replaced; an
        // absent session means this client must start a fresh five-frame set.
        _acceptedCandidateCount = math.max(
          _acceptedCandidateCount,
          result.acceptedCandidates,
        );
        final errorCode = result.errorCode?.toUpperCase();
        final fakeFrame =
            errorCode == 'FACE_NOT_LIVE' ||
            errorCode == 'FAKE_FACE' ||
            errorCode == 'LIVENESS_FAILED' ||
            errorCode == 'SPOOF_DETECTED';
        final invalidGeometry = errorCode == 'INVALID_GEOMETRY';
        setState(
          () =>
              _status =
                  fakeFrame || !result.accepted
                      ? 'Face not detected.\nPosition your face within the circle'
                      : 'Face not detected.\nPosition your face within the circle',
        );
        // The backend cannot accept further candidates in a geometry-invalid
        // session. Start a fresh session instead of advancing its index.
        if (fakeFrame || invalidGeometry || !result.accepted) {
          await _resumeAfterBiometricRejection();
        }
        return;
      }

      _captureSessionId = requestSessionId;
      _acceptedCandidateCount = math.max(
        _acceptedCandidateCount,
        result.acceptedCandidates,
      );
      if (_acceptedCandidateCount >= FaceBiometricPipeline.framesToUse) {
        BiometricStageTiming.log(
          'Capture',
          'five_live_frames',
          _captureBatchTimer!,
        );
      }
      if (!result.complete) {
        setState(() => _status = 'Scanning…');
        return;
      }

      if (_uploadBatchTimer != null) {
        BiometricStageTiming.log(
          'Upload',
          'batch_to_backend_acceptance',
          _uploadBatchTimer!,
        );
      }
      // Stop OpenCV/RetinaFace extraction as soon as the backend has accepted
      // the five live candidates. Keep the camera stream open so the preview
      // remains visible while LDPC recovery and challenge signing complete.
      setState(() {
        _complete = true;
        _candidateExtractionClosed = true;
        _backendWaiting = true;
        _status = 'Please wait…';
      });
      // No more candidates may be dispatched once the backend has completed
      // the session. Clear the queue immediately; already in-flight requests
      // are ignored by the completion guard below when they return.
      _discardPendingCandidateCaptures();
      _discardPendingRetinaFrames();
      _discardPendingCropCaptures();
      _discardPendingLivenessCaptures();
      await BiometricStageTiming.measureAsync(
        'UI',
        'completion_wait',
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      if (mounted) {
        setState(() {
          _backendWaiting = false;
          _status = 'Done';
        });
        await BiometricStageTiming.measureAsync(
          'UI',
          'done_display',
          () => Future<void>.delayed(const Duration(milliseconds: 900)),
        );
      }
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
    } catch (error, stackTrace) {
      // Type-only diagnostic: no request data, identity, image, or token.
      // ignore: avoid_print
      debugPrint('[KFaceScan] candidate upload failed: $error\n$stackTrace');
      if (mounted) {
        setState(() => _status = 'Position your face\nwithin the circle');
      }
      if (_processingPaused && !_complete) {
        await _resumeAfterBiometricRejection();
      }
    } finally {
      capture.clear();
      _inFlightCandidateUploads = math.max(0, _inFlightCandidateUploads - 1);
      _dispatchPendingCandidateCaptures();
    }
  }

  /// Drains every frontend-owned queue and closes admission to all stages.
  /// The CameraController is deliberately left initialized and streaming so
  /// the preview remains visible; callbacks return before conversion.
  void _pauseFrontendProcessing() {
    unawaited(_pipeline.reset());
    _processingPaused = true;
    _candidateExtractionClosed = true;
    _discardPendingCandidateCaptures();
    _discardPendingRetinaFrames();
    _discardPendingCropCaptures();
    _discardPendingLivenessCaptures();
  }

  Future<void> _completeExistingUserEnrollment(BiometricLdpcInput input) async {
    _sending = true;
    final camera = _camera;
    if (camera?.value.isStreamingImages == true) {
      await BiometricStageTiming.measureAsync(
        'Camera',
        'stop_stream',
        () => camera!.stopImageStream(),
      );
    }
    try {
      final enrollment = await BiometricStageTiming.measureAsync(
        'LDPC',
        'local_enrollment',
        () => _createLocalEnrollment(input.ldpcBits),
      );
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

  void _wipeCameraFrame(img.Image frame) {
    final bytes = frame.data?.toUint8List();
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
  }

  void _discardPendingRetinaFrames() {
    while (_pendingRetinaFrames.isNotEmpty) {
      _wipeCameraFrame(_pendingRetinaFrames.removeFirst().frame);
    }
  }

  void _discardPendingLivenessCaptures() {
    while (_pendingLivenessCaptures.isNotEmpty) {
      _pendingLivenessCaptures.removeFirst().clear();
    }
  }

  void _discardPendingCropCaptures() {
    while (_pendingCropCaptures.isNotEmpty) {
      _pendingCropCaptures.removeFirst().clear();
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
      await BiometricStageTiming.measureAsync(
        'Camera',
        'stop_stream',
        () => camera!.stopImageStream(),
      );
    }
    await BiometricStageTiming.measureAsync(
      'Session',
      'persist_before_profile',
      () => AuthService.instance.persistPhoneSession(
        userId: provision.userId,
        username:
            provision.username.isNotEmpty
                ? provision.username
                : widget.wrytteId,
        phone: provision.phone.isNotEmpty ? provision.phone : widget.wrytteId,
        secret: provision.secret,
        token: provision.token,
        preferMatrixRegisterFirst: true,
        deferNonEssentialInitialization: true,
      ),
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
      await BiometricStageTiming.measureAsync(
        'Session',
        'device_registration',
        () => DeviceMetadataService.instance.registerWithBackend(
          userId: provision.userId,
        ),
      );
    } catch (error) {
      debugPrint('[KFaceScan] Wrytte-ID device registration deferred: $error');
    }
    // This task retains no image. It waits only for the opaque delivery ticket
    // and completes the client-owned LDPC commitment after navigation.
    unawaited(
      runZoned(
        () => _completeEnrollmentInBackground(provision),
        zoneValues: {FrontendTimingTotal.zoneKey: null},
      ),
    );
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
      final biometric = await BiometricStageTiming.measureAsync(
        'Enrollment',
        'wait_for_ldpc_input',
        () => _waitForEnrollmentLdpcInput(provision),
      );
      if (biometric == null ||
          !biometric.accepted ||
          biometric.enrollmentTicket == null) {
        throw StateError('Biometric finalization was not accepted.');
      }
      final enrollment = await _createLocalEnrollment(biometric.ldpcBits);
      await BiometricStageTiming.measureAsync(
        'Enrollment',
        'finalize_request',
        () => AuthService.instance.completeClientBiometricEnrollment(
          wrytteId: widget.wrytteId,
          biometricEnrollmentTicket: biometric.enrollmentTicket!,
          kmap: enrollment.commitment.toJson(),
          publicKey: enrollment.publicKey,
        ),
      );
      // Deliberately no identity, ticket, image, score, vector, or key data.
      // ignore: avoid_print
      debugPrint(
        '[BiometricTiming] stage=background_enrollment_finalization outcome=accepted',
      );
    } catch (error) {
      // The account session remains valid while a transient background task is
      // retried by the next app launch or explicit biometric recovery flow.
      // ignore: avoid_print
      debugPrint(
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
    if (mounted) setState(() => _status = 'Please wait…');
    try {
      final recoveredKey = await BiometricStageTiming.measureAsync(
        'LDPC',
        'local_recovery',
        () => _recoverLocalKey(verification.input.ldpcBits, verification.kmap),
      );
      if (recoveredKey == null) {
        await _resumeAfterBiometricRejection();
        return;
      }
      final signature = await BiometricStageTiming.measureAsync(
        'Verification',
        'sign_challenge',
        () => _signatureService.signBackendChallenge(
          hkdfKeyHex: recoveredKey,
          challengeBase64Url: verification.challenge,
        ),
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
      await _pipeline.reset();
      if (mounted) {
        if (_enrolling) BiometricEnrollmentTiming.cancel();
        _logTransitionTiming('failure_result');
        setState(() {
          _complete = true;
          _backendWaiting = false;
          _verificationFailed = true;
          _status = 'Verification failed.\nTap “Start over” to try again';
        });
      }
    } finally {
      _sending = false;
    }
  }

  Future<_ClientEnrollment> _createLocalEnrollment(Uint8List ldpcBits) async {
    final timer = Stopwatch()..start();
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
      timer.stop();
      debugPrint(
        '[BiometricTiming] pipeline=LDPC stage=enrollment elapsed_ms=${timer.elapsedMilliseconds}',
      );
      ldpcBits.fillRange(0, ldpcBits.length, 0);
    }
  }

  Future<String?> _recoverLocalKey(
    Uint8List ldpcBits,
    Map<String, dynamic> serializedCommitment,
  ) async {
    final timer = Stopwatch()..start();
    try {
      await _ldpc.initialize();
      final result = _ldpc.recoverQuantizedBits(
        ldpcBits,
        FuzzyCommitment.fromJson(serializedCommitment),
      );
      return result.accepted ? result.derivedKey : null;
    } finally {
      timer.stop();
      debugPrint(
        '[BiometricTiming] pipeline=LDPC stage=recovery elapsed_ms=${timer.elapsedMilliseconds}',
      );
      ldpcBits.fillRange(0, ldpcBits.length, 0);
    }
  }

  /// A false biometric result is deliberately indistinguishable from a bad
  /// capture or an unknown Wrytte ID. Discard all candidates and continue the
  /// original scan rather than showing a result screen that reveals nothing.
  Future<void> _resumeAfterBiometricRejection() async {
    _captureBatchTimer?.stop();
    _normalFramesFrontendTimer?.stop();
    _normalFramesFrontendTimer = null;
    _uploadBatchTimer?.stop();
    _captureBatchTimer = null;
    _uploadBatchTimer = null;
    _frontendTiming = FrontendTimingTotal();
    _scanTotalTimer
      ..reset()
      ..start();
    await _pipeline.reset();
    if (_enrolling) BiometricEnrollmentTiming.cancel();
    _captureToTransitionTimer?.stop();
    _captureToTransitionTimer = null;
    _complete = false;
    _backendWaiting = false;
    _verificationFailed = false;
    _acceptedCandidateCount = 0;
    _candidateExtractionClosed = false;
    _processingPaused = false;
    _scanStarted = false;
    _scanPhaseReady = _ready;
    _scanStartTimer?.cancel();
    _faceAligned = false;
    _nextCandidateSubmissionIndex = 0;
    _captureSessionId = null;
    _discardPendingCandidateCaptures();
    _discardPendingRetinaFrames();
    _discardPendingCropCaptures();
    _discardPendingLivenessCaptures();
    _sending = false;
    unawaited(_startCaptureSession());
    if (!mounted) return;
    setState(() => _status = 'Position your face\nwithin the circle');
    final camera = _camera;
    if (camera != null &&
        camera.value.isInitialized &&
        !camera.value.isStreamingImages) {
      await camera.startImageStream(_onFrame);
    }
  }

  void _logTransitionTiming(String destination) {
    _frontendTiming.log(destination);
    BiometricStageTiming.log(
      'Scan',
      'attempt_to_$destination',
      _scanTotalTimer,
    );
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

  Future<void> _startOver() async {
    if (_sending || _inFlightCandidateUploads > 0) return;
    _captureBatchTimer?.stop();
    _normalFramesFrontendTimer?.stop();
    _normalFramesFrontendTimer = null;
    _uploadBatchTimer?.stop();
    _captureBatchTimer = null;
    _uploadBatchTimer = null;
    _frontendTiming = FrontendTimingTotal();
    _scanTotalTimer
      ..reset()
      ..start();
    await _pipeline.reset();
    setState(() {
      _complete = false;
      _backendWaiting = false;
      _verificationFailed = false;
      _acceptedCandidateCount = 0;
      _candidateExtractionClosed = false;
      _processingPaused = false;
      _scanStarted = false;
      _scanPhaseReady = _ready;
      _scanStartTimer?.cancel();
      _faceAligned = false;
      _nextCandidateSubmissionIndex = 0;
      _captureSessionId = null;
      _status = 'Position your face\nwithin the circle';
    });
    _discardPendingCandidateCaptures();
    _discardPendingRetinaFrames();
    _discardPendingCropCaptures();
    _discardPendingLivenessCaptures();
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
    if (BiometricApiService.onFrontendPayloadReady != null) {
      BiometricApiService.onFrontendPayloadReady = null;
    }
    _frameRateTimer?.cancel();
    _scanStartTimer?.cancel();
    _discardPendingCandidateCaptures();
    _discardPendingRetinaFrames();
    _discardPendingCropCaptures();
    _discardPendingLivenessCaptures();
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
                  ).inflate(6),
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
              showTicks: false,
              scanning:
                  _scanStarted &&
                  _faceAligned &&
                  !_complete &&
                  !_sending &&
                  _captureSessionId != null,
              progress: _complete ? 1.0 : progress,
              waiting: _backendWaiting,
              success: _complete && !_backendWaiting && !_verificationFailed,
              failure: _verificationFailed,
              movement: _headMovement,
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
                      onPressed:
                          (_backendWaiting ||
                                  (_complete && !_verificationFailed))
                              ? null
                              : _startOver,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            (_backendWaiting ||
                                    (_complete && !_verificationFailed))
                                ? const Color(0xFF23262C)
                                : const Color(0xFF4285DF),
                        foregroundColor:
                            (_backendWaiting ||
                                    (_complete && !_verificationFailed))
                                ? const Color(0xFFB8BDC5)
                                : Colors.white,
                        disabledBackgroundColor: const Color(0xFF23262C),
                        disabledForegroundColor: const Color(0xFFB8BDC5),
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
        fit: BoxFit.cover,
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
  const _ScanMaskPainter({required this.faceRect});

  final Rect faceRect;

  @override
  void paint(Canvas canvas, Size size) {
    final mask =
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addOval(faceRect);
    canvas.drawPath(mask, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(covariant _ScanMaskPainter oldDelegate) =>
      oldDelegate.faceRect != faceRect;
}
