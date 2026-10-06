import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
  StreamSubscription<ToDeviceEvent>? _toDeviceCaptureSub;
  StreamSubscription<SyncUpdate>? _profileUpdateCaptureSub;
  final List<ToDeviceEvent> _pendingGroupDeletionEvents = [];
  final List<String> _pendingProfileUpdates = [];
  final Set<String> _capturedGroupDeletionKeys = {};
  final Map<String, String> _capturedProfileUpdateEventIds = {};
  final Map<String, String> _observedMatrixDisplayNames = {};
  final StreamController<String> _profileUpdateController =
      StreamController<String>.broadcast();

  static const String _groupDeletedToDeviceType = 'com.wrytte.group.deleted';
  static const String profileUpdatedEventType = 'com.wrytte.profile.updated';

  Stream<String> get profileUpdateStream => _profileUpdateController.stream;

  List<String> takePendingProfileUpdates() {
    final updates = List<String>.of(_pendingProfileUpdates);
    _pendingProfileUpdates.clear();
    return updates;
  }

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

  /// Returns deletion notifications captured before [ChatService] finishes
  /// binding its account-scoped local database.
  ///
  /// Matrix to-device events are delivered once. In particular, an offline
  /// member can receive this event in the first sync after being removed from
  /// a room, before the chat layer has attached its own listener. Capturing it
  /// with the client prevents that one-shot notification from being lost.
  List<ToDeviceEvent> takePendingGroupDeletionEvents() {
    final events = List<ToDeviceEvent>.of(_pendingGroupDeletionEvents);
    _pendingGroupDeletionEvents.clear();
    return events;
  }

  void _captureGroupDeletionEvent(ToDeviceEvent event) {
    _captureProfileUpdateToDeviceEvent(event);
    if (event.type != _groupDeletedToDeviceType) return;
    final roomId = event.content['room_id']?.toString().trim() ?? '';
    if (roomId.isEmpty) return;
    final deletedAt =
        event.content['wrytte.deleted_at']?.toString().trim() ?? '';
    final key = '$roomId|$deletedAt';
    if (!_capturedGroupDeletionKeys.add(key)) return;
    _pendingGroupDeletionEvents.add(event);
  }

  void _captureProfileUpdateToDeviceEvent(ToDeviceEvent event) {
    if (event.type != profileUpdatedEventType) return;
    final ownerId = event.content['user_id']?.toString().trim() ?? '';
    final senderId = event.senderId.trim();
    if (ownerId.isEmpty ||
        senderId.isEmpty ||
        _profileUpdateLocalpart(ownerId) != _profileUpdateLocalpart(senderId)) {
      return;
    }
    final revision = event.content['revision']?.toString().trim() ?? '';
    final dedupeKey = revision.isNotEmpty
        ? '$senderId|$revision'
        : '$senderId|to-device|${event.content.hashCode}';
    if (_capturedProfileUpdateEventIds.containsKey(dedupeKey)) return;
    _capturedProfileUpdateEventIds[dedupeKey] =
        _profileUpdateLocalpart(ownerId);
    if (_profileUpdateController.hasListener) {
      _profileUpdateController.add(ownerId);
    } else {
      _pendingProfileUpdates.add(ownerId);
    }
  }

  void _startEarlyToDeviceCapture(Client client) {
    _toDeviceCaptureSub?.cancel();
    _toDeviceCaptureSub = client.onToDeviceEvent.stream.listen(
      _captureGroupDeletionEvent,
    );
    _profileUpdateCaptureSub?.cancel();
    _profileUpdateCaptureSub = client.onSync.stream.listen(
      _captureProfileUpdateEvents,
    );
    final cached = client.onToDeviceEvent.value;
    if (cached != null) _captureGroupDeletionEvent(cached);
  }

  void _captureProfileUpdateEvents(SyncUpdate update) {
    for (final presence in update.presence ?? const []) {
      final userId = presence.senderId.trim();
      if (userId.isEmpty) continue;
      debugPrint(
        '[Matrix.presence] sync_update user_id="$userId" '
        'status="${presence.presence.presence.name}"',
      );
    }

    final joinedRooms = update.rooms?.join;
    if (joinedRooms == null) return;
    for (final room in joinedRooms.values) {
      final stateAndTimelineEvents = <MatrixEvent>[
        ...?room.state,
        ...?room.timeline?.events,
      ];
      for (final event in stateAndTimelineEvents) {
        _captureMatrixDisplayNameChange(event);
        if (event.type != profileUpdatedEventType) continue;
        final ownerId = event.content['user_id']?.toString().trim() ?? '';
        if (event.senderId.isEmpty ||
            _profileUpdateLocalpart(ownerId) !=
                _profileUpdateLocalpart(event.senderId)) {
          continue;
        }
        final eventId = event.eventId;
        final revision = event.content['revision']?.toString() ?? '';
        final dedupeKey = revision.isNotEmpty
            ? '${event.senderId}|$revision'
            : eventId.isNotEmpty
            ? eventId
            : '${event.senderId}|${room.hashCode}|${event.originServerTs.microsecondsSinceEpoch}';
        final ownerKey = _profileUpdateLocalpart(ownerId);
        if (_capturedProfileUpdateEventIds[dedupeKey] == ownerKey) continue;
        _capturedProfileUpdateEventIds[dedupeKey] = ownerKey;
        if (_profileUpdateController.hasListener) {
          _profileUpdateController.add(ownerId);
        } else {
          _pendingProfileUpdates.add(ownerId);
        }
      }
    }
    if (_capturedProfileUpdateEventIds.length > 2048) {
      final recent = _capturedProfileUpdateEventIds.entries.toList().reversed.take(1024);
      _capturedProfileUpdateEventIds
        ..clear()
        ..addEntries(recent.toList().reversed);
    }
  }

  void _captureMatrixDisplayNameChange(MatrixEvent event) {
    if (event.type != 'm.room.member' || event.stateKey == null) return;
    final userId = event.stateKey!.trim();
    if (userId.isEmpty || !event.content.containsKey('displayname')) return;
    final localpart = _profileUpdateLocalpart(userId);
    final observedUserKey = userId.toLowerCase();
    final displayName = event.content['displayname']?.toString() ?? '';
    final previous = _observedMatrixDisplayNames[observedUserKey];
    _observedMatrixDisplayNames[observedUserKey] = displayName;

    // The first sync contains current room state for many users. Only an
    // observed value change should invalidate an already-running profile UI.
    // If this is the first event seen for the user, use Matrix's prev_content
    // when present so a rename during startup is not missed.
    final unsignedPrevious = event.unsigned?['prev_content'];
    final previousEventName =
        unsignedPrevious is Map
            ? unsignedPrevious['displayname']?.toString() ?? ''
            : null;
    final changed =
        previous != null
            ? previous != displayName
            : previousEventName != null && previousEventName != displayName;
    if (!changed) return;
    final eventId = event.eventId.trim();
    final dedupeKey =
        eventId.isNotEmpty
            ? 'matrix-displayname|$eventId'
            : 'matrix-displayname|$localpart|$displayName|${event.originServerTs.microsecondsSinceEpoch}';
    if (_capturedProfileUpdateEventIds.containsKey(dedupeKey)) return;
    _capturedProfileUpdateEventIds[dedupeKey] = localpart;
    if (_profileUpdateController.hasListener) {
      _profileUpdateController.add(userId);
    } else {
      _pendingProfileUpdates.add(userId);
    }
  }

  String _profileUpdateLocalpart(String userId) {
    final value = userId.trim();
    if (value.startsWith('@')) {
      final separator = value.indexOf(':');
      return (separator > 1 ? value.substring(1, separator) : value.substring(1))
          .toLowerCase();
    }
    return value.toLowerCase();
  }

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
      // History is restored explicitly when a conversation is opened. Letting
      // the SDK request it for every limited room during startup creates a
      // second, uncontrolled request wave and trips the homeserver limiter.
      requestHistoryOnLimitedTimeline: false,
      syncFilter: Filter(
        room: RoomFilter(
          state: StateFilter(lazyLoadMembers: true),
          timeline: StateFilter(
            lazyLoadMembers: true,
            // CHANGED: was MatrixConfig.historyPageSize (3000). A sync only
            // needs a few events per room for the conversation preview;
            // asking for 3000 is what made /sync time out.
            limit: MatrixConfig.syncTimelineLimit,
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
    _startEarlyToDeviceCapture(client);
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
    var matrix = await ensureInitialized(storeNamespace: userId);
    if (matrix.isLogged()) {
      if (matrix.userID == userId && matrix.accessToken == accessToken) {
        return;
      }
      await clearLocalSession();
      await disposeCurrentClient();
      matrix = await ensureInitialized(storeNamespace: userId);
    }
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
    await _toDeviceCaptureSub?.cancel();
    _toDeviceCaptureSub = null;
    await _profileUpdateCaptureSub?.cancel();
    _profileUpdateCaptureSub = null;
    _pendingGroupDeletionEvents.clear();
    _pendingProfileUpdates.clear();
    _capturedGroupDeletionKeys.clear();
    _capturedProfileUpdateEventIds.clear();
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
        getApplicationCacheDirectory(),
        getTemporaryDirectory(),
      ]);
      for (final dir in dirs) {
        for (final name in [
          'matrix',
          'matrix_media',
          'matrix_sdk',
          'hive',
          'db',
          'client',
        ]) {
          final child = Directory(p.join(dir.path, name));
          if (await child.exists()) {
            await child.delete(recursive: true);
          }
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
