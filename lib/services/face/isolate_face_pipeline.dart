import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:wrytte/services/face/biometric_worker.dart';
import 'package:wrytte/services/face/face_biometric_pipeline.dart';
import 'package:wrytte/services/face/minifasnet_v2_liveness.dart';
import 'package:wrytte/services/face/opencv_face_preprocessor.dart';
import 'package:wrytte/services/face/retinaface_detector.dart';

TransferableTypedData _transfer(Uint8List bytes) {
  // TransferableTypedData owns a distinct buffer. The sender can therefore
  // erase its image immediately without racing the receiving worker.
  final transfer = TransferableTypedData.fromList([Uint8List.fromList(bytes)]);
  bytes.fillRange(0, bytes.length, 0);
  return transfer;
}

Uint8List _bytes(Object? value) =>
    (value as TransferableTypedData).materialize().asUint8List();
void _wipe(Uint8List bytes) => bytes.fillRange(0, bytes.length, 0);

Map<String, Object?> _pointToWire(math.Point<double> point) =>
    <String, Object?>{'x': point.x, 'y': point.y};

math.Point<double> _pointFromWire(Map<Object?, Object?> wire) =>
    math.Point<double>(
      (wire['x']! as num).toDouble(),
      (wire['y']! as num).toDouble(),
    );

Map<String, Object?> _targetToWire(FaceDetection face) => <String, Object?>{
  'left': face.left,
  'top': face.top,
  'right': face.right,
  'bottom': face.bottom,
  'confidence': face.confidence,
  'leftEye': _pointToWire(face.landmarks.leftEye),
  'rightEye': _pointToWire(face.landmarks.rightEye),
  'nose': _pointToWire(face.landmarks.nose),
  'leftMouth': _pointToWire(face.landmarks.leftMouth),
  'rightMouth': _pointToWire(face.landmarks.rightMouth),
};

FaceDetection _targetFromWire(Map<Object?, Object?> wire) => FaceDetection(
  left: (wire['left']! as num).toDouble(),
  top: (wire['top']! as num).toDouble(),
  right: (wire['right']! as num).toDouble(),
  bottom: (wire['bottom']! as num).toDouble(),
  confidence: (wire['confidence']! as num).toDouble(),
  landmarks: FaceLandmarks(
    leftEye: _pointFromWire(wire['leftEye']! as Map<Object?, Object?>),
    rightEye: _pointFromWire(wire['rightEye']! as Map<Object?, Object?>),
    nose: _pointFromWire(wire['nose']! as Map<Object?, Object?>),
    leftMouth: _pointFromWire(wire['leftMouth']! as Map<Object?, Object?>),
    rightMouth: _pointFromWire(wire['rightMouth']! as Map<Object?, Object?>),
  ),
);

Map<String, Object?> _boxToWire(LivenessFaceBox box) => <String, Object?>{
  'x': box.x,
  'y': box.y,
  'width': box.width,
  'height': box.height,
};

LivenessFaceBox _boxFromWire(Map<Object?, Object?> wire) => LivenessFaceBox(
  x: wire['x']! as int,
  y: wire['y']! as int,
  width: wire['width']! as int,
  height: wire['height']! as int,
);

Map<String, Object?> _analysisToWire(FrameAnalysis analysis) =>
    <String, Object?>{
      'faceDetected': analysis.faceDetected,
      'targetFaceSelected': analysis.targetFaceSelected,
      'alignmentAccepted': analysis.alignmentAccepted,
      'processingMilliseconds': analysis.processingMilliseconds,
      'faceCenterX': analysis.faceCenterX,
      'faceCenterY': analysis.faceCenterY,
      'faceTooFar': analysis.faceTooFar,
      'faceTooClose': analysis.faceTooClose,
      'multipleFaces': analysis.multipleFaces,
    };

FrameAnalysis _analysisFromWire(Map<Object?, Object?> wire) => FrameAnalysis(
  faceDetected: wire['faceDetected']! as bool,
  targetFaceSelected: wire['targetFaceSelected']! as bool,
  alignmentAccepted: wire['alignmentAccepted']! as bool,
  processingMilliseconds: wire['processingMilliseconds']! as int,
  faceCenterX: (wire['faceCenterX'] as num?)?.toDouble(),
  faceCenterY: (wire['faceCenterY'] as num?)?.toDouble(),
  faceTooFar: wire['faceTooFar']! as bool,
  faceTooClose: wire['faceTooClose']! as bool,
  multipleFaces: wire['multipleFaces']! as bool,
);

class WorkerCropCapture {
  WorkerCropCapture(
    this.generation,
    this.index,
    this.retinaWorker,
    this.target,
    this.source,
    this.width,
    this.height,
    this.box,
  );
  final int generation, index, width, height;
  final String retinaWorker;
  final FaceDetection target;
  final LivenessFaceBox box;
  Uint8List source;
  void clear() {
    _wipe(source);
    source = Uint8List(0);
  }
}

class WorkerLivenessCapture {
  WorkerLivenessCapture(
    this.generation,
    this.index,
    this.retinaWorker,
    this.target,
    this.crop,
    this.width,
    this.height,
    this.box,
  ) : capture = BiometricCropSet(
        retinaFaceBgr: Uint8List(0),
        adafaceLandmarks: target.landmarks,
        livenessFaceBox: box,
      );
  final int generation, index, width, height;
  final String retinaWorker;
  final FaceDetection target;
  final LivenessFaceBox box;
  final Uint8List crop;
  BiometricCropSet capture;
  void clear() {
    _wipe(crop);
    capture.clear();
  }
}

class WorkerRetinaResult {
  WorkerRetinaResult(this.analysis, this.pendingCrop);
  final FrameAnalysis analysis;
  final WorkerCropCapture? pendingCrop;
}

/// Camera/UI stay on the root isolate. Each heavy stage has one persistent
/// isolate, and only pixels, geometry, frame IDs and generations cross ports.
class IsolateFacePipeline {
  // The three background workers are: RetinaFace preparation/detection,
  // crop-plus-liveness, and JPEG encoding. Flutter's root isolate is the
  // fourth lane: it owns animation and all widget state updates.
  static const retinaWorkerCount = 1;
  static const retinaThreadsPerWorker = 4;

  Map<String, BiometricWorker> _workers = {};
  int _generation = 0, _index = 0;
  Future<void>? _initializing;
  Future<void> _closing = Future.value();
  bool _disposed = false;

  Future<void> initializeDetector() => _initializing ??= _initialize();

  /// Compile/prepare the selected RetinaFace execution provider while the
  /// camera warms up, before any user frame is admitted for extraction.
  Future<void> warmupRetinaFace() async {
    await initializeDetector();
    final generation = _generation;
    await Future.wait(
      List<Future<Object?>>.generate(
        retinaWorkerCount,
        (index) => _call('retina-$index', generation, 'warmup', null),
      ),
    );
  }

  Future<void> _initialize() async {
    await _closing;
    final generation = _generation;
    final created = <String, BiometricWorker>{};
    try {
      for (final stage in ['liveness', 'jpeg']) {
        created[stage] = await BiometricWorker.start(
          stage,
          generation,
          _workerMain,
        );
      }
      for (var index = 0; index < retinaWorkerCount; index++) {
        final stage = 'retina-$index';
        created[stage] = await BiometricWorker.start(
          stage,
          generation,
          _workerMain,
        );
      }
      if (_disposed || generation != _generation) {
        throw StateError('Stale initialization');
      }
      _workers = created;
    } catch (_) {
      await Future.wait(created.values.map((w) => w.cancelGeneration()));
      rethrow;
    }
  }

  void _check(int generation) {
    if (_disposed || generation != _generation) {
      throw StateError('Cancelled biometric generation');
    }
  }

  Future<Object?> _call(
    String stage,
    int generation,
    String command,
    Object? data,
  ) async {
    _check(generation);
    final result = await _workers[stage]!.call(command, data);
    return result;
  }

  Future<WorkerRetinaResult> processRetinaFrame(img.Image image) async {
    await initializeDetector();
    final generation = _generation, index = _index++;
    final raw = image.getBytes(order: img.ChannelOrder.rgb);
    final retinaWorker = 'retina-${index % retinaWorkerCount}';
    final result =
        await _call(retinaWorker, generation, 'process', [
              index,
              image.width,
              image.height,
              _transfer(raw),
            ])
            as Map;
    final analysis = _analysisFromWire(
      result['analysis']! as Map<Object?, Object?>,
    );
    final source = result['source'];
    if (generation != _generation) {
      if (source != null) _wipe(_bytes(source));
      throw StateError('Cancelled frame');
    }
    return WorkerRetinaResult(
      analysis,
      source == null
          ? null
          : WorkerCropCapture(
            generation,
            index,
            retinaWorker,
            _targetFromWire(result['target']! as Map<Object?, Object?>),
            _bytes(source),
            result['width'] as int,
            result['height'] as int,
            _boxFromWire(result['box']! as Map<Object?, Object?>),
          ),
    );
  }

  Future<WorkerLivenessCapture> cropForLiveness(
    WorkerCropCapture pending,
  ) async {
    try {
      final result = await _call('liveness', pending.generation, 'crop', [
        pending.index,
        pending.width,
        pending.height,
        _boxToWire(pending.box),
        _transfer(pending.source),
      ]);
      final crop = _bytes(result);
      if (pending.generation != _generation) {
        _wipe(crop);
        throw StateError('Cancelled crop');
      }
      return WorkerLivenessCapture(
        pending.generation,
        pending.index,
        pending.retinaWorker,
        pending.target,
        crop,
        pending.width,
        pending.height,
        pending.box,
      );
    } finally {
      pending.clear();
    }
  }

  Future<bool> checkLiveness(WorkerLivenessCapture pending) async {
    try {
      final live =
          await _call('liveness', pending.generation, 'check', [
                pending.index,
                _transfer(pending.crop),
              ])
              as bool;
      _check(pending.generation);
      return live;
    } finally {
      _wipe(pending.crop);
    }
  }

  /// The liveness isolate is released before this request waits for the
  /// RetinaFace worker. A real result retrieves the retained original;
  /// a fake result tells RetinaFace to wipe it.
  Future<void> resolveRetinaOriginal(
    WorkerLivenessCapture pending,
    bool live,
  ) async {
    final original = await _call(
      pending.retinaWorker,
      pending.generation,
      live ? 'takeOriginal' : 'discardOriginal',
      pending.index,
    );
    if (original != null) {
      final bytes = _bytes(original);
      if (pending.generation != _generation) {
        _wipe(bytes);
        throw StateError('Cancelled original');
      }
      pending.capture = BiometricCropSet(
        retinaFaceBgr: bytes,
        adafaceLandmarks: pending.target.landmarks,
        livenessFaceBox: pending.box,
      );
    }
  }

  Future<void> prepareJpeg(BiometricCropSet capture) async {
    final generation = _generation;
    final result = await _call(
      'jpeg',
      generation,
      'process',
      _transfer(capture.retinaFaceBgr),
    );
    final jpeg = _bytes(result);
    if (generation != _generation) {
      _wipe(jpeg);
      throw StateError('Cancelled JPEG');
    }
    capture.retinaFaceJpeg = jpeg;
  }

  Future<void> reset() {
    _generation++;
    final workers = _workers;
    _workers = {};
    final initializing = _initializing;
    _initializing = null;
    final previous = _closing;
    _closing = () async {
      await previous;
      if (initializing != null) {
        try {
          await initializing;
        } catch (_) {}
      }
      await Future.wait(workers.values.map((w) => w.cancelGeneration()));
    }();
    return _closing;
  }

  Future<void> dispose() {
    _disposed = true;
    return reset();
  }
}

@pragma('vm:entry-point')
Future<void> _workerMain(List<Object> arguments) async {
  final stage = arguments[0] as String, generation = arguments[1] as int;
  initializeBiometricWorker(arguments[2] as RootIsolateToken);
  final replies = arguments[3] as SendPort;
  final commands = ReceivePort();
  final retina = RetinaFaceDetector(
    inferenceThreads: IsolateFacePipeline.retinaThreadsPerWorker,
  );
  final liveness = MiniFasNetV2Liveness();
  final originals = <int, Uint8List>{};
  if (stage.startsWith('retina-')) await retina.initialize();
  if (stage == 'liveness') await liveness.initialize();
  replies.send(commands.sendPort);
  var cancelled = false;
  await for (final dynamic message in commands) {
    final request = message as List;
    final id = request[0], command = request[2] as String;
    final timer = Stopwatch()..start();
    try {
      Object? result;
      if (command == 'cancelGeneration' || command == 'dispose') {
        cancelled = true;
        for (final bytes in originals.values) {
          _wipe(bytes);
        }
        originals.clear();
        await retina.dispose();
        await liveness.dispose();
      } else {
        if (cancelled || request[1] != generation) {
          throw StateError('Stale generation');
        }
        final data = request[3];
        if (stage.startsWith('retina-')) {
          if (command == 'warmup') {
            final blank = Uint8List(640 * 640 * 3);
            try {
              await retina.detectBgr(blank);
            } finally {
              _wipe(blank);
            }
          } else if (command == 'takeOriginal' ||
              command == 'discardOriginal') {
            final original = originals.remove(data as int);
            if (original != null) {
              if (command == 'takeOriginal') {
                result = _transfer(original);
              } else {
                _wipe(original);
              }
            }
          } else {
            final values = data as List;
            final rgb = _bytes(values[3]);
            final image = img.Image.fromBytes(
              width: values[1] as int,
              height: values[2] as int,
              bytes: rgb.buffer,
              numChannels: 3,
              order: img.ChannelOrder.rgb,
            );
            RetinaFrame? frame;
            Uint8List? bgr;
            var retained = false;
            try {
              // Worker 1 owns conversion, 640x640 crop and RetinaFace. Keep
              // its own detector copy only when this exact frame is selected.
              frame = OpenCvFacePreprocessor().prepare(image);
              bgr = Uint8List.fromList(frame.bgr);
              final faces = await retina.detectBgr(bgr);
              final target = FaceBiometricPipeline.chooseTarget(faces);
              result = <String, Object>{
                'analysis': _analysisToWire(
                  FrameAnalysis(
                    faceDetected: faces.isNotEmpty,
                    targetFaceSelected: target != null,
                    alignmentAccepted: target != null,
                    processingMilliseconds: timer.elapsedMilliseconds,
                    faceCenterX: target?.centerX,
                    faceCenterY: target?.centerY,
                    multipleFaces: faces.length > 1,
                    faceTooFar:
                        faces.isNotEmpty &&
                        faces.every(
                          (f) =>
                              FaceBiometricPipeline.measureFaceDistance(
                                f,
                              ).label ==
                              'FAR',
                        ),
                    faceTooClose:
                        faces.isNotEmpty &&
                        faces.every(
                          (f) =>
                              FaceBiometricPipeline.measureFaceDistance(
                                f,
                              ).label ==
                              'CLOSE',
                        ),
                  ),
                ),
                if (target != null) ...{
                  'target': _targetToWire(target),
                  'source': _transfer(frame.originalBgr),
                  'width': frame.originalWidth,
                  'height': frame.originalHeight,
                  'box': _boxToWire(
                    OpenCvFacePreprocessor.mapRetinaFaceToOriginalBox(
                      cropX: frame.cropX,
                      cropY: frame.cropY,
                      cropSide: frame.cropSide,
                      faceLeft: target.left,
                      faceTop: target.top,
                      faceWidth: target.width,
                      faceHeight: target.height,
                    ),
                  ),
                },
              };
              if (target != null) {
                originals[values[0] as int] = bgr;
                retained = true;
              }
            } finally {
              if (!retained && bgr != null) _wipe(bgr);
              frame?.dispose();
              _wipe(rgb);
              image.data?.toUint8List().fillRange(
                0,
                image.data!.toUint8List().length,
                0,
              );
            }
          }
        } else if (stage == 'liveness' && command == 'crop') {
          final values = data as List;
          final box = _boxFromWire(values[3] as Map<Object?, Object?>);
          final source = _bytes(values[4]);
          cv.Mat? mat, cropped, resized;
          cv.Rect? roi;
          try {
            final crop = OpenCvFacePreprocessor.calculateMiniFasNetCropBox(
              sourceWidth: values[1] as int,
              sourceHeight: values[2] as int,
              x: box.x,
              y: box.y,
              boxWidth: box.width,
              boxHeight: box.height,
              scale: 2.7,
            );
            mat = cv.Mat.fromList(
              values[2] as int,
              values[1] as int,
              cv.MatType.CV_8UC3,
              source,
            );
            roi = cv.Rect(crop.left, crop.top, crop.width, crop.height);
            cropped = cv.Mat.fromMat(mat, roi: roi);
            resized = cv.resize(cropped, (
              80,
              80,
            ), interpolation: cv.INTER_LINEAR);
            result = _transfer(resized.data);
          } finally {
            if (resized != null) {
              _wipe(resized.data);
              resized.dispose();
            }
            cropped?.dispose();
            roi?.dispose();
            if (mat != null) {
              _wipe(mat.data);
              mat.dispose();
            }
            _wipe(source);
          }
        } else if (stage == 'liveness' && command == 'check') {
          final crop = _bytes((data as List)[1]);
          try {
            result = await liveness.isReal(crop);
          } finally {
            _wipe(crop);
          }
        } else if (stage == 'jpeg') {
          final bgr = _bytes(data);
          if (bgr.length != 640 * 640 * 3) {
            _wipe(bgr);
            throw ArgumentError('Invalid RetinaFace buffer');
          }
          final image = img.Image.fromBytes(
            width: 640,
            height: 640,
            bytes: bgr.buffer,
            numChannels: 3,
            order: img.ChannelOrder.bgr,
          );
          try {
            result = _transfer(
              Uint8List.fromList(img.encodeJpg(image, quality: 90)),
            );
          } finally {
            _wipe(bgr);
            final pixels = image.data!.toUint8List();
            _wipe(pixels);
          }
        }
      }
      replies.send([id, generation, true, result]);
      final pipeline = switch (stage) {
        _ when stage.startsWith('retina-') => 'RetinaFace',
        'liveness' => 'Liveness',
        'jpeg' => 'JPEG',
        _ => stage,
      };
      // ignore: avoid_print
      print(
        '[BiometricTiming] pipeline=$pipeline stage=$command generation=$generation '
        'elapsed_ms=${timer.elapsedMilliseconds} worker=${Isolate.current.debugName}',
      );
      if (command == 'dispose') {
        commands.close();
        break;
      }
    } catch (error, stack) {
      replies.send([id, generation, false, '$error\n$stack']);
    }
  }
}
