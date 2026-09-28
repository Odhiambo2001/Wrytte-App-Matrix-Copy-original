import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:wrytte/data/models/camera_device_record.dart';

import 'package:wrytte/data/services/camera_capabilities_service.dart';

import 'package:wrytte/data/services/camera_diagnostics.dart';

import 'package:wrytte/data/services/camera_session_manager.dart';

import 'package:wrytte/data/services/device_camera_service.dart';

import 'package:wrytte/domain/models/camera_capabilities.dart';

import 'package:wrytte/domain/models/camera_capture_result.dart';

import 'package:wrytte/domain/models/camera_device.dart';

import 'package:wrytte/domain/models/camera_failure.dart';

import 'package:wrytte/domain/models/camera_session_config.dart';

import 'package:wrytte/domain/models/camera_session_state.dart';

import 'package:wrytte/domain/repositories/camera_repository.dart';

class CameraRepositoryImpl implements CameraRepository {

  CameraRepositoryImpl(

    this._deviceService,

    this._capabilitiesService,

    this._sessionManager, [

    this._diagnostics = const CameraDiagnostics(),

  ]);

  final DeviceCameraService _deviceService;

  final CameraCapabilitiesService _capabilitiesService;

  final CameraSessionManager _sessionManager;

  final CameraDiagnostics _diagnostics;

  final _states = StreamController<CameraSessionState>.broadcast(sync: true);

  CameraSessionState _state = const CameraSessionState();

  Map<String, NativeCameraMetadataRecord> _nativeMetadata = const {};

  DateTime? _recordingStartedAt;

  final Stopwatch _recordingStopwatch = Stopwatch();

  double? _pendingZoom;

  Future<void>? _zoomWorker;

  bool _lifecycleInterrupted = false;

  String? _resumeDeviceId;

  double _resumeZoom = 1;

  WrytteFlashMode _resumeFlash = WrytteFlashMode.off;

  double _activeControllerMinimumZoom = 1;

  double _activeControllerMaximumZoom = 1;

  @override

  CameraSessionState get state => _state;

  @override

  Stream<CameraSessionState> get states => _states.stream;

  @override

  Future<void> open(CameraSessionConfig config) async {

    final timer = Stopwatch()..start();

    _diagnostics.event('open_requested', {

      'purpose': config.purpose.name,

      'audio': config.enableAudio,

      'resolution': config.resolution.name,

    });

    if (_state.isReady &&

        _state.config?.isCompatibleWith(config) == true &&

        _deviceService.isReady) {

      _lifecycleInterrupted = false;

      _emit(_state.copyWith(config: config, clearFailure: true));

      return;

    }

    // A route may be opened while its attachment-tile preview is still

    // initializing. Both callers describe the same logical session, so keep

    // the in-flight initialization instead of invalidating it and producing a

    // visible preview restart during the shared-surface transition.

    if (_state.status == CameraSessionStatus.opening &&

        _state.config?.isCompatibleWith(config) == true) {

      return;

    }

    final generation = _sessionManager.invalidate();

    _emit(

      _state.copyWith(

        status: CameraSessionStatus.opening,

        config: config,

        clearFailure: true,

      ),

    );

    await _sessionManager.serialize(() async {

      if (!_sessionManager.isCurrent(generation)) return;

      try {

        final records = await _deviceService.discover();

        _nativeMetadata = await _capabilitiesService.load();

        final devices = records.map(_toDevice).toList(growable: false);

        _diagnostics.event('devices_discovered', {'count': devices.length});

        if (devices.isEmpty) {

          throw const CameraFailure(

            CameraFailureCode.noCamera,

            'No camera is available on this device.',

          );

        }

        final resumedDeviceId = _lifecycleInterrupted ? _resumeDeviceId : null;

        final selected = resumedDeviceId == null

            ? _selectInitialDevice(devices, config)

            : devices.firstWhere(

                (device) => device.id == resumedDeviceId,

                orElse: () => _selectInitialDevice(devices, config),

              );

        _diagnostics.event('device_selected', {

          'id': selected.id,

          'facing': selected.facing.name,

          'lens': selected.lensRole.name,

        });

        await _initializeDevice(

          selected,

          devices: devices,

          config: config,

          generation: generation,

          desiredDisplayZoom: _lifecycleInterrupted ? _resumeZoom : null,

          desiredFlash: _lifecycleInterrupted ? _resumeFlash : null,

        );

        _lifecycleInterrupted = false;

        _diagnostics.event('open_ready', {

          'milliseconds': timer.elapsedMilliseconds,

          'minZoom': _state.capabilities?.minimumZoom,

          'maxZoom': _state.capabilities?.maximumZoom,

        });

      } catch (error) {

        if (_sessionManager.isCurrent(generation)) {

          _emitFailure(_mapFailure(error));

        }

      }

    });

  }

  @override

  Future<void> close() async {

    _diagnostics.event('close_requested');

    _lifecycleInterrupted = false;

    _resumeDeviceId = null;

    _pendingZoom = null;
    _recordingStopwatch
      ..stop()
      ..reset();

    final generation = _sessionManager.invalidate();

    _emit(_state.copyWith(status: CameraSessionStatus.closed));

    await _sessionManager.serialize(() async {

      await _deviceService.dispose();

      if (_sessionManager.isCurrent(generation)) {

        _emit(const CameraSessionState());

      }

    });

  }

  @override

  Future<void> interrupt() async {

    if (_state.status == CameraSessionStatus.closed ||

        _state.status == CameraSessionStatus.interrupted) {

      return;

    }

    _lifecycleInterrupted = true;

    _diagnostics.event('lifecycle_interrupted');

    _resumeDeviceId = _state.activeDevice?.id;

    _resumeZoom = _state.zoom;

    _resumeFlash = _state.flashMode;

    final wasRecording = _state.isRecording;
    _recordingStopwatch
      ..stop()
      ..reset();

    final generation = _sessionManager.invalidate();

    _emit(_state.copyWith(status: CameraSessionStatus.interrupted));

    await _sessionManager.serialize(() async {

      if (wasRecording) {

        try {

          await _deviceService.stopVideo();

        } catch (_) {

          // Background recording is not supported; discard partial output.

        }

      }

      await _deviceService.dispose();

      if (_sessionManager.isCurrent(generation)) {

        _emit(_state.copyWith(status: CameraSessionStatus.interrupted));

      }

    });

  }

  @override

  Future<void> resume() async {

    if (!_lifecycleInterrupted) return;

    final config = _state.config;

    if (config == null) return;

    _diagnostics.event('lifecycle_resume');

    await open(config);

  }

  @override

  Future<void> switchCamera() async {
    if (!_canAdjustCamera || _state.activeDevice == null) return;

    final current = _state.activeDevice!;
    final desiredFacing =
        current.isFront ? CameraFacing.back : CameraFacing.front;
    final candidates = _state.devices
        .where((device) => device.facing == desiredFacing)
        .toList();

    if (candidates.isEmpty) return;

    final target = _preferredWide(candidates);

    if (_state.status == CameraSessionStatus.recording ||
        _state.status == CameraSessionStatus.recordingPaused) {
      await _switchActiveCameraWhileRecording(target);
      return;
    }

    await _replaceActiveDevice(target);
  }

  @override

  Future<CameraCaptureResult> takePhoto() async {

    _ensureReady();

    final generation = _sessionManager.generation;

    _emit(_state.copyWith(status: CameraSessionStatus.capturing));

    try {

      final path = await _sessionManager.serialize(_deviceService.takePhoto);

      if (!_sessionManager.isCurrent(generation)) {

        throw const CameraFailure(

          CameraFailureCode.interrupted,

          'Photo capture was interrupted.',

        );

      }

      final result = CameraCaptureResult(

        path: path,

        type: CameraMediaType.photo,

        capturedAt: DateTime.now(),

        cameraId: _state.activeDevice!.id,

        zoom: _state.zoom,

      );

      _emit(_state.copyWith(status: CameraSessionStatus.ready));

      return result;

    } catch (error) {

      final failure = _mapFailure(error);

      if (_sessionManager.isCurrent(generation)) _emitFailure(failure);

      throw failure;

    }

  }

  @override

  Future<void> startVideo() async {

    _ensureReady();

    if (_state.config?.supportsVideo != true) return;

    final generation = _sessionManager.generation;

    _emit(_state.copyWith(status: CameraSessionStatus.recordingStarting));

    try {

      await _sessionManager.serialize(_deviceService.startVideo);

      if (!_sessionManager.isCurrent(generation)) return;

      _recordingStartedAt = DateTime.now();
      _recordingStopwatch
        ..reset()
        ..start();

      _emit(_state.copyWith(status: CameraSessionStatus.recording));

    } catch (error) {

      final failure = _mapFailure(error);

      if (_sessionManager.isCurrent(generation)) _emitFailure(failure);

      throw failure;

    }

  }

  @override

  Future<CameraCaptureResult> stopVideo() async {

    if (!_state.isRecording) {

      throw const CameraFailure(

        CameraFailureCode.captureFailed,

        'No video recording is active.',

      );

    }

    final generation = _sessionManager.generation;

    _emit(_state.copyWith(status: CameraSessionStatus.recordingStopping));

    try {

      final path = await _sessionManager.serialize(_deviceService.stopVideo);

      if (!_sessionManager.isCurrent(generation)) {

        throw const CameraFailure(

          CameraFailureCode.interrupted,

          'Video capture was interrupted.',

        );

      }

      final startedAt = _recordingStartedAt;
      _recordingStartedAt = null;

      _recordingStopwatch.stop();
      final activeDuration = _recordingStopwatch.elapsed;
      _recordingStopwatch.reset();

      final result = CameraCaptureResult(
        path: path,
        type: CameraMediaType.video,
        capturedAt: DateTime.now(),
        cameraId: _state.activeDevice!.id,
        zoom: _state.zoom,
        duration: activeDuration > Duration.zero
            ? activeDuration
            : startedAt == null
            ? null
            : DateTime.now().difference(startedAt),
      );

      _emit(_state.copyWith(status: CameraSessionStatus.ready));

      return result;

    } catch (error) {
      _recordingStopwatch
        ..stop()
        ..reset();

      final failure = _mapFailure(error);

      if (_sessionManager.isCurrent(generation)) _emitFailure(failure);

      throw failure;
    }

  }

  @override

  Future<void> pauseVideo() async {
    if (_state.status != CameraSessionStatus.recording) return;

    await _deviceService.pauseVideo();
    _recordingStopwatch.stop();

    _emit(_state.copyWith(status: CameraSessionStatus.recordingPaused));
  }

  @override

  Future<void> resumeVideo() async {
    if (_state.status != CameraSessionStatus.recordingPaused) return;

    await _deviceService.resumeVideo();
    _recordingStopwatch.start();

    _emit(_state.copyWith(status: CameraSessionStatus.recording));
  }

  @override

  Future<void> setZoom(double zoom) {
    final capabilities = _state.capabilities;
    if (!_canAdjustCamera || capabilities == null) {
      return Future<void>.value();
    }

    _pendingZoom = zoom.clamp(
      capabilities.minimumZoom,
      capabilities.maximumZoom,
    ).toDouble();

    return _zoomWorker ??= _applyLatestZoom();
  }

  Future<void> _applyLatestZoom() async {
    try {
      while (_pendingZoom != null && _canAdjustCamera) {
        final requested = _pendingZoom!;
        _pendingZoom = null;

        final active = _state.activeDevice;
        if (active == null) return;

        // Switching physical devices through dispose/reinitialize would destroy
        // an active recording. During recording, stay on the current controller
        // and use its supported zoom range only.
        final canReplaceDevice = _state.status == CameraSessionStatus.ready;
        final alternate = canReplaceDevice && !active.isLogicalCamera
            ? _findLensForDisplayZoom(requested)
            : null;

        if (alternate != null && alternate.id != active.id) {
          await _replaceActiveDevice(
            alternate,
            desiredDisplayZoom: requested,
          );
          continue;
        }

        final deviceZoom = requested / active.intrinsicZoomRatio;
        await _deviceService.setZoom(
          deviceZoom
              .clamp(
                _activeControllerMinimumZoom,
                _activeControllerMaximumZoom,
              )
              .toDouble(),
        );

        _emit(_state.copyWith(zoom: requested));
      }
    } catch (error) {
      final recording =
          _state.status == CameraSessionStatus.recording ||
          _state.status == CameraSessionStatus.recordingPaused;

      if (recording) {
        _diagnostics.event('recording_zoom_failed', {
          'error': error.toString(),
        });
      } else {
        _emitFailure(_mapFailure(error));
      }
    } finally {
      _zoomWorker = null;
      if (_pendingZoom != null && _canAdjustCamera) {
        _zoomWorker = _applyLatestZoom();
      }
    }
  }

  @override

  Future<void> setFocusAndExposurePoint(double x, double y) async {

    if (!_state.isReady) return;

    try {

      await _deviceService.setFocusAndExposurePoint(x, y);

    } catch (_) {

      // Tap-to-focus is an optional capability and must not close the session.

    }

  }

  @override

  Future<void> cycleFlashMode() async {
    if (!_canAdjustCamera || _state.capabilities?.flashAvailable != true) return;

    final recording =
        _state.status == CameraSessionStatus.recording ||
        _state.status == CameraSessionStatus.recordingPaused;

    final next = recording
        ? (_state.flashMode == WrytteFlashMode.torch
              ? WrytteFlashMode.off
              : WrytteFlashMode.torch)
        : switch (_state.flashMode) {
            WrytteFlashMode.off => WrytteFlashMode.auto,
            WrytteFlashMode.auto => WrytteFlashMode.always,
            WrytteFlashMode.always || WrytteFlashMode.torch =>
              WrytteFlashMode.off,
          };

    try {
      await _deviceService.setFlashMode(next);
      _emit(_state.copyWith(flashMode: next));
    } catch (_) {
      // Some vendors report flash support but reject individual modes.
    }
  }

  @override

  Future<void> pausePreview() async {

    if (!_state.isReady) return;

    await _sessionManager.serialize(_deviceService.pausePreview);

  }

  @override

  Future<void> resumePreview() async {

    if (!_state.isReady) return;

    await _sessionManager.serialize(_deviceService.resumePreview);

  }

  @override

  Widget buildPreview({Key? key}) => _deviceService.buildPreview(key: key);

  bool get _canAdjustCamera {
    return _state.status == CameraSessionStatus.ready ||
        _state.status == CameraSessionStatus.recording ||
        _state.status == CameraSessionStatus.recordingPaused;
  }

  Future<void> _switchActiveCameraWhileRecording(CameraDevice target) async {
    final previousStatus = _state.status;
    final config = _state.config;
    if (config == null) return;

    try {
      if (_state.flashMode != WrytteFlashMode.off) {
        try {
          await _deviceService.setFlashMode(WrytteFlashMode.off);
        } catch (_) {
          // The old lens may not expose a flash control.
        }
      }

      final record = await _sessionManager.serialize(
        () => _deviceService.switchCamera(target.id),
      );

      _activeControllerMinimumZoom = record.minimumZoom;
      _activeControllerMaximumZoom = record.maximumZoom;

      final capabilities = _capabilitiesFor(
        device: target,
        devices: _state.devices,
        record: record,
      );

      double displayZoom = math.max(1.0, capabilities.minimumZoom);
      displayZoom = displayZoom
          .clamp(
            capabilities.minimumZoom,
            capabilities.maximumZoom,
          )
          .toDouble();

      final controllerZoom = (displayZoom / target.intrinsicZoomRatio)
          .clamp(
            record.minimumZoom,
            record.maximumZoom,
          )
          .toDouble();

      await _deviceService.setZoom(controllerZoom);

      _emit(
        CameraSessionState(
          status: previousStatus,
          devices: _state.devices,
          activeDevice: target,
          capabilities: capabilities,
          config: config,
          zoom: displayZoom,
          flashMode: WrytteFlashMode.off,
          previewAspectRatio: record.previewAspectRatio,
        ),
      );
    } catch (error) {
      _diagnostics.event('switch_while_recording_failed', {
        'error': error.toString(),
      });
      // Camera switching is an optional control. A failed switch must not move
      // an otherwise healthy active recording into the global failure state.
    }
  }

  CameraCapabilities _capabilitiesFor({
    required CameraDevice device,
    required List<CameraDevice> devices,
    required DeviceCameraCapabilitiesRecord record,
  }) {
    final native = _nativeMetadata[device.id];
    final displayMinimum = math.min(
      record.minimumZoom * device.intrinsicZoomRatio,
      devices
          .where((candidate) => candidate.facing == device.facing)
          .map((candidate) => candidate.intrinsicZoomRatio)
          .fold<double>(double.infinity, math.min),
    );

    return CameraCapabilities(
      minimumZoom: displayMinimum.isFinite
          ? displayMinimum
          : record.minimumZoom,
      maximumZoom: math.max(
        record.maximumZoom * device.intrinsicZoomRatio,
        device.intrinsicZoomRatio,
      ),
      minimumExposureOffset: record.minimumExposureOffset,
      maximumExposureOffset: record.maximumExposureOffset,
      exposureOffsetStep: record.exposureOffsetStep,
      focusPointSupported: record.focusPointSupported,
      exposurePointSupported: record.exposurePointSupported,
      imageStreamingSupported: record.imageStreamingSupported,
      flashAvailable: native?.flashAvailable ?? false,
      stabilizationModes: record.stabilizationModes.map(_stabilization).toSet(),
    );
  }

  Future<void> _replaceActiveDevice(

    CameraDevice target, {

    double? desiredDisplayZoom,

  }) async {

    final config = _state.config;

    if (config == null) return;

    final generation = _sessionManager.invalidate();

    _emit(_state.copyWith(status: CameraSessionStatus.opening));

    await _sessionManager.serialize(() async {

      try {

        await _initializeDevice(

          target,

          devices: _state.devices,

          config: config,

          generation: generation,

          desiredDisplayZoom: desiredDisplayZoom,

        );

      } catch (error) {

        if (_sessionManager.isCurrent(generation)) {

          _emitFailure(_mapFailure(error));

        }

      }

    });

  }

  Future<void> _initializeDevice(

    CameraDevice device, {

    required List<CameraDevice> devices,

    required CameraSessionConfig config,

    required int generation,

    double? desiredDisplayZoom,

    WrytteFlashMode? desiredFlash,

  }) async {

    final record = await _deviceService.initialize(

      cameraId: device.id,

      config: config,

    );

    if (!_sessionManager.isCurrent(generation)) {

      await _deviceService.dispose();

      return;

    }

    _activeControllerMinimumZoom = record.minimumZoom;
    _activeControllerMaximumZoom = record.maximumZoom;

    final capabilities = _capabilitiesFor(
      device: device,
      devices: devices,
      record: record,
    );

    double displayZoom =

        desiredDisplayZoom ?? math.max(1.0, capabilities.minimumZoom);

    displayZoom = displayZoom
        .clamp(

          capabilities.minimumZoom,

          capabilities.maximumZoom,

        )
        .toDouble();

    final controllerZoom = (displayZoom / device.intrinsicZoomRatio)
        .clamp(

          record.minimumZoom,

          record.maximumZoom,

        )
        .toDouble();

    if ((controllerZoom - 1).abs() > .01) {

      await _deviceService.setZoom(controllerZoom);

    }

    var restoredFlash = WrytteFlashMode.off;

    if (desiredFlash != null &&

        desiredFlash != WrytteFlashMode.off &&

        capabilities.flashAvailable) {

      try {

        await _deviceService.setFlashMode(desiredFlash);

        restoredFlash = desiredFlash;

      } catch (_) {

        restoredFlash = WrytteFlashMode.off;

      }

    }

    _emit(

      CameraSessionState(

        status: CameraSessionStatus.ready,

        devices: devices,

        activeDevice: device,

        capabilities: capabilities,

        config: config,

        zoom: displayZoom,

        flashMode: restoredFlash,

        previewAspectRatio: record.previewAspectRatio,

      ),

    );

  }

  CameraDevice? _findLensForDisplayZoom(double zoom) {

    final active = _state.activeDevice;

    if (active == null) return null;

    final candidates =

        _state.devices

            .where((device) => device.facing == active.facing)

            .toList()

          ..sort(

            (a, b) => a.intrinsicZoomRatio.compareTo(b.intrinsicZoomRatio),

          );

    CameraDevice? result;

    for (final candidate in candidates) {

      if (candidate.intrinsicZoomRatio <= zoom + .02) result = candidate;

    }

    return result ?? candidates.firstOrNull;

  }

  CameraDevice _selectInitialDevice(

    List<CameraDevice> devices,

    CameraSessionConfig config,

  ) {

    final facing = config.preferredFacing == CameraFacingPreference.front

        ? CameraFacing.front

        : CameraFacing.back;

    final matching = devices

        .where((device) => device.facing == facing)

        .toList();

    return _preferredWide(matching.isEmpty ? devices : matching);

  }

  CameraDevice _preferredWide(List<CameraDevice> devices) {

    return devices.firstWhere(

      (device) => device.lensRole == CameraLensRole.wide,

      orElse: () => devices.reduce(

        (a, b) =>

            (a.intrinsicZoomRatio - 1).abs() <= (b.intrinsicZoomRatio - 1).abs()

            ? a

            : b,

      ),

    );

  }

  CameraDevice _toDevice(CameraDeviceRecord record) {

    final native = _nativeMetadata[record.id];

    return CameraDevice(

      id: record.id,

      facing: switch (record.lensDirection) {

        'front' => CameraFacing.front,

        'external' => CameraFacing.external,

        _ => CameraFacing.back,

      },

      sensorOrientation: record.sensorOrientation,

      lensRole: switch (record.lensType) {

        'ultraWide' => CameraLensRole.ultraWide,

        'telephoto' => CameraLensRole.telephoto,

        'wide' => CameraLensRole.wide,

        _ when record.lensDirection == 'front' => CameraLensRole.front,

        _ => CameraLensRole.unknown,

      },

      intrinsicZoomRatio:

          native?.intrinsicZoomRatio ??

          switch (record.lensType) {

            'ultraWide' => .5,

            'telephoto' => 2,

            _ => 1,

          },

      isLogicalCamera: native?.logicalMultiCamera ?? false,

      physicalCameraIds: native?.physicalCameraIds ?? const [],

    );

  }

  static WrytteVideoStabilization _stabilization(String value) =>

      switch (value) {

        'level2' || 'level3' => WrytteVideoStabilization.cinematic,

        'level1' => WrytteVideoStabilization.standard,

        _ => WrytteVideoStabilization.off,

      };

  void _ensureReady() {

    if (!_state.isReady || !_deviceService.isReady) {

      throw const CameraFailure(

        CameraFailureCode.unavailable,

        'The camera is not ready yet.',

      );

    }

  }

  void _emit(CameraSessionState value) {

    _state = value;

    if (!_states.isClosed) _states.add(value);

  }

  void _emitFailure(CameraFailure failure) {

    _diagnostics.event('failure', {

      'code': failure.code.name,

      'message': failure.message,

    });

    _emit(

      _state.copyWith(status: CameraSessionStatus.failure, failure: failure),

    );

  }

  static CameraFailure _mapFailure(Object error) {

    if (error is CameraFailure) return error;

    if (error is DeviceCameraException) {

      final normalized = error.code.toLowerCase();

      final code =

          normalized.contains('deniedwithoutprompt') ||

              normalized.contains('permanently')

          ? CameraFailureCode.permissionPermanentlyDenied

          : normalized.contains('denied')

          ? CameraFailureCode.permissionDenied

          : normalized.contains('not_found')

          ? CameraFailureCode.noCamera

          : normalized.contains('interrupted') ||

                normalized.contains('disposed')

          ? CameraFailureCode.interrupted

          : normalized.contains('capture')

          ? CameraFailureCode.captureFailed

          : CameraFailureCode.unavailable;

      return CameraFailure(code, error.description, cause: error.cause);

    }

    return CameraFailure(

      CameraFailureCode.unknown,

      'The camera could not be started.',

      cause: error,

    );

  }

}