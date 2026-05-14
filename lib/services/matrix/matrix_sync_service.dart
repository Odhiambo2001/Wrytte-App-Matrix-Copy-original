import 'dart:async';

import 'package:matrix/matrix.dart';

import 'matrix_auth_service.dart';
import 'matrix_client.dart';

class MatrixSyncService {
  MatrixSyncService._();
  static final MatrixSyncService instance = MatrixSyncService._();

  StreamSubscription<SyncUpdate>? _syncSub;

  Stream<SyncUpdate> get onSync =>
      MatrixClientService.instance.client.onSync.stream;

  Future<void> start({void Function(SyncUpdate update)? onSync}) async {
    final client = await MatrixAuthService.instance.restore();
    _syncSub ??= client.onSync.stream.listen(onSync ?? (_) {});
    client.backgroundSync = true;
  }

  Future<void> stop() async {
    await _syncSub?.cancel();
    _syncSub = null;
    if (MatrixClientService.instance.isInitialized) {
      MatrixClientService.instance.client.backgroundSync = false;
    }
  }
}
