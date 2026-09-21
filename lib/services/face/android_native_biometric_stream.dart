import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/isolate_face_pipeline.dart';
import 'package:wrytte/services/face/opencv_face_preprocessor.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

class AndroidNativeBiometricFrame {
  AndroidNativeBiometricFrame({
    required this.index,
    required this.analysis,
    this.pendingCrop,
  });

  final int index;
  final FrameAnalysis analysis;
  final WorkerCropCapture? pendingCrop;
}

class AndroidNativeBiometricStream {
  AndroidNativeBiometricStream._();

  static const _methods = MethodChannel(
    'com.example.wrytte/native_biometric_stream',
  );
  static const _events = EventChannel(
    'com.example.wrytte/native_biometric_stream/events',
  );

  static Stream<AndroidNativeBiometricFrame>? _stream;

  static bool get isSupported => Platform.isAndroid;

  static Future<void> start({
    String asset = RetinaFaceDetector.androidTfliteModelAsset,
    int threads = IsolateFacePipeline.retinaThreadsPerWorker,
  }) {
    if (!isSupported) return Future<void>.value();
    return _methods.invokeMethod<void>('start', <String, Object>{
      'asset': asset,
      'threads': threads,
    });
  }

  static Future<void> stop() {
    if (!isSupported) return Future<void>.value();
    return _methods.invokeMethod<void>('stop');
  }

  static Stream<AndroidNativeBiometricFrame> frames() {
    if (!isSupported) return const Stream<AndroidNativeBiometricFrame>.empty();
    return _stream ??= _events.receiveBroadcastStream().map((event) {
      final map = Map<Object?, Object?>.from(event as Map);
      final analysis = _analysisFromNative(map);
      final target = map['target'];
      final source = map['source'];
      final jpeg = map['jpeg'];
      WorkerCropCapture? pendingCrop;
      if (target is Map && source is Uint8List) {
        pendingCrop = WorkerCropCapture(
          0,
          (map['index'] as num).toInt(),
          'android-native',
          _targetFromNative(Map<Object?, Object?>.from(target)),
          source,
          (map['width'] as num?)?.toInt() ?? 640,
          (map['height'] as num?)?.toInt() ?? 640,
          LivenessFaceBox(
            x: 0,
            y: 0,
            width: (map['width'] as num?)?.toInt() ?? 640,
            height: (map['height'] as num?)?.toInt() ?? 640,
          ),
          jpeg is Uint8List ? jpeg : null,
        );
      }
      return AndroidNativeBiometricFrame(
        index: (map['index'] as num).toInt(),
        analysis: analysis,
        pendingCrop: pendingCrop,
      );
    });
  }

  static FrameAnalysis _analysisFromNative(Map<Object?, Object?> map) {
    return FrameAnalysis(
      faceDetected: map['faceDetected'] == true,
      targetFaceSelected: map['targetFaceSelected'] == true,
      alignmentAccepted: map['alignmentAccepted'] == true,
      processingMilliseconds:
          (map['processingMilliseconds'] as num?)?.toInt() ?? 0,
      faceCenterX: (map['faceCenterX'] as num?)?.toDouble(),
      faceCenterY: (map['faceCenterY'] as num?)?.toDouble(),
      faceTooFar: map['faceTooFar'] == true,
      faceTooClose: map['faceTooClose'] == true,
      multipleFaces: map['multipleFaces'] == true,
    );
  }

  static FaceDetection _targetFromNative(Map<Object?, Object?> map) {
    return FaceDetection(
      left: (map['left'] as num).toDouble(),
      top: (map['top'] as num).toDouble(),
      right: (map['right'] as num).toDouble(),
      bottom: (map['bottom'] as num).toDouble(),
      rawLeft: (map['rawLeft'] as num?)?.toDouble(),
      rawTop: (map['rawTop'] as num?)?.toDouble(),
      rawRight: (map['rawRight'] as num?)?.toDouble(),
      rawBottom: (map['rawBottom'] as num?)?.toDouble(),
      confidence: (map['confidence'] as num).toDouble(),
      landmarks: FaceLandmarks(
        leftEye: _point(map['landmarks'], 0),
        rightEye: _point(map['landmarks'], 1),
        nose: _point(map['landmarks'], 2),
        leftMouth: _point(map['landmarks'], 3),
        rightMouth: _point(map['landmarks'], 4),
      ),
    );
  }

  static Point<double> _point(Object? value, int index) {
    final values = List<Object?>.from(value as List);
    return Point<double>(
      (values[index * 2] as num).toDouble(),
      (values[index * 2 + 1] as num).toDouble(),
    );
  }
}
