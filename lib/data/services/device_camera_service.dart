import 'package:camera/camera.dart';

import 'package:flutter/services.dart';

import 'package:flutter/widgets.dart';

import 'package:wrytte/data/models/camera_device_record.dart';

import 'package:wrytte/domain/models/camera_capabilities.dart';

import 'package:wrytte/domain/models/camera_session_config.dart';

/// The only Wrytte class that imports the camera plugin.

///

/// Plugin values never escape this adapter. This keeps controller ownership in

/// one place and makes route transitions independent of camera initialization.

class DeviceCameraService {

  List<CameraDescription>? _descriptions;

  CameraController? _controller;

  String? _activeId;

  CameraSessionConfig? _activeConfig;

  bool get isReady => _controller?.value.isInitialized ?? false;

  String? get activeId => _activeId;

  Future<List<CameraDeviceRecord>> discover() async {

    try {

      final descriptions = _descriptions ??= await availableCameras();

      return descriptions.map(_toRecord).toList(growable: false);

    } on CameraException catch (error) {

      throw DeviceCameraException(error.code, error.description ?? error.code);

    } catch (error) {

      throw DeviceCameraException('camera_unavailable', '$error', error);

    }

  }

  Future<DeviceCameraCapabilitiesRecord> initialize({

    required String cameraId,

    required CameraSessionConfig config,

  }) async {

    await dispose();

    try {

      final descriptions = _descriptions ??= await availableCameras();

      final description = descriptions.firstWhere(

        (camera) => camera.name == cameraId,

        orElse: () => throw const DeviceCameraException(

          'camera_not_found',

          'The selected camera is no longer available.',

        ),

      );

      final controller = CameraController(

        description,

        _resolution(config.resolution),

        enableAudio: config.enableAudio,

        fps: config.framesPerSecond,

        videoBitrate: config.videoBitrate,

        audioBitrate: config.audioBitrate,

      );

      _controller = controller;

      _activeId = cameraId;

      _activeConfig = config;

      await controller.initialize();

      if (!identical(_controller, controller)) {

        await controller.dispose();

        throw const DeviceCameraException(

          'camera_interrupted',

          'Camera initialization was superseded.',

        );

      }

      if (config.supportsVideo) {

        await _ignoreUnsupported(controller.prepareForVideoRecording);

      }

      final capabilities = await _readCapabilities(controller);

      return capabilities;

    } on DeviceCameraException {

      rethrow;

    } on CameraException catch (error) {

      await dispose();

      throw DeviceCameraException(error.code, error.description ?? error.code);

    } catch (error) {

      await dispose();

      throw DeviceCameraException('camera_initialize_failed', '$error', error);

    }

  }

  Widget buildPreview({Key? key}) {

    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {

      return SizedBox(key: key);

    }

    return ColoredBox(

      key: key,

      color: const Color(0xFF050608),

      child: ValueListenableBuilder<CameraValue>(

        valueListenable: controller,

        builder: (context, value, _) {

          if (!value.isInitialized) return const SizedBox.expand();

          final aspect = _orientedPreviewAspect(value);

          const baseExtent = 1000.0;

          final width = aspect >= 1 ? baseExtent * aspect : baseExtent;

          final height = aspect >= 1 ? baseExtent : baseExtent / aspect;

          return ClipRect(

            child: FittedBox(

              fit: BoxFit.cover,

              clipBehavior: Clip.hardEdge,

              child: SizedBox(

                width: width,

                height: height,

                child: controller.buildPreview(),

              ),

            ),

          );

        },

      ),

    );

  }

  Future<String> takePhoto() async =>

      _cameraCall(() async => (await _requireController().takePicture()).path);

  Future<void> startVideo() async => _cameraCall(() async {
    final controller = _requireController();

    // Round-video messages are portrait UI. Keep capture orientation stable
    // even if the user tilts the phone during the recording gesture.
    await _ignoreUnsupported(
      () => controller.lockCaptureOrientation(DeviceOrientation.portraitUp),
    );

    // Persistent recording is important on Android: it lets CameraController
    // change camera descriptions without silently cancelling the active file.
    await controller.startVideoRecording(enablePersistentRecording: true);
  });

  Future<String> stopVideo() async => _cameraCall(

    () async => (await _requireController().stopVideoRecording()).path,

  );

  Future<void> pauseVideo() async =>

      _cameraCall(() => _requireController().pauseVideoRecording());

  Future<void> resumeVideo() async =>

      _cameraCall(() => _requireController().resumeVideoRecording());

  Future<DeviceCameraCapabilitiesRecord> switchCamera(String cameraId) async {
    return _cameraCall(() async {
      final controller = _requireController();
      final descriptions = _descriptions ??= await availableCameras();
      final description = descriptions.firstWhere(
        (camera) => camera.name == cameraId,
        orElse: () => throw const DeviceCameraException(
          'camera_not_found',
          'The selected camera is no longer available.',
        ),
      );

      if (description.name != controller.description.name) {
        await controller.setDescription(description);
      }

      _activeId = description.name;

      final config = _activeConfig;
      if (config != null &&
          config.supportsVideo &&
          !controller.value.isRecordingVideo) {
        await _ignoreUnsupported(controller.prepareForVideoRecording);
      }

      return _readCapabilities(controller);
    });
  }

  Future<void> setZoom(double zoom) async =>

      _cameraCall(() => _requireController().setZoomLevel(zoom));

  Future<void> setFocusAndExposurePoint(double x, double y) async {

    final controller = _requireController();

    final point = Offset(
      x.clamp(0.0, 1.0).toDouble(),
      y.clamp(0.0, 1.0).toDouble(),
    );

    if (controller.value.focusPointSupported) {

      await _cameraCall(() => controller.setFocusPoint(point));

    }

    if (controller.value.exposurePointSupported) {

      await _cameraCall(() => controller.setExposurePoint(point));

    }

  }

  Future<void> setFlashMode(WrytteFlashMode mode) async => _cameraCall(

    () => _requireController().setFlashMode(switch (mode) {

      WrytteFlashMode.off => FlashMode.off,

      WrytteFlashMode.auto => FlashMode.auto,

      WrytteFlashMode.always => FlashMode.always,

      WrytteFlashMode.torch => FlashMode.torch,

    }),

  );

  Future<void> pausePreview() async {

    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) return;

    await _cameraCall(controller.pausePreview);

  }

  Future<void> resumePreview() async {

    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) return;

    await _cameraCall(controller.resumePreview);

  }

  Future<void> dispose() async {

    final controller = _controller;

    _controller = null;

    _activeId = null;

    _activeConfig = null;

    if (controller != null) {

      try {

        await controller.dispose();

      } catch (_) {

        // Disposal is best effort and CameraController.dispose is idempotent.

      }

    }

  }

  CameraController _requireController() {

    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {

      throw const DeviceCameraException(

        'camera_not_initialized',

        'The camera is not ready yet.',

      );

    }

    return controller;

  }

  Future<T> _cameraCall<T>(Future<T> Function() action) async {

    try {

      return await action();

    } on CameraException catch (error) {

      throw DeviceCameraException(error.code, error.description ?? error.code);

    } catch (error) {

      if (error is DeviceCameraException) rethrow;

      throw DeviceCameraException('camera_operation_failed', '$error', error);

    }

  }

  static CameraDeviceRecord _toRecord(CameraDescription description) =>

      CameraDeviceRecord(

        id: description.name,

        lensDirection: description.lensDirection.name,

        sensorOrientation: description.sensorOrientation,

        lensType: description.lensType.name,

      );

  static ResolutionPreset _resolution(CameraResolution resolution) =>

      switch (resolution) {

        CameraResolution.medium => ResolutionPreset.medium,

        CameraResolution.high => ResolutionPreset.high,

        CameraResolution.veryHigh => ResolutionPreset.veryHigh,

      };

  static double _orientedPreviewAspect(CameraValue value) {

    final raw = value.aspectRatio;

    if (!raw.isFinite || raw <= 0) return 1;

    final orientation = value.isRecordingVideo

        ? value.recordingOrientation ??

              value.lockedCaptureOrientation ??

              value.deviceOrientation

        : value.previewPauseOrientation ??

              value.lockedCaptureOrientation ??

              value.deviceOrientation;

    final landscape =

        orientation == DeviceOrientation.landscapeLeft ||

        orientation == DeviceOrientation.landscapeRight;

    return landscape ? raw : 1 / raw;

  }

  static Future<DeviceCameraCapabilitiesRecord> _readCapabilities(
    CameraController controller,
  ) async {
    final minZoom = await _readDouble(controller.getMinZoomLevel, 1);
    final maxZoom = await _readDouble(controller.getMaxZoomLevel, minZoom);
    final minExposure = await _readDouble(controller.getMinExposureOffset, 0);
    final maxExposure = await _readDouble(controller.getMaxExposureOffset, 0);
    final exposureStep = await _readDouble(
      controller.getExposureOffsetStepSize,
      0,
    );
    final stabilization = await _readStabilization();
    final value = controller.value;

    return DeviceCameraCapabilitiesRecord(
      minimumZoom: minZoom,
      maximumZoom: maxZoom < minZoom ? minZoom : maxZoom,
      minimumExposureOffset: minExposure,
      maximumExposureOffset: maxExposure,
      exposureOffsetStep: exposureStep,
      focusPointSupported: value.focusPointSupported,
      exposurePointSupported: value.exposurePointSupported,
      imageStreamingSupported: controller.supportsImageStreaming(),
      stabilizationModes: stabilization,
      previewAspectRatio: _orientedPreviewAspect(value),
    );
  }

  static Future<double> _readDouble(

    Future<double> Function() reader,

    double fallback,

  ) async {

    try {

      return await reader();

    } catch (_) {

      return fallback;

    }

  }

  static Future<Set<String>> _readStabilization() async => const {'off'};

  static Future<void> _ignoreUnsupported(Future<void> Function() call) async {

    try {

      await call();

    } catch (_) {

      // This optional quality hint is not implemented by every platform.

    }

  }

}
