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
import 'package:wrytte/services/face/biometric_prewarm_service.dart';
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
    this.prewarm,
  });
  final String wrytteId;

  /// Internal BE account ID returned by the Wrytte-ID search. It marks every
  /// sign-in capture; enrollment has no existing account ID.
  final String? userId;
  final KFaceRecoveryData? recoveryData;
  final bool isEnrollment;
  final bool attachToExistingUser;
  final BiometricPrewarmBundle? prewarm;

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
    required this.frameSequence,
  });

  final img.Image frame;
  final String wrytteId;
  final String? userId;
  final String captureSessionId;
  final int frameSequence;
}

class _TaggedLivenessCapture {
  const _TaggedLivenessCapture({
    required this.pending,
    required this.wrytteId,
    required this.userId,
    required this.captureSessionId,
    required this.frameSequence,
    this.blockedSign,
  });

  final WorkerLivenessCapture pending;
  final String wrytteId;
  final String? userId;
  final String captureSessionId;
  final int frameSequence;

  /// Non-null when the target failed the candidate quality/geometry guard
  /// (too far, too close, partial/half face, off-centre, low confidence).
  /// Such a frame is never uploaded and never starts the scan animation; the
  /// value is the sign to show for it.
  final String? blockedSign;

  void clear() => pending.clear();
}

class _TaggedCropCapture {
  const _TaggedCropCapture({
    required this.pending,
    required this.wrytteId,
    required this.userId,
    required this.captureSessionId,
    required this.frameSequence,
    this.blockedSign,
  });

  final WorkerCropCapture pending;
  final String wrytteId;
  final String? userId;
  final String captureSessionId;
  final int frameSequence;

  /// See [_TaggedLivenessCapture.blockedSign].
  final String? blockedSign;

  void clear() => pending.clear();
}

class _KFaceScanPageState extends State<KFaceScanPage> {
  Size? _cachedScreenSize;
  FrontendTimingTotal _frontendTiming = FrontendTimingTotal();
  final _scanTotalTimer = Stopwatch()..start();
  Stopwatch? _captureBatchTimer;
  Stopwatch? _normalFramesFrontendTimer;
  Stopwatch? _uploadBatchTimer;
  bool _scanPhaseReady = false;
  bool _backendWaiting = false;
  bool _verificationFailed = false;

  // ---- SCAN-ANIMATION / WAITING STATE (sign-up AND login) ---------------
  // The 3-D scan animation runs ONLY while the frame on screen is a valid,
  // usable face. "Face not detected", "Move closer", "Move farther",
  // "Multiple faces" and every other RetinaFace answer keep a plain white
  // ring with no animation.
  bool _scanAnimation = false;
  // Set when the fifth candidate is handed to the backend. The green ring
  // makes ONE smooth rotation counted from this moment, then holds.
  DateTime? _waitStartedAt;
  static const _greenAnimation = Duration(seconds: 3);
  static const _doneDisplay = Duration(milliseconds: 900);

  // ---- LOGIN-ONLY STATE -------------------------------------------------
  bool _loginChallengeAccepted = false;
  bool _loginCaptureComplete = false;
  bool _loginCompletionHandling = false;
  BiometricVerificationBootstrap? _pendingLoginVerification;
  // -----------------------------------------------------------------------

  // The generic sign is shown at the beginning and on explicit restart.
  static const _signPosition = 'Position your face\nwithin the circle';
  static const _signNotDetected =
      'Face not detected.\nPosition your face within the circle';
  static const _signMultiple =
      'Multiple faces detected.\nCenter one face within the circle';
  static const _signFar = 'Move your face closer to the camera';
  static const _signClose = 'Move your face farther from the camera';
  static const _signScanning = 'Scanning…';

  // Candidate guard (see _candidateBlockedSign), used by sign-up AND login.
  // A face that is not roughly centred in the circle, is cut by the camera
  // frame, has an implausible (half-face) shape, or that RetinaFace is not
  // confident about, is treated as "face not detected" and never becomes a
  // candidate.
  //  - centre of the face box must be within this fraction of the circle radius
  static const _maxFaceOffCenter = 0.55;
  //  - the face box may overhang the circle by at most this factor of radius
  static const _maxFaceOverhang = 1.15;
  //  - minimum RetinaFace confidence for a candidate
  static const _minFaceConfidence = 0.80;
  //  - a face box touching the camera frame edge (within this fraction of the
  //    frame) is cut off, i.e. a half face
  static const _frameEdgeMargin = 0.01;
  //  - plausible width/height ratio of a complete face box
  static const _minFaceAspect = 0.50;
  static const _maxFaceAspect = 1.30;
  // -----------------------------------------------------------------------

  Timer? _scanStartTimer;
  Timer? _frameRateTimer;
  int _framesThisSecond = 0;
  int _nextFrameSequence = 0;
  int _lastUiFrameSequence = -1;
  DateTime? _lastSelectedFrameAt;
  double _headMovement = 0.5;
  // Keep three local pipeline stages moving: one request may be on the wire,
  // the next candidate may be encoding, and a third may pass RetinaFace and
  // local liveness. [BiometricApiService] still gates HTTP requests in index
  // order, so backend submissions cannot arrive out of order.
  static const _maxConcurrentCandidateUploads = 5;
  // Any work that survives the fifth acceptance is cancelled before it enters
  // HTTP.
  static const _maxCandidateSubmissions = 300;
  late final IsolateFacePipeline _pipeline;
  late final BiometricPrewarmBundle _prewarm;
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
  // RetinaFace has a small bounded worker pool. Frames waiting for it are
  // kept in this queue, so handing frame N to BBOX immediately admits N+1.
  final Queue<_TaggedRawBiometricFrame> _pendingRetinaFrames =
      Queue<_TaggedRawBiometricFrame>();
  int _retinaWorkersRunning = 0;
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
  String _status = _signPosition;
  String? _cameraError;
  // Pending stop of the camera image stream (see _pauseFrontendProcessing).
  Future<void>? _streamStop;

  bool get _enrolling => widget.isEnrollment;
  bool _isExpectedCancellation(Object error) =>
      error is StateError &&
      (error.message.contains('Cancelled') ||
          error.message.contains('Stale generation'));

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

  // ---- SIGN / ANIMATION HELPERS ------------------------------------------

  /// True while any candidate frame sits in the crop -> liveness lane. While
  /// this is true the sign belongs to the liveness answer; RetinaFace
  /// answers are used only when the lane is empty.
  /// The sign/scan-animation is gated centrally, in one place. Nothing may
  /// change the sign while:
  ///  - the waiting UI is armed (`_backendWaiting`) or extraction is paused
  ///    (`_processingPaused`), or
  ///  - an outcome is on screen (`_complete` / `_verificationFailed`: the red
  ///    ring, the check mark), so a late RetinaFace / liveness answer can
  ///    never overwrite the sign or flip the ring back to "Scanning…".
  /// The official waiting/result flow sets state directly, not through this
  /// helper.
  void _setSign(String status, {required bool scanAnimation}) {
    if (!mounted) return;
    if (_backendWaiting ||
        _processingPaused ||
        _complete ||
        _verificationFailed) {
      return;
    }
    if (_status == status && _scanAnimation == scanAnimation) return;
    setState(() {
      _status = status;
      _scanAnimation = scanAnimation;
    });
  }

  /// Shows a RetinaFace-side answer (no candidate produced). It yields to
  /// liveness while any candidate is in the liveness lane.
  void _showRetinaSign(String sign, {required int frameSequence}) {
    if (_backendWaiting || _processingPaused || _complete) return;
    _setSignForFrame(sign, scanAnimation: false, frameSequence: frameSequence);
  }

  // Frame result arbitration: an older, slower liveness result must never
  // bring back Scanning after a newer RetinaFace frame reported far/close,
  // multiple faces, or no usable face.
  void _setSignForFrame(
    String status, {
    required bool scanAnimation,
    required int frameSequence,
  }) {
    if (frameSequence < _lastUiFrameSequence) return;
    _lastUiFrameSequence = frameSequence;
    _setSign(status, scanAnimation: scanAnimation);
  }

  /// RetinaFace answer for a frame that produced NO candidate. Signup and
  /// login both show the specific far/close/multiple/not-detected instruction.
  /// None of these answers starts (or keeps) the scan animation.
  void _applyRetinaAnswer({
    required bool faceDetected,
    required bool multipleFaces,
    required bool faceTooFar,
    required bool faceTooClose,
    required int frameSequence,
  }) {
    final String sign;
    if (faceTooFar) {
      sign = _signFar;
    } else if (faceTooClose) {
      sign = _signClose;
    } else if (multipleFaces) {
      sign = _signMultiple;
    } else if (!faceDetected) {
      sign = _signNotDetected;
    } else {
      sign = _signNotDetected;
    }
    _showRetinaSign(sign, frameSequence: frameSequence);
  }

  /// Decides whether a face RetinaFace selected may become a candidate.
  /// Returns the sign to show when it may NOT (no scanner, nothing uploaded),
  /// or null when the frame is a valid candidate.
  String? _candidateBlockedSign(
    WorkerCropCapture pending, {
    required bool faceTooFar,
    required bool faceTooClose,
  }) {
    if (faceTooFar) return _signFar;
    if (faceTooClose) return _signClose;
    final reason = _candidateRejectReason(pending);
    if (reason != null) {
      debugPrint(
        '[BiometricTiming] pipeline=CandidateGuard stage=candidate_rejected '
        'mode=${_enrolling ? 'signup' : 'login'} reason=$reason '
        'confidence=${pending.target.confidence.toStringAsFixed(3)}',
      );
      return _signNotDetected;
    }
    return null;
  }

  String? _candidateRejectReason(WorkerCropCapture pending) {
    if (pending.target.confidence < _minFaceConfidence) {
      return 'low_confidence';
    }
    final partial = _partialFaceRejectReason(pending);
    if (partial != null) return partial;
    return _circleRejectReason(pending);
  }

  /// A half face: the box is cut by the camera frame, or its shape is not
  /// that of a complete face. Needs only the frame and box, so it never
  /// depends on screen geometry.
  String? _partialFaceRejectReason(WorkerCropCapture pending) {
    final frameWidth = pending.width.toDouble();
    final frameHeight = pending.height.toDouble();
    if (frameWidth <= 0 || frameHeight <= 0) return null;
    final box = pending.box;
    final boxWidth = box.width.toDouble();
    final boxHeight = box.height.toDouble();
    if (boxWidth <= 0 || boxHeight <= 0) return 'empty_box';
    final left = box.x.toDouble();
    final top = box.y.toDouble();
    final right = left + boxWidth;
    final bottom = top + boxHeight;
    final marginX = frameWidth * _frameEdgeMargin;
    final marginY = frameHeight * _frameEdgeMargin;
    if (left <= marginX ||
        top <= marginY ||
        right >= frameWidth - marginX ||
        bottom >= frameHeight - marginY) {
      return 'clipped_by_frame';
    }
    final aspect = boxWidth / boxHeight;
    if (aspect < _minFaceAspect || aspect > _maxFaceAspect) {
      return 'partial_face_shape';
    }
    return null;
  }

  /// Maps the face box from the analysed camera frame to the on-screen circle
  /// using exactly the layout of [_ScanCamera] / [build], then requires the
  /// face to sit inside the circle. The camera sees more than the circle
  /// shows, so without this a head beside or at the edge of the circle counts.
  /// Fails open (returns null) whenever the geometry cannot be trusted.
  String? _circleRejectReason(WorkerCropCapture pending) {
    final preview = _camera?.value.previewSize;
    final screen = _cachedScreenSize;
    if (!mounted ||
        screen == null ||
        preview == null ||
        preview.width <= 0 ||
        preview.height <= 0 ||
        pending.width <= 0 ||
        pending.height <= 0) {
      return null;
    }
    // Same shape as the preview? Otherwise the mapping is not valid.
    final previewAspect = preview.height / preview.width;
    final frameAspect = pending.width / pending.height;
    if ((frameAspect - previewAspect).abs() > 0.06) return null;

    final areaWidth = screen.width;
    final areaHeight = screen.height * 0.52;
    final ringSize = (screen.width * 0.75).clamp(240.0, 340.0);
    final radius = ringSize / 2 + 6;
    final circleX = areaWidth / 2;
    final circleY = areaHeight * 0.5;

    // BoxFit.cover of a 1000 x (1000 / aspect) child, Alignment(0, -0.2).
    const contentWidth = 1000.0;
    final contentHeight = contentWidth / previewAspect;
    final scale = math.max(
      areaWidth / contentWidth,
      areaHeight / contentHeight,
    );
    final shownWidth = contentWidth * scale;
    final shownHeight = contentHeight * scale;
    final offsetX = (areaWidth - shownWidth) / 2;
    final offsetY = (areaHeight - shownHeight) * 0.4;

    final box = pending.box;
    final left = offsetX + box.x / pending.width * shownWidth;
    final right = offsetX + (box.x + box.width) / pending.width * shownWidth;
    final top = offsetY + box.y / pending.height * shownHeight;
    final bottom =
        offsetY + (box.y + box.height) / pending.height * shownHeight;

    final dx = (left + right) / 2 - circleX;
    final dy = (top + bottom) / 2 - circleY;
    if (math.sqrt(dx * dx + dy * dy) > radius * _maxFaceOffCenter) {
      return 'off_center';
    }
    final overhang = radius * _maxFaceOverhang;
    if (left < circleX - overhang ||
        right > circleX + overhang ||
        top < circleY - overhang ||
        bottom > circleY + overhang) {
      return 'outside_circle';
    }
    return null;
  }

  /// Called when the fifth candidate is handed to the backend (sign sign-up
  /// batch, per-candidate sign-up, and login). Extraction has already been
  /// stopped and wiped by [_pauseFrontendProcessing]. The green ring now makes
  /// exactly one rotation; [_awaitMinimumWait] guarantees nothing heavy runs
  /// on the UI thread before that rotation has finished.
  void _startWaitingUi() {
    if (_waitStartedAt != null || !mounted) return;
    _waitStartedAt = DateTime.now();
    // If the backend never completes the batch, the drain in
    // [_finishLoginCandidateBatch] ends in "Verification failed" rather than
    // leaving the green animation running forever.
    if (!_enrolling) _loginCaptureComplete = true;
    setState(() {
      _scanAnimation = false;
      _backendWaiting = true;
      _status = 'Please wait…';
    });
  }

  /// Keeps the green ring on screen for at least [_greenAnimation] counted
  /// from the fifth frame, before any Done / failure outcome shows and before
  /// any UI-thread-heavy work (LDPC) starts, so the rotation is never janked.
  Future<void> _awaitMinimumWait() async {
    final startedAt = _waitStartedAt;
    if (startedAt == null) return;
    final remaining = _greenAnimation - DateTime.now().difference(startedAt);
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
  }
  // -----------------------------------------------------------------------

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedScreenSize = MediaQuery.sizeOf(context);
  }

  @override
  void initState() {
    super.initState();
    _prewarm =
        widget.prewarm ??
        BiometricPrewarmService.take(
          wrytteId: widget.wrytteId,
          userId: widget.userId,
          isEnrollment: widget.isEnrollment,
          attachToExistingUser: widget.attachToExistingUser,
        );
    _pipeline = _prewarm.pipeline;
    BiometricApiService.onFrontendPayloadReady = (candidateIndex) {
      if (candidateIndex == FaceBiometricPipeline.framesToUse - 1 &&
          _normalFramesFrontendTimer != null) {
        final timer = _normalFramesFrontendTimer!;
        timer.stop();
        BiometricStageTiming.log('Frontend', 'five_normal_frames_only', timer);
      }
    };
    unawaited(_frontendTiming.run(() => _initialize(_prewarm)));
  }

  Future<void> _initialize(BiometricPrewarmBundle prewarm) async {
    try {
      // Don't await here — let this run in parallel with camera enumerate/init below.
      final modelsInit = BiometricStageTiming.measureAsync(
        'Models',
        'initialize',
        () async {
          await Future.wait<void>([
            prewarm.pipelineWarmup,
            prewarm.nativeWarmup,
          ]);
        },
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
          'camera_id=${description.name} ranges=${ranges ?? const []} requested_fps=30',
        );
      } catch (error) {
        debugPrint(
          '[BiometricTiming] pipeline=Camera stage=supported_fps_ranges_error error=$error',
        );
      }
      final camera = await _buildCameraController(description);
      await _restoreCameraParameters(camera);
      if (!mounted) {
        await camera.dispose();
        return;
      }

      // CameraX must receive the Flutter preview texture before ImageAnalysis
      // is bound. Starting the stream first can leave a live analyzer with a
      // black preview surface on some devices.
      await modelsInit; // block here — right before frame streaming actually needs warmup done
      await _startFrameStream(camera);
      if (!mounted) {
        await camera.dispose();
        return;
      }
      final retinaWarmup = prewarm.pipelineWarmup;
      setState(() {
        _camera = camera;
        _ready = true;
      });
      final previewMounted = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!previewMounted.isCompleted) previewMounted.complete();
      });
      await previewMounted.future;
      if (!mounted || _camera != camera) {
        await camera.dispose();
        return;
      }
      _scanStartTimer?.cancel();
      final startupWaitTimer = Stopwatch()..start();
      _scanStartTimer = Timer(const Duration(milliseconds: 400), () async {
        if (!mounted) return;
        try {
          await retinaWarmup;
        } catch (error) {
          debugPrint(
            '[BiometricTiming] pipeline=RetinaFace stage=warmup_error '
            'error=${error.runtimeType}',
          );
        }
        if (!mounted) return;
        BiometricStageTiming.log('UI', 'startup_wait', startupWaitTimer);
        debugPrint(
          '[BiometricTiming] pipeline=Camera stage=warmup '
          'elapsed_ms=${startupWaitTimer.elapsedMilliseconds}',
        );
        setState(() {
          _scanPhaseReady = true;
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
      unawaited(
        _startCaptureSession(prefetchedSession: prewarm.captureSession),
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[BiometricTiming] pipeline=Models stage=initialize_error '
        'error=$error\n$stackTrace',
      );
      if (mounted) {
        setState(() {
          _cameraError = null;
          _status = _signPosition;
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

Future<CameraController> _buildCameraController(
  CameraDescription description,
) async {
  Object? lastError;
  for (final preset in <ResolutionPreset>[
    ResolutionPreset.medium, // wider FOV — avoids the “zoomed in” look
    ResolutionPreset.high,
    ResolutionPreset.low,
  ]) {
    final camera = CameraController(
      description,
      preset,
      enableAudio: false,
      fps: 30,
      imageFormatGroup:
          Platform.isIOS
              ? ImageFormatGroup.bgra8888
              : ImageFormatGroup.yuv420,
    );
    try {
      await BiometricStageTiming.measureAsync(
        'Camera',
        'initialize_${preset.name}_30fps',
        () => camera.initialize(),
      );
      return camera;
    } catch (error) {
      lastError = error;
      await camera.dispose();
    }
  }
  throw lastError ?? StateError('Unable to initialize the front camera.');
}

  Future<void> _startFrameStream(CameraController camera) async {
    // If a stop was requested when extraction paused, let it finish first so a
    // restart can never race it.
    final pendingStop = _streamStop;
    if (pendingStop != null) {
      await pendingStop;
      _streamStop = null;
    }
    // Keep Kface on its original single CameraPreview/ImageAnalysis stream.
    // Adding the native CameraX analyzer creates a second use case, which can
    // make some Android front cameras apply a tighter crop to the preview.
    if (!camera.value.isStreamingImages) {
      await camera.startImageStream(_onFrame);
    }
  }

  Future<void> _stopFrameStream() async {
    final camera = _camera;
    if (camera == null) return;
    try {
      if (camera.value.isStreamingImages) {
        await camera.stopImageStream();
      }
    } catch (error) {
      debugPrint('[Camera] stopImageStream failed: $error');
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
    // Keep one frame ready while RetinaFace owns the preceding frame. This
    // allows RetinaFace(N+1) to start immediately when RetinaFace(N) hands
    // N to crop/liveness, without building an unbounded, stale frame backlog.
    if (_pendingRetinaFrames.isNotEmpty) {
      return;
    }
    final now = DateTime.now();
    if (_lastSelectedFrameAt != null &&
        now.difference(_lastSelectedFrameAt!).inMilliseconds < 100) {
      return;
    }
    final sessionId = _captureSessionId;
    final camera = _camera;
    if (sessionId == null || camera == null) return;
    _lastSelectedFrameAt = now;
    final frameSequence = _nextFrameSequence++;
    _captureBatchTimer ??= Stopwatch()..start();
    try {
      final image = await BiometricStageTiming.measureAsync(
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
        frameSequence: frameSequence,
      );
      _pendingRetinaFrames.addLast(tagged);
      _drainRetinaFrames();
    } catch (error) {
      debugPrint(
        '[BiometricTiming] pipeline=Frame stage=retina_admission_error error=${error.runtimeType}',
      );
    }
  }

  void _drainRetinaFrames() {
    if (_retinaWorkersRunning >= IsolateFacePipeline.retinaWorkerCount ||
        _complete ||
        _processingPaused ||
        _candidateExtractionClosed ||
        _pendingRetinaFrames.isEmpty) {
      return;
    }
    while (_retinaWorkersRunning < IsolateFacePipeline.retinaWorkerCount &&
        _pendingRetinaFrames.isNotEmpty) {
      final tagged = _pendingRetinaFrames.removeFirst();
      _retinaWorkersRunning++;
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
            if (analysis.processingMilliseconds == 0) {
              // A frame that could not be analysed cannot justify the
              // initial positioning prompt or a scan animation. Fail closed
              // to the neutral prompt and wait for another frame.
              _setSignForFrame(
                _signNotDetected,
                scanAnimation: false,
                frameSequence: tagged.frameSequence,
              );
              return;
            }
            setState(() {
              if (analysis.faceCenterX != null) {
                _headMovement = (analysis.faceCenterX! / 640).clamp(0.0, 1.0);
              }
            });
            final pendingCrop = retina.pendingCrop;
            if (pendingCrop == null) {
              // No candidate (no face / half face / far / close / multiple):
              // sign-only, plain white ring, no scan animation. Yields to
              // liveness while any candidate is in the liveness lane.
              _applyRetinaAnswer(
                faceDetected: analysis.faceDetected,
                multipleFaces: analysis.multipleFaces,
                faceTooFar: analysis.faceTooFar,
                faceTooClose: analysis.faceTooClose,
                frameSequence: tagged.frameSequence,
              );
              return;
            }
            // Candidate guard for BOTH sign-up and login: far / close /
            // partial (half) face / off-centre / low confidence.
            final blockedSign = _candidateBlockedSign(
              pendingCrop,
              faceTooFar: analysis.faceTooFar,
              faceTooClose: analysis.faceTooClose,
            );
            if (blockedSign != null) {
              // Show the correct sign right away (no animation). The frame
              // still travels the crop -> liveness lane so the worker-side
              // originals are released, but it is never uploaded.
              _showRetinaSign(blockedSign, frameSequence: tagged.frameSequence);
            }
            // RetinaFace passed this target to the independent BBOX worker. The
            // next camera frame can now enter RetinaFace while this frame crops.
            _pendingCropCaptures.addLast(
              _TaggedCropCapture(
                pending: pendingCrop,
                wrytteId: tagged.wrytteId,
                userId: tagged.userId,
                captureSessionId: tagged.captureSessionId,
                frameSequence: tagged.frameSequence,
                blockedSign: blockedSign,
              ),
            );
            _normalFramesFrontendTimer ??= Stopwatch()..start();
            _drainCropCaptures();
          } catch (error) {
            if (!_isExpectedCancellation(error)) {
              debugPrint(
                '[BiometricTiming] pipeline=Frame stage=retina_error '
                'error=${error.runtimeType} detail=$error',
              );
              // Never imply that an unverified frame is real.
              _setSignForFrame(
                _signNotDetected,
                scanAnimation: false,
                frameSequence: tagged.frameSequence,
              );
            }
          } finally {
            _wipeCameraFrame(tagged.frame);
            _retinaWorkersRunning--;
            _drainRetinaFrames();
          }
        }),
      );
    }
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
              frameSequence: tagged.frameSequence,
              blockedSign: tagged.blockedSign,
            ),
          );
          // Hand the next slot to BBOX before waking liveness. This ordering
          // keeps the conveyor full: while N enters liveness, N+1 starts
          // cropping immediately.
          _drainLivenessCaptures();
        } catch (error) {
          tagged.clear();
          if (!_isExpectedCancellation(error)) {
            _setSignForFrame(
              _signNotDetected,
              scanAnimation: false,
              frameSequence: tagged.frameSequence,
            );
            debugPrint(
              '[BiometricTiming] pipeline=OpenCV stage=bbox_error '
              'error=${error.runtimeType} detail=$error',
            );
          }
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
          if (!_isExpectedCancellation(error)) {
            _setSignForFrame(
              _signNotDetected,
              scanAnimation: false,
              frameSequence: tagged.frameSequence,
            );
          }
          debugPrint(
            '[BiometricTiming] pipeline=Liveness stage=error '
            'error=${error.runtimeType} detail=$error',
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
      if (tagged.pending.capture.retinaFaceJpeg == null) {
        await _pipeline.prepareJpeg(tagged.pending.capture);
      }
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
      _dispatchPendingCandidateCaptures();
    } catch (error) {
      tagged.pending.capture.clear();
      debugPrint(
        '[BiometricTiming] pipeline=JPEG stage=error error=${error.runtimeType}',
      );
    }
  }

  /// Liveness / candidate verdict for one frame, sign-up and login.
  ///  - Blocked by the candidate guard (far, close, half face, off-centre,
  ///    low confidence): the guard's sign, plain white ring, NO scan
  ///    animation, frame is wiped and never uploaded.
  ///  - SIGN-UP and LOGIN, local liveness Fake: keep the neutral prompt and
  ///    drop the frame locally. It must never trigger a backend rejection,
  ///    red ring, or scan reset.
  ///  - Real: "Scanning…" + scan animation, frame continues to the backend.
  ///
  /// The `_backendWaiting` / `_processingPaused` / outcome guard lives inside
  /// `_setSign`, so every call site is protected the same way.
  Future<void> _completeLivenessResult(
    _TaggedLivenessCapture tagged,
    bool live,
  ) async {
    bool stale() =>
        !mounted ||
        _complete ||
        _processingPaused ||
        tagged.captureSessionId != _captureSessionId;
    try {
      if (stale()) {
        // Pause/reset already wiped the RetinaFace-side original.
        tagged.pending.capture.clear();
        return;
      }
      final blocked = tagged.blockedSign;
      final dropFrame = blocked != null || !live;
      if (dropFrame) {
        _setSignForFrame(
          blocked ?? _signNotDetected,
          scanAnimation: false,
          frameSequence: tagged.frameSequence,
        );
        debugPrint(
          '[BiometricTiming] pipeline=Liveness stage=local_verdict '
          'outcome=${blocked != null ? 'blocked_by_guard' : 'rejected'} '
          'authority=frontend mode=${_enrolling ? 'signup' : 'login'}',
        );
        await _pipeline.resolveRetinaOriginal(tagged.pending, false);
        tagged.pending.capture.clear();
        return;
      }

      if (live) {
        _setSignForFrame(
          _signScanning,
          scanAnimation: true,
          frameSequence: tagged.frameSequence,
        );
      }
      // Keep the RetinaFace original so the frame can continue to JPEG/upload.
      await _pipeline.resolveRetinaOriginal(tagged.pending, true);
      if (stale()) {
        tagged.pending.capture.clear();
        return;
      }
      await _prepareAndQueueCandidate(tagged);
    } catch (error) {
      tagged.pending.capture.clear();
      if (!_isExpectedCancellation(error)) {
        debugPrint(
          '[BiometricTiming] pipeline=RetinaFace stage=original_error '
          'error=${error.runtimeType}',
        );
      }
    }
  }

  /// The camera opens immediately. This tiny request only obtains the opaque
  /// backend session that lets valid target frames stream in a bounded queue.
  Future<void> _startCaptureSession({
    Future<String?>? prefetchedSession,
  }) async {
    if (_startingCaptureSession || _captureSessionId != null || _complete) {
      return;
    }
    _startingCaptureSession = true;
    try {
      final sessionId =
          await prefetchedSession ??
          (_enrolling
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
              ));
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
      //
      // Pause happens here, synchronously, BEFORE the upload task is even
      // scheduled — so every frame still sitting in RetinaFace/crop/liveness
      // at this exact instant is stopped and its captures wiped before the
      // "Please wait…" UI is armed. `_pauseFrontendProcessing` is idempotent,
      // so the follow-up call inside `_uploadCandidate` is a no-op.
      if (candidateIndex + 1 == FaceBiometricPipeline.framesToUse) {
        _pauseFrontendProcessing();
        // The fifth frame has just been sent to the backend. The green
        // "Please wait…" ring starts its one rotation now.
        _startWaitingUi();
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
      // Defensive/idempotent: the dispatch loop already paused everything
      // synchronously before this task was scheduled. Kept only in case
      // this method is ever reached without going through that loop.
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
      if (_complete && (_enrolling || _verificationFailed)) return;

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
        // Wrapped in setState — this drives `progress` in build().
        setState(() {
          _acceptedCandidateCount = math.max(
            _acceptedCandidateCount,
            result.acceptedCandidates,
          );
        });
        final errorCode = result.errorCode?.toUpperCase();
        final fakeFrame =
            errorCode == 'FACE_NOT_LIVE' ||
            errorCode == 'FAKE_FACE' ||
            errorCode == 'LIVENESS_FAILED' ||
            errorCode == 'SPOOF_DETECTED';
        final invalidGeometry = errorCode == 'INVALID_GEOMETRY';
        if (!_enrolling) {
          // LOGIN: a BACKEND fake/reject is the only thing that turns the
          // ring red (2 s), after which the scan restarts on the
          // "Face not detected" sign.
          await _showBackendFaceRejection();
          return;
        }
        // The backend cannot accept further candidates in a geometry-invalid
        // session. Start a fresh session instead of advancing its index.
        if (fakeFrame || invalidGeometry || !result.accepted) {
          await _showBackendFaceRejection();
        } else {
          _setSign(_signNotDetected, scanAnimation: false);
        }
        return;
      }

      _captureSessionId = requestSessionId;
      setState(() {
        _acceptedCandidateCount = math.max(
          _acceptedCandidateCount,
          result.acceptedCandidates,
        );
      });
      if (_acceptedCandidateCount >= FaceBiometricPipeline.framesToUse &&
          _captureBatchTimer != null) {
        BiometricStageTiming.log(
          'Capture',
          'five_live_frames',
          _captureBatchTimer!,
        );
      }
      if (!result.complete) return;

      if (!_enrolling) {
        _loginCaptureComplete = true;
        _pendingLoginVerification = result.verificationBootstrap;
        await _finishLoginCandidateBatch();
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
      // the five live candidates. Keep the camera preview visible while LDPC
      // recovery and challenge signing complete.
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
      // The green ring makes exactly one rotation counted from the fifth
      // frame; wait only for whatever is left of it.
      await BiometricStageTiming.measureAsync(
        'UI',
        'completion_wait',
        _awaitMinimumWait,
      );
      if (mounted) {
        setState(() {
          _backendWaiting = false;
          _status = 'Done';
        });
        // New-account signup should move to Name immediately after showing
        // Done. Existing-device enrollment keeps its short confirmation hold.
        if (widget.attachToExistingUser) {
          await BiometricStageTiming.measureAsync(
            'UI',
            'done_display',
            () => Future<void>.delayed(_doneDisplay),
          );
        }
      }
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
    } catch (error, stackTrace) {
      // Type-only diagnostic: no request data, identity, image, or token.
      // ignore: avoid_print
      debugPrint('[KFaceScan] candidate upload failed: $error\n$stackTrace');
      // Sign-up only. On login the sign is never dropped back to the generic
      // "Position your face" text by a transient error.
      if (mounted && _enrolling && !_backendWaiting) {
        setState(() => _status = _signPosition);
      }
      if (_processingPaused && !_complete) {
        if (_enrolling) await _awaitMinimumWait();
        if (!mounted || _complete) return;
        await _resumeAfterBiometricRejection();
      }
    } finally {
      capture.clear();
      _inFlightCandidateUploads = math.max(0, _inFlightCandidateUploads - 1);
      if (!_enrolling &&
          _loginCaptureComplete &&
          _inFlightCandidateUploads == 0) {
        unawaited(_finishLoginCandidateBatch());
      }
      _dispatchPendingCandidateCaptures();
    }
  }

  /// LOGIN: runs once every in-flight upload has returned. The green animation
  /// keeps running (minimum [_greenAnimation] from the fifth frame) until
  /// the outcome is known, then either Done (challenge passed) or a red
  /// "Verification failed" (backend rejected, LDPC rejected, challenge false).
  Future<void> _finishLoginCandidateBatch([
    BiometricVerificationBootstrap? verification,
  ]) async {
    if (_loginCompletionHandling || _verificationFailed || !mounted) return;
    final pending = verification ?? _pendingLoginVerification;
    if (_inFlightCandidateUploads > 0) {
      if (pending != null) _pendingLoginVerification = pending;
      return;
    }
    if (pending == null) {
      if (!_loginCaptureComplete) return;
      // All five frames went out but the backend never completed the batch.
      _loginCompletionHandling = true;
      try {
        if (!mounted || _verificationFailed) return;
        _showVerificationFailure();
      } finally {
        _loginCompletionHandling = false;
      }
      return;
    }
    _loginCompletionHandling = true;
    _pendingLoginVerification = null;
    try {
      if (!pending.input.accepted) {
        if (!mounted || _verificationFailed) return;
        _showVerificationFailure();
        return;
      }
      await _completeSubmission(pending);
    } finally {
      _loginCompletionHandling = false;
    }
  }

  /// Drains every frontend-owned queue, closes admission to all stages and
  /// stops the camera image stream.
  ///
  /// The CameraController stays initialized so the preview remains visible;
  /// only the per-frame image delivery to Dart stops. Copying full camera
  /// frames across the platform channel on the UI isolate is what made the
  /// green ring stutter while waiting, and no frame is needed after the fifth
  /// candidate. [_startFrameStream] restarts it on Start over / rejection.
  ///
  /// Idempotent: calling it twice for the same session (once from the dispatch
  /// loop, once defensively from `_uploadCandidate`) is a no-op the second
  /// time.
  void _pauseFrontendProcessing() {
    if (_processingPaused) return;
    unawaited(_pipeline.reset());
    _processingPaused = true;
    _candidateExtractionClosed = true;
    _discardPendingCandidateCaptures();
    _discardPendingRetinaFrames();
    _discardPendingCropCaptures();
    _discardPendingLivenessCaptures();
    _streamStop = _stopFrameStream();
  }

  Future<void> _completeExistingUserEnrollment(BiometricLdpcInput input) async {
    _sending = true;
    await BiometricStageTiming.measureAsync(
      'Camera',
      'stop_stream',
      _stopFrameStream,
    );
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
    await BiometricStageTiming.measureAsync(
      'Camera',
      'stop_stream',
      _stopFrameStream,
    );
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
    unawaited(
      BiometricStageTiming.measureAsync(
        'Session',
        'device_registration',
        () => DeviceMetadataService.instance
            .registerWithBackend(userId: provision.userId)
            .then<void>((_) {})
            .catchError((Object error) {
              debugPrint(
                '[KFaceScan] Wrytte-ID device registration deferred: $error',
              );
            }),
      ),
    );
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

  /// LOGIN ONLY. LDPC recovery and challenge signing/verification each get
  /// their own timing relative to the ring animation, per spec:
  ///
  ///  - LDPC is local and fast. It is never gated behind the ring: if it
  ///    rejects, the ring is cut short and turns red immediately, wherever
  ///    it currently is in its animation.
  ///  - The challenge is a backend round trip whose timing is unknown, so it
  ///    runs concurrently with the rest of the ring animation.
  ///    - If the challenge answers **false** (or errors) at any point, the
  ///      ring turns red immediately.
  ///    - If the challenge answers **true**, the page never advances before
  ///      the ring's minimum duration has also elapsed. If the ring finishes
  ///      first and the challenge hasn't answered yet, the ring HOLDS as a
  ///      full green ring on "Done" until the challenge resolves.
  Future<void> _completeSubmission(
    BiometricVerificationBootstrap verification,
  ) async {
    _sending = true;
    // Sign-in keeps the camera preview alive, but [_complete]/[_processingPaused]
    // make sure no more extraction happens. The page disposes the camera
    // normally after navigation.
    if (mounted) setState(() => _status = 'Please wait…');

    // LDPC recovery is local/fast and is intentionally NOT wrapped in
    // _awaitMinimumWait(): a rejection here must cut the ring short,
    // not wait for the full green animation to play out first.
    final recoveredKey = await BiometricStageTiming.measureAsync(
      'LDPC',
      'local_recovery',
      () => _recoverLocalKey(verification.input.ldpcBits, verification.kmap),
    );
    if (recoveredKey == null) {
      if (mounted) {
        _loginChallengeAccepted = false;
        _logTransitionTiming('failure_result');
        _showVerificationFailure();
      }
      unawaited(_pipeline.reset());
      _sending = false;
      return;
    }

    // LDPC passed. Kick off the challenge round trip and let it race against
    // the ring's minimum duration instead of running strictly after it.
    var settled = false;
    final challengeFuture = _runLoginChallenge(recoveredKey, verification);

    // Failure branch: acts the instant the challenge resolves to a rejection,
    // regardless of whether the ring is still animating or already settled.
    unawaited(
      challengeFuture.then((signedInUser) async {
        if (!mounted || settled || signedInUser != null) return;
        settled = true;
        _loginChallengeAccepted = false;
        _logTransitionTiming('failure_result');
        _showVerificationFailure();
        await _pipeline.reset();
      }),
    );

    // Success branch: never finalizes before the ring's minimum duration,
    // even if the challenge has already answered true.
    await _awaitMinimumWait();
    if (!mounted || settled) {
      _sending = false;
      return;
    }

    // The one-shot green rotation has completed. Hold the full ring while the
    // challenge resolves; success or failure ends it with the final symbol.
    setState(() => _status = 'Done');

    final signedInUser = await challengeFuture;
    if (!mounted || settled || signedInUser == null) {
      _sending = false;
      return;
    }
    settled = true;
    await _finishSuccessfulLogin(signedInUser);
    _sending = false;
  }

  /// Signs and submits the backend challenge for LOGIN. Returns the signed-in
  /// user on success, or null on any failure (network error or explicit
  /// rejection) — never throws — so [_completeSubmission] can race this
  /// against the ring's minimum-duration timer without try/catch plumbing.
  Future<dynamic> _runLoginChallenge(
    String recoveredKey,
    BiometricVerificationBootstrap verification,
  ) async {
    try {
      final signature = await BiometricStageTiming.measureAsync(
        'Verification',
        'sign_challenge',
        () => _signatureService.signBackendChallenge(
          hkdfKeyHex: recoveredKey,
          challengeBase64Url: verification.challenge,
        ),
      );
      return await AuthService.instance.completeWrytteIdSignIn(
        userId: widget.userId!,
        wrytteId: widget.wrytteId,
        challenge: verification.challenge,
        signature: signature,
      );
    } catch (error) {
      // Type-only diagnostic: no request data, identity, image, or token.
      // ignore: avoid_print
      debugPrint(
        '[BiometricTiming] stage=submit_failure type=${error.runtimeType}',
      );
      return null;
    }
  }

  /// LOGIN ONLY. Runs once the challenge has answered true and the ring's
  /// minimum duration has elapsed: shows the checkmark, registers this
  /// device, then navigates Home.
  Future<void> _finishSuccessfulLogin(dynamic signedInUser) async {
    if (!mounted) return;
    setState(() {
      _complete = true;
      _backendWaiting = false;
      _verificationFailed = false;
      _loginChallengeAccepted = true;
      _status = 'Done';
    });
    await Future<void>.delayed(_doneDisplay);
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
  ///
  /// This (backend rejection) is the ONLY path that shows the red ring during
  /// the scan phase of login; a locally-detected fake frame never gets here.
  Future<void> _showBackendFaceRejection() async {
    // Signup's green orbit is a one-shot three-second movement. Keep it
    // running to completion before the rejection state replaces it. Login
    // retains its existing immediate verification-failure behavior.
    if (_enrolling) {
      await _awaitMinimumWait();
    }
    if (!mounted) return;
    setState(() {
      _complete = true;
      _backendWaiting = false;
      _verificationFailed = true;
      _loginChallengeAccepted = false;
      _scanAnimation = false;
      _status = _signNotDetected;
    });
    await Future<void>.delayed(Duration(milliseconds: _enrolling ? 900 : 2000));
    if (mounted && _verificationFailed) {
      await _resumeAfterBiometricRejection();
    }
  }

  void _showVerificationFailure() {
    if (!mounted) return;
    setState(() {
      _complete = true;
      _backendWaiting = false;
      _loginChallengeAccepted = false;
      _scanAnimation = false;
      _verificationFailed = true;
      _status = 'Verification failed.\nTap “Start over” to try again';
    });
  }

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
    _loginChallengeAccepted = false;
    _loginCaptureComplete = false;
    _loginCompletionHandling = false;
    _pendingLoginVerification = null;
    _waitStartedAt = null;
    _scanAnimation = false;
    _acceptedCandidateCount = 0;
    _candidateExtractionClosed = false;
    _processingPaused = false;
    _scanPhaseReady = _ready;
    _scanStartTimer?.cancel();
    _nextCandidateSubmissionIndex = 0;
    _captureSessionId = null;
    _discardPendingCandidateCaptures();
    _discardPendingRetinaFrames();
    _discardPendingCropCaptures();
    _discardPendingLivenessCaptures();
    _sending = false;
    unawaited(_startCaptureSession());
    if (!mounted) return;
    // LOGIN: the generic "Position your face" sign belongs to the very start
    // only. After a rejection the sign stays on "Face not detected" (white
    // ring, no scanner) until a Real face is shown. Sign-up is unchanged.
    setState(() => _status = _enrolling ? _signPosition : _signNotDetected);
    final camera = _camera;
    if (camera != null && camera.value.isInitialized) {
      await _startFrameStream(camera);
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
      _loginChallengeAccepted = false;
      _loginCaptureComplete = false;
      _loginCompletionHandling = false;
      _pendingLoginVerification = null;
      _waitStartedAt = null;
      _scanAnimation = false;
      _acceptedCandidateCount = 0;
      _candidateExtractionClosed = false;
      _processingPaused = false;
      _scanPhaseReady = _ready;
      _scanStartTimer?.cancel();
      _nextCandidateSubmissionIndex = 0;
      _captureSessionId = null;
      // An explicit "Start over" is a genuine fresh start, so the initial
      // instruction is correct here.
      _status = _signPosition;
    });
    _discardPendingCandidateCaptures();
    _discardPendingRetinaFrames();
    _discardPendingCropCaptures();
    _discardPendingLivenessCaptures();
    final camera = _camera;
    if (camera != null && camera.value.isInitialized) {
      await _startFrameStream(camera);
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
    const verticalShift = 24.0;
    // Keep the camera shifted down, but leave the circle slightly higher
    // within it so the guide does not include as much of the chest.
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
            top: verticalShift,
            right: 0,
            bottom: bottomPanelHeight - verticalShift,
            child: _ScanCamera(
              controller: _camera,
              error: _cameraError,
              onRetry: () => _initialize(_prewarm),
            ),
          ),
          Positioned(
            left: 0,
            top: verticalShift,
            right: 0,
            bottom: bottomPanelHeight - verticalShift,
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
            top: verticalShift + ringTop - tickRingMargin,
            width: ringSize + tickRingMargin * 2,
            height: ringSize + tickRingMargin * 2,
            child: KFaceScanOverlay(
              faceDiameter: ringSize,
              showTicks: false,
              // The 3-D scan runs only while the frame on screen is a valid,
              // usable face (sign-up AND login). Not detected / far / close /
              // half face / multiple faces => plain white ring, no scan.
              scanning:
                  _ready &&
                  !_complete &&
                  !_sending &&
                  !_backendWaiting &&
                  _scanAnimation,
              progress: _complete ? 1.0 : progress,
              waiting: _backendWaiting,
              // Sign-up and login share the same fixed-length, one-orbit
              // clockwise green light.
              waitingDuration: _greenAnimation,
              success:
                  _complete &&
                  !_backendWaiting &&
                  !_verificationFailed &&
                  (_enrolling || _loginChallengeAccepted),
              // Red only ever comes from a backend / verification outcome.
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
        // Preserve the APK's 3:4 camera framing. Cover crops the sides/top
        // to fill a 9:16 screen and makes the face appear too close.
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        alignment: const Alignment(0, -0.2), // tune this
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
