import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/face/camera_frame_converter.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

class KFaceScanPage extends StatefulWidget {
  const KFaceScanPage({super.key, required this.wrytteId});

  final String wrytteId;

  @override
  State<KFaceScanPage> createState() => _KFaceScanPageState();
}

class _KFaceScanPageState extends State<KFaceScanPage>
    with WidgetsBindingObserver {
  final RetinaFaceDetector _detector = RetinaFaceDetector();
  CameraController? _camera;
  bool _initializing = true;
  bool _processingFrame = false;
  bool _completed = false;
  double _progress = 0;
  String _instruction = 'Preparing face scanner…';
  DateTime _lastInference = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _detector.initialize();
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera is available.');
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        description,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup:
            Platform.isIOS
                ? ImageFormatGroup.bgra8888
                : ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _camera = controller;
      await controller.startImageStream(_processFrame);
      setState(() {
        _initializing = false;
        _instruction = 'Position your face inside the oval';
      });
    } on CameraException catch (error) {
      _showError(
        error.code == 'CameraAccessDenied'
            ? 'Camera permission is required for face scanning.'
            : 'Could not start the camera: ${error.description ?? error.code}',
      );
    } catch (error) {
      _showError('Could not start face scanning: $error');
    }
  }

  Future<void> _processFrame(CameraImage frame) async {
    final camera = _camera;
    if (camera == null || _processingFrame || _completed) return;
    final now = DateTime.now();
    if (now.difference(_lastInference) < const Duration(milliseconds: 300)) {
      return;
    }
    _lastInference = now;
    _processingFrame = true;
    try {
      final image = CameraFrameConverter.convert(
        frame,
        sensorOrientation: camera.description.sensorOrientation,
      );
      final faces = await _detector.detect(image);
      if (!mounted) return;
      _updateScan(faces, image.width, image.height);
    } catch (error) {
      if (mounted) {
        setState(() => _instruction = 'Face detection failed. Try again.');
      }
    } finally {
      _processingFrame = false;
    }
  }

  void _updateScan(List<FaceDetection> faces, int width, int height) {
    var instruction = 'Hold still and look at the camera';
    var valid = false;
    if (faces.isEmpty) {
      instruction = 'No face detected';
    } else if (faces.length > 1) {
      instruction = 'Only one person should be visible';
    } else {
      final face = faces.single;
      final widthRatio = face.width / width;
      final centered =
          (face.centerX / width - 0.5).abs() < 0.18 &&
          (face.centerY / height - 0.5).abs() < 0.22;
      if (widthRatio < 0.30) {
        instruction = 'Move closer';
      } else if (widthRatio > 0.78) {
        instruction = 'Move farther away';
      } else if (!centered) {
        instruction = 'Center your face in the oval';
      } else {
        valid = true;
      }
    }

    final nextProgress =
        valid
            ? (_progress + 0.12).clamp(0.0, 1.0)
            : (_progress - 0.08).clamp(0.0, 1.0);
    setState(() {
      _progress = nextProgress;
      _instruction = instruction;
      if (_progress >= 1) {
        _completed = true;
        _instruction = 'Face detected';
      }
    });
    if (_completed) unawaited(_camera?.stopImageStream());
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _initializing = false;
      _instruction = message;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_camera?.stopImageStream());
    } else if (state == AppLifecycleState.resumed &&
        !_completed &&
        _camera?.value.isInitialized == true &&
        _camera?.value.isStreamingImages == false) {
      unawaited(_camera?.startImageStream(_processFrame));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final camera = _camera;
    _camera = null;
    unawaited(camera?.dispose());
    unawaited(_detector.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (camera != null && camera.value.isInitialized)
            Center(
              child: Transform.scale(scaleX: -1, child: CameraPreview(camera)),
            )
          else
            const ColoredBox(color: Color(0xFF08090B)),
          const _CameraShade(),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
                const Spacer(),
                SizedBox.square(
                  dimension: 270,
                  child: CircularProgressIndicator(
                    value: _initializing ? null : _progress,
                    strokeWidth: 7,
                    backgroundColor: Colors.white24,
                    color:
                        _completed
                            ? const Color(0xFF59C787)
                            : const Color(0xFF4285DF),
                  ),
                ),
                const Spacer(),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 30),
                  color: const Color(0xCC08090B),
                  child: Column(
                    children: [
                      Text(
                        _instruction,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _completed
                            ? 'RetinaFace found a stable, centered face.'
                            : 'Keep your whole face visible in good lighting.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFB0B3BC),
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraShade extends StatelessWidget {
  const _CameraShade();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(child: CustomPaint(painter: _CameraShadePainter()));
  }
}

class _CameraShadePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final oval = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.45),
      width: 250,
      height: 330,
    );
    final path =
        Path()
          ..addRect(Offset.zero & size)
          ..addOval(oval)
          ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = const Color(0x66000000));
    canvas.drawOval(
      oval,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
