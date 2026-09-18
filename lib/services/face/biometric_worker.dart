import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';

/// An ordered, persistent isolate. Native handles never leave its entry point.
class BiometricWorker {
  BiometricWorker._(
    this.generation,
    this._isolate,
    this._commands,
    this._replies,
    this._errors,
    this._exits,
  );

  final int generation;
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies, _errors, _exits;
  final Map<int, Completer<Object?>> _pending = {};
  int _sequence = 0;
  bool _closing = false;
  Future<void>? _close;

  static Future<BiometricWorker> start(
    String stage,
    int generation,
    void Function(List<Object>) entry,
  ) async {
    final token = RootIsolateToken.instance;
    if (token == null) {
      throw StateError('Workers must be started on the root isolate.');
    }
    final replies = ReceivePort(),
        errors = ReceivePort(),
        exits = ReceivePort();
    final ready = Completer<SendPort>();
    BiometricWorker? worker;
    replies.listen((dynamic message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final response = message as List;
      final pending = worker?._pending.remove(response[0]);
      if (pending == null) return;
      if (response[1] != generation || response[2] == false) {
        pending.completeError(StateError('${response[3]}'));
      } else {
        pending.complete(response[3]);
      }
    });
    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
      final active = worker;
      if (active != null) {
        active._closing = true;
        for (final pending in active._pending.values) {
          pending.completeError(error);
        }
        active._pending.clear();
      }
    }

    errors.listen((dynamic error) => fail(StateError('$stage worker: $error')));
    exits.listen((_) => fail(StateError('$stage worker exited')));
    try {
      final isolate = await Isolate.spawn(
        entry,
        <Object>[stage, generation, token, replies.sendPort],
        debugName: 'biometric-$stage-$generation',
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );
      final commands = await ready.future;
      final startedWorker = BiometricWorker._(
        generation,
        isolate,
        commands,
        replies,
        errors,
        exits,
      );
      worker = startedWorker;
      return startedWorker;
    } catch (_) {
      replies.close();
      errors.close();
      exits.close();
      rethrow;
    }
  }

  Future<Object?> call(String command, Object? payload) {
    if (_closing) {
      return Future.error(StateError('Worker generation cancelled'));
    }
    return _send(command, payload);
  }

  Future<Object?> _send(String command, Object? payload) {
    final id = _sequence++;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands.send(<Object?>[id, generation, command, payload]);
    return result.future;
  }

  /// Cooperative shutdown waits for in-flight native calls before releasing
  /// sessions. Killing an isolate first would orphan its native resources.
  Future<void> cancelGeneration() => _close ??= _shutdown();
  Future<void> _shutdown() async {
    _closing = true;
    try {
      await _send('cancelGeneration', null);
      await _send('dispose', null);
    } finally {
      _replies.close();
      _errors.close();
      _exits.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

void initializeBiometricWorker(RootIsolateToken token) {
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
}
