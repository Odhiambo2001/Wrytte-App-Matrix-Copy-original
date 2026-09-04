import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/face/biometric_api_service.dart';
import 'package:wrytte/services/face/camera_frame_converter.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
import 'package:wrytte/ui/auth/kface_access_result_page.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

/// Server-biometric scanner. Existing Wrytte-ID users are treated as needing
/// enrolment again: no local face commitment is read or retained.
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
  final _pipeline = FaceBiometricPipeline();
  CameraController? _camera;
  bool _ready = false;
  bool _sending = false;
  bool _complete = false;
  DateTime? _lastFrame;
  String _status = 'Center your face inside the ring.';

  bool get _enrolling => widget.isEnrollment;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      if (!(await Permission.camera.request()).isGranted)
        throw Exception('Camera permission is required.');
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
      if (mounted)
        setState(() => _status = 'Unable to start the face scanner.');
    }
  }

  Future<void> _onFrame(CameraImage frame) async {
    if (!_ready || _sending || _complete) return;
    final now = DateTime.now();
    if (_lastFrame != null &&
        now.difference(_lastFrame!) < const Duration(milliseconds: 100))
      return;
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
      if (!analysis.faceDetected) {
        setState(() => _status = 'No face detected.');
      } else if (!analysis.targetFaceSelected) {
        setState(() => _status = 'Keep one whole face centered in the ring.');
      } else if (!analysis.alignmentAccepted) {
        setState(() => _status = 'Hold still and look at the camera.');
      } else {
        setState(
          () =>
              _status =
                  'Capturing ${analysis.acceptedFrameCount} of ${FaceBiometricPipeline.framesToUse}…',
        );
      }
      if (analysis.acceptedFrameCount == FaceBiometricPipeline.framesToUse) {
        _complete = true;
        unawaited(_submit());
      }
    } catch (_) {
      // Frames are disposable; an invalid transient camera frame is ignored.
    }
  }

  Future<void> _submit() async {
    _sending = true;
    final camera = _camera;
    if (camera?.value.isStreamingImages == true)
      await camera!.stopImageStream();
    if (mounted) setState(() => _status = 'Verifying securely…');
    try {
      if (_enrolling) {
        final current = await AuthService.instance.getCurrentUser();
        final accepted =
            current?.token.isNotEmpty == true &&
            await BiometricApiService.enroll(
              token: current!.token,
              captures: _pipeline.cropSets,
            );
        if (!accepted) throw Exception();
        if (!mounted) return;
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => AddProfilePage(isNewUser: true),
          ),
        );
      } else {
        final response = await BiometricApiService.verify(
          wrytteId: widget.wrytteId,
          captures: _pipeline.cropSets,
        );
        final accepted = response['token']?.toString().isNotEmpty == true;
        if (accepted)
          await AuthService.instance.completeServerBiometricSignIn(
            response,
            wrytteId: widget.wrytteId,
          );
        if (!mounted) return;
        if (!accepted) {
          await _showResult(false);
          return;
        }
        final user = await AuthService.instance.getCurrentUser();
        if (!mounted) return;
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
    } catch (_) {
      if (mounted) await _showResult(false);
    } finally {
      _sending = false;
    }
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

  @override
  void dispose() {
    unawaited(_camera?.dispose());
    unawaited(_pipeline.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        _pipeline.acceptedFrameCount / FaceBiometricPipeline.framesToUse;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_camera != null && _camera!.value.isInitialized)
            Positioned.fill(child: CameraPreview(_camera!)),
          Center(
            child: Container(
              width: 270,
              height: 270,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      Color.lerp(Colors.white, Colors.greenAccent, progress)!,
                  width: 5,
                ),
              ),
            ),
          ),
          SafeArea(
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              color: Colors.black87,
              width: double.infinity,
              padding: const EdgeInsets.all(28),
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
                  const SizedBox(height: 10),
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: progress, minHeight: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
