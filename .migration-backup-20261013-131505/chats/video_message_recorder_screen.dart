import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class VideoMessageResult {
  final String filePath;
  final int durationSeconds;

  const VideoMessageResult({
    required this.filePath,
    required this.durationSeconds,
  });
}

class VideoMessageRecorderScreen extends StatefulWidget {
  final Duration maxDuration;

  const VideoMessageRecorderScreen({
    super.key,
    this.maxDuration = const Duration(seconds: 60),
  });

  @override
  State<VideoMessageRecorderScreen> createState() =>
      _VideoMessageRecorderScreenState();
}

class _VideoMessageRecorderScreenState
    extends State<VideoMessageRecorderScreen> {
  static const int _videoBitrate = 800000;
  static const int _audioBitrate = 32000;
  static const int _framesPerSecond = 20;

  CameraController? _controller;
  Timer? _timer;
  bool _initialising = true;
  bool _recording = false;
  bool _closing = false;
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialiseAndRecord());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initialiseAndRecord() async {
    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();
    if (!cameraStatus.isGranted || !micStatus.isGranted) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) Navigator.of(context).pop();
        return;
      }

      final camera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.low,
        enableAudio: true,
        fps: _framesPerSecond,
        videoBitrate: _videoBitrate,
        audioBitrate: _audioBitrate,
      );
      await controller.initialize();
      await controller.prepareForVideoRecording();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _initialising = false;
      });
      await _startRecording();
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null || _recording || !controller.value.isInitialized) {
      return;
    }

    await controller.startVideoRecording();
    if (!mounted) return;
    setState(() {
      _recording = true;
      _elapsedSeconds = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final next = _elapsedSeconds + 1;
      setState(() => _elapsedSeconds = next);
      if (next >= widget.maxDuration.inSeconds) {
        unawaited(_finish(save: true));
      }
    });
  }

  Future<void> _finish({required bool save}) async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();

    final controller = _controller;
    XFile? file;
    if (controller != null && controller.value.isRecordingVideo) {
      file = await controller.stopVideoRecording();
    }

    if (!mounted) return;
    if (!save || file == null || _elapsedSeconds < 1) {
      if (file != null) {
        final recorded = File(file.path);
        if (await recorded.exists()) await recorded.delete();
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }

    Navigator.of(context).pop(
      VideoMessageResult(
        filePath: file.path,
        durationSeconds: _elapsedSeconds.clamp(1, widget.maxDuration.inSeconds),
      ),
    );
  }

  String get _timeLabel {
    final minutes = (_elapsedSeconds ~/ 60).toString();
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (!_initialising &&
              controller != null &&
              controller.value.isInitialized)
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: CameraPreview(controller),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => _finish(save: false),
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.circle,
                              color: Colors.redAccent,
                              size: 9,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _timeLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _recording ? () => _finish(save: true) : null,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                      child: const Icon(
                        Icons.stop_rounded,
                        color: Colors.white,
                        size: 36,
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
