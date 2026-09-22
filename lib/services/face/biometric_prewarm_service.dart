import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/face/android_tflite_image_session.dart';
import 'package:wrytte/services/face/biometric_api_service.dart';
import 'package:wrytte/services/face/isolate_face_pipeline.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

class BiometricPrewarmBundle {
  BiometricPrewarmBundle({
    required this.pipeline,
    required this.pipelineWarmup,
    required this.nativeWarmup,
    required this.captureSession,
  });

  final IsolateFacePipeline pipeline;
  final Future<void> pipelineWarmup;
  final Future<void> nativeWarmup;
  final Future<String?> captureSession;
}

class BiometricPrewarmService {
  BiometricPrewarmService._();

  static IsolateFacePipeline? _pipeline;
  static Future<void>? _pipelineWarmup;
  static Future<void>? _nativeWarmup;
  static Future<String?>? _captureSession;
  static _CaptureSessionKey? _captureSessionKey;

  static BiometricPrewarmBundle prewarm({
    required String wrytteId,
    required String? userId,
    required bool isEnrollment,
    required bool attachToExistingUser,
  }) {
    final pipeline = _pipeline ??= IsolateFacePipeline();
    final pipelineWarmup =
        _pipelineWarmup ??=
            Platform.isAndroid
                ? pipeline.initializeNativeStreamSupport()
                : pipeline.warmupRetinaFace();
    final nativeWarmup =
        _nativeWarmup ??=
            Platform.isAndroid
                ? AndroidTfliteImageSession.prewarm(
                  RetinaFaceDetector.androidTfliteModelAsset,
                  threads: IsolateFacePipeline.retinaThreadsPerWorker,
                )
                : Future<void>.value();
    final key = _CaptureSessionKey(
      wrytteId: wrytteId,
      userId: userId,
      isEnrollment: isEnrollment,
      attachToExistingUser: attachToExistingUser,
    );
    if (_captureSessionKey != key) {
      _captureSessionKey = key;
      _captureSession = _startCaptureSession(key);
    }
    return BiometricPrewarmBundle(
      pipeline: pipeline,
      pipelineWarmup: pipelineWarmup,
      nativeWarmup: nativeWarmup,
      captureSession: _captureSession!,
    );
  }

  static BiometricPrewarmBundle take({
    required String wrytteId,
    required String? userId,
    required bool isEnrollment,
    required bool attachToExistingUser,
  }) {
    final bundle = prewarm(
      wrytteId: wrytteId,
      userId: userId,
      isEnrollment: isEnrollment,
      attachToExistingUser: attachToExistingUser,
    );
    _pipeline = null;
    _pipelineWarmup = null;
    return bundle;
  }

  static void releaseNativeWarmup() {
    _nativeWarmup = null;
  }

  /// Logout ends the current account journey. Do not let its prefetched
  /// capture session or pipeline be reused by the next Wrytte-ID signup.
  static Future<void> clearForLogout() async {
    final pipeline = _pipeline;
    _pipeline = null;
    _pipelineWarmup = null;
    _nativeWarmup = null;
    _captureSession = null;
    _captureSessionKey = null;
    await pipeline?.dispose();
  }

  static Future<String?> _startCaptureSession(_CaptureSessionKey key) async {
    try {
      if (key.isEnrollment) {
        if (key.attachToExistingUser) {
          final userId = key.userId;
          if (userId == null || userId.isEmpty) return null;
          return BiometricApiService.startExistingEnrollmentCaptureSession(
            userId: userId,
            token: await AuthService.instance.getValidBackendToken() ?? '',
          );
        }
        return BiometricApiService.startEnrollmentCaptureSession(
          wrytteId: key.wrytteId,
        );
      }
      final userId = key.userId;
      if (userId == null || userId.isEmpty) return null;
      return BiometricApiService.startVerifyCaptureSession(userId: userId);
    } catch (error) {
      debugPrint(
        '[BiometricTiming] pipeline=Prewarm stage=capture_session_error '
        'error=${error.runtimeType}',
      );
      return null;
    }
  }
}

@immutable
class _CaptureSessionKey {
  const _CaptureSessionKey({
    required this.wrytteId,
    required this.userId,
    required this.isEnrollment,
    required this.attachToExistingUser,
  });

  final String wrytteId;
  final String? userId;
  final bool isEnrollment;
  final bool attachToExistingUser;

  @override
  bool operator ==(Object other) =>
      other is _CaptureSessionKey &&
      other.wrytteId == wrytteId &&
      other.userId == userId &&
      other.isEnrollment == isEnrollment &&
      other.attachToExistingUser == attachToExistingUser;

  @override
  int get hashCode =>
      Object.hash(wrytteId, userId, isEnrollment, attachToExistingUser);
}
