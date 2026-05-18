import 'dart:async';
import 'dart:io';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'matrix_config.dart';

class MatrixClientService {
  MatrixClientService._();
  static final MatrixClientService instance = MatrixClientService._();

  Client? _client;
  Future<Client>? _initializing;

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

  Future<Client> ensureInitialized() {
    if (_client != null) return Future.value(_client);
    final pending = _initializing;
    if (pending != null) return pending;
    _initializing = _buildClient();
    return _initializing!;
  }

  Future<Client> _buildClient() async {
    final supportDir = await getApplicationSupportDirectory();
    final cacheDir = await getApplicationCacheDirectory();
    final mediaDir = Directory('${cacheDir.path}/matrix_media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }

    // ✅ FIXED — no PRAGMA statements at all
    // MatrixSdkDatabase handles WAL internally
    final database = await sqlite.openDatabase(
      '${supportDir.path}/${MatrixConfig.localDatabaseFile}',
    );

    final client = Client(
      MatrixConfig.appServiceName,
      database: await MatrixSdkDatabase.init(
        MatrixConfig.localDatabaseName,
        database: database,
        maxFileSize: MatrixConfig.localMediaMaxBytes,
        fileStorageLocation: Uri.directory('${mediaDir.path}/'),
        deleteFilesAfterDuration: MatrixConfig.localMediaTtl,
      ),
    );

    await client.init(waitForFirstSync: false);
    _client = client;
    _initializing = null;
    return client;
  }

  Future<void> initWithCredentials({
    required Uri homeserver,
    required String userId,
    required String accessToken,
    String? deviceId,
  }) async {
    final matrix = await ensureInitialized();
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
    if (matrix.isLogged()) {
      await matrix.logout();
    } else {
      await matrix.clear();
    }
  }
}
