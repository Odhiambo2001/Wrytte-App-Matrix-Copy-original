import 'dart:async';
import 'dart:io';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'matrix_config.dart';

class MatrixClientService {
  MatrixClientService._();
  static final MatrixClientService instance = MatrixClientService._();

  Client? _client;
  Future<Client>? _initializing;
  String? _storeNamespace;
  String? _initializingStoreNamespace;

  Client get client {
    final value = _client;
    if (value == null) {
      throw StateError('Matrix client has not been initialized yet.');
    }
    return value;
  }

  bool get isInitialized => _client != null;
  bool get isLoggedIn => _client?.isLogged() ?? false;
  String? get userId => _client?.userID;
  String? get accessToken => _client?.accessToken;

  Future<Client> ensureInitialized({String? storeNamespace}) async {
    final namespace = _normalizeStoreNamespace(storeNamespace);
    if (_client != null && _storeNamespace == namespace) {
      return _client!;
    }

    final pending = _initializing;
    if (pending != null && _initializingStoreNamespace == namespace) {
      return pending;
    }
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
      return ensureInitialized(storeNamespace: namespace);
    }

    if (_client != null && _storeNamespace != namespace) {
      await disposeCurrentClient();
    }

    _initializingStoreNamespace = namespace;
    _initializing = _buildClient(namespace);
    final initializing = _initializing!;
    try {
      return await initializing;
    } finally {
      if (identical(_initializing, initializing)) {
        _initializing = null;
        _initializingStoreNamespace = null;
      }
    }
  }

  Future<Client> _buildClient(String storeNamespace) async {
    // Try each candidate directory until one passes the write test
    final candidates = [
      () => getApplicationSupportDirectory(),
      () => getApplicationDocumentsDirectory(),
    ];

    Directory? storeDir;
    for (final getDir in candidates) {
      try {
        final baseDir = await getDir();
        final candidate = Directory(
          p.join(baseDir.path, 'matrix', storeNamespace),
        );
        await candidate.create(recursive: true);
        final testFile = File(p.join(candidate.path, '.matrix_io_test'));
        await testFile.writeAsString('ok');
        await testFile.delete();
        storeDir = candidate;
        break;
      } catch (_) {
        continue;
      }
    }

    if (storeDir == null) {
      throw StateError(
        'No writable directory found for Matrix local store. '
        'Both application support and documents directories failed the I/O test.',
      );
    }

    final cacheDir = await getApplicationCacheDirectory();
    final mediaDir = Directory(
      p.join(cacheDir.path, 'matrix_media', storeNamespace),
    );
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }

    final dbPath = p.join(storeDir.path, MatrixConfig.localDatabaseFile);

    final database = await sqlite.openDatabase(dbPath);

    final client = Client(
      MatrixConfig.appServiceName,
      requestHistoryOnLimitedTimeline: true,
      syncFilter: Filter(
        room: RoomFilter(
          state: StateFilter(lazyLoadMembers: true),
          timeline: StateFilter(
            lazyLoadMembers: true,
            limit: MatrixConfig.historyPageSize,
          ),
        ),
      ),
      database: await MatrixSdkDatabase.init(
        '${MatrixConfig.localDatabaseName}_$storeNamespace',
        database: database,
        maxFileSize: MatrixConfig.localMediaMaxBytes,
        fileStorageLocation: Uri.directory('${mediaDir.path}/'),
        deleteFilesAfterDuration: MatrixConfig.localMediaTtl,
      ),
    );

    await client.init(waitForFirstSync: false);
    _client = client;
    _storeNamespace = storeNamespace;
    _initializing = null;
    _initializingStoreNamespace = null;
    return client;
  }

  Future<void> initWithCredentials({
    required Uri homeserver,
    required String userId,
    required String accessToken,
    String? deviceId,
  }) async {
    final matrix = await ensureInitialized(storeNamespace: userId);
    await matrix.init(
      newHomeserver: homeserver,
      newUserID: userId,
      newToken: accessToken,
      newDeviceID: deviceId,
      waitForFirstSync: false,
    );
  }

  Future<void> logout() async {
    final matrix = _client;
    if (matrix == null) return;
    try {
      if (matrix.isLogged()) {
        await matrix.logout();
      } else {
        await matrix.clear();
      }
    } finally {
      await disposeCurrentClient();
    }
  }

  Future<void> clearLocalSession() async {
    final matrix = _client;
    if (matrix == null) return;
    await matrix.clear();
  }

  Future<void> disposeCurrentClient() async {
    final matrix = _client;
    _client = null;
    _initializing = null;
    _storeNamespace = null;
    _initializingStoreNamespace = null;
    try {
      await matrix?.dispose();
    } catch (_) {}
  }

  Future<void> deleteLocalStore() async {
    // Null these immediately so ensureInitialized() is forced
    // to call _buildClient() fresh on the next connect()
    final matrix = _client;

    // Try to clear the SDK's in-memory state first
    try {
      await matrix?.clear();
    } catch (_) {}
    await disposeCurrentClient();

    // Wipe DB files from every possible store location
    try {
      final dirs = await Future.wait([
        getApplicationSupportDirectory(),
        getApplicationDocumentsDirectory(),
      ]);
      for (final dir in dirs) {
        final matrixDir = Directory(p.join(dir.path, 'matrix'));
        if (await matrixDir.exists()) {
          await matrixDir.delete(recursive: true);
        }

        final legacyDbBase = p.join(dir.path, MatrixConfig.localDatabaseFile);
        for (final path in [
          legacyDbBase,
          '$legacyDbBase-wal',
          '$legacyDbBase-shm',
        ]) {
          try {
            final file = File(path);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}

    // Wipe media cache
    try {
      final cacheDir = await getApplicationCacheDirectory();
      final mediaDir = Directory(p.join(cacheDir.path, 'matrix_media'));
      if (await mediaDir.exists()) {
        await mediaDir.delete(recursive: true);
      }
    } catch (_) {}
  }

  String _normalizeStoreNamespace(String? raw) {
    var trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return 'default';
    if (trimmed.startsWith('@')) {
      final serverSeparator = trimmed.indexOf(':');
      if (serverSeparator > 1) {
        trimmed = trimmed.substring(1, serverSeparator);
      }
    }
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}
