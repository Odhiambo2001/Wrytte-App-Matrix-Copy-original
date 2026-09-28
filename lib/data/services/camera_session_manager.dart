import 'dart:async';

class CameraSessionManager {
  Future<void> _tail = Future<void>.value();
  int _generation = 0;

  int get generation => _generation;
  int invalidate() => ++_generation;
  bool isCurrent(int generation) => generation == _generation;

  Future<T> serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
