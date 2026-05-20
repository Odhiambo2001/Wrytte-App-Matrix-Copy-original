import 'dart:async';
import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;

import 'matrix_auth_service.dart';
import 'matrix_client.dart';
import 'matrix_config.dart';

class MatrixChatService {
  MatrixChatService._();
  static final MatrixChatService instance = MatrixChatService._();

  bool _initialSyncComplete = false;
  Future<void>? _syncAndJoinFuture;
  final Map<String, Future<Room>> _directRoomFutures = {};

  Stream<Event> get timelineEvents =>
      MatrixClientService.instance.client.onTimelineEvent.stream;

  Stream<SyncUpdate> get syncStream =>
      MatrixClientService.instance.client.onSync.stream;

  Future<Client> connect() => MatrixAuthService.instance.restore();

  List<Room> get rooms => MatrixClientService.instance.client.rooms;

  Room? getRoomById(String roomId) {
    for (final room in MatrixClientService.instance.client.rooms) {
      if (room.id == roomId) return room;
    }
    return null;
  }

  Future<void> ensureSyncedAndAutoJoinInvites({bool forceSync = false}) {
    _syncAndJoinFuture ??= _ensureSyncedAndAutoJoinInvites(
      forceSync: forceSync,
    );
    return _syncAndJoinFuture!.whenComplete(() => _syncAndJoinFuture = null);
  }

  Future<void> _ensureSyncedAndAutoJoinInvites({bool forceSync = false}) async {
    final client = await connect();
    if (!client.isLogged()) return;

    if (forceSync || !_initialSyncComplete) {
      try {
        final firstSync = client.firstSyncReceived;
        if (firstSync != null) {
          await firstSync.timeout(const Duration(seconds: 8), onTimeout: () {});
        } else {
          await client
              .oneShotSync(timeout: Duration.zero)
              .timeout(const Duration(seconds: 8), onTimeout: () {});
        }
      } catch (_) {
        // The background sync will keep running. We still inspect loaded rooms.
      }
      _initialSyncComplete = true;
    }

    await autoJoinTrustedDirectInvites();
  }

  Future<void> autoJoinTrustedDirectInvites() async {
    final client = MatrixClientService.instance.client;
    if (!client.isLogged()) return;

    final invites =
        client.rooms
            .where((room) => room.membership == Membership.invite)
            .where(_isTrustedDirectInvite)
            .toList();

    for (final room in invites) {
      try {
        await room.join().timeout(const Duration(seconds: 12));
        await client
            .waitForRoomInSync(room.id, join: true)
            .timeout(
              const Duration(seconds: 12),
              onTimeout: () {
                throw TimeoutException(
                  'Timed out waiting for joined room ${room.id}',
                );
              },
            );
      } catch (_) {
        // A failed invite join should not block the chat list or message send.
      }
    }
  }

  Future<Room> getOrCreateDirectRoom(String matrixUserId) async {
    final key = matrixUserId.trim();
    final pending = _directRoomFutures[key];
    if (pending != null) return pending;

    final future = _getOrCreateDirectRoom(key);
    _directRoomFutures[key] = future;
    return future.whenComplete(() => _directRoomFutures.remove(key));
  }

  Future<Room?> findDirectRoom(String matrixUserId) async {
    final client = await connect();
    if (!client.isLogged()) return null;

    await ensureSyncedAndAutoJoinInvites();
    final room = _directRoomFor(matrixUserId.trim(), includeInvite: true);
    if (room == null) return null;
    if (room.membership == Membership.join) return room;
    if (room.membership != Membership.invite) return null;

    try {
      await room.join().timeout(const Duration(seconds: 8));
      await client
          .waitForRoomInSync(room.id, join: true)
          .timeout(
            const Duration(seconds: 8),
            onTimeout:
                () =>
                    throw TimeoutException(
                      'Timed out joining direct room ${room.id}',
                    ),
          );
      return getRoomById(room.id);
    } catch (_) {
      return null;
    }
  }

  Future<Room> _getOrCreateDirectRoom(String matrixUserId) async {
    final client = await connect();
    if (!client.isLogged()) {
      throw StateError('Matrix session is not available.');
    }
    if (matrixUserId == client.userID) {
      throw StateError('Cannot create a direct chat with the current user.');
    }

    await ensureSyncedAndAutoJoinInvites();

    var room = _directRoomFor(matrixUserId, includeInvite: true);
    final inviteRoom = room;
    if (inviteRoom != null && inviteRoom.membership == Membership.invite) {
      await inviteRoom.join().timeout(const Duration(seconds: 12));
      await client
          .waitForRoomInSync(inviteRoom.id, join: true)
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              throw TimeoutException(
                'Timed out joining direct room ${inviteRoom.id}',
              );
            },
          );
      room = getRoomById(inviteRoom.id);
    }
    if (room != null && room.membership == Membership.join) return room;

    // Another path may have joined/created the room while we were syncing.
    room = _directRoomFor(matrixUserId, includeInvite: true);
    if (room != null && room.membership == Membership.join) return room;

    late final String roomId;
    try {
      roomId = await client.startDirectChat(matrixUserId, waitForSync: false);
    } catch (e) {
      if (!_looksLikeAlreadyJoinedRoomError(e)) rethrow;
      await ensureSyncedAndAutoJoinInvites(forceSync: true);
      final createdRoom = _directRoomFor(matrixUserId, includeInvite: true);
      if (createdRoom != null && createdRoom.membership == Membership.join) {
        return createdRoom;
      }
      throw StateError(
        'Matrix direct room was created but could not be resolved.',
      );
    }
    await client
        .waitForRoomInSync(roomId, join: true)
        .timeout(
          const Duration(seconds: 12),
          onTimeout: () {
            throw TimeoutException(
              'Timed out waiting for created room $roomId',
            );
          },
        );

    room = getRoomById(roomId);
    if (room == null) {
      throw StateError('Matrix room $roomId was not available after sync.');
    }
    return room;
  }

  Future<String?> sendText({
    required String roomId,
    required String body,
  }) async {
    final room = getRoomById(roomId);
    if (room == null) throw StateError('Unknown Matrix room: $roomId');
    return room.sendTextEvent(body);
  }

  Future<String?> sendDirectText({
    required String matrixUserId,
    required String body,
  }) async {
    final room = await getOrCreateDirectRoom(matrixUserId);
    return room.sendTextEvent(body);
  }

  Future<String?> sendFile({
    required String roomId,
    required String filePath,
    String? mimeType,
  }) async {
    final room = getRoomById(roomId);
    if (room == null) throw StateError('Unknown Matrix room: $roomId');
    final file = File(filePath);
    final matrixFile = MatrixFile.fromMimeType(
      bytes: await file.readAsBytes(),
      name: p.basename(filePath),
      mimeType: mimeType,
    );
    return room.sendFileEvent(matrixFile);
  }

  Future<Timeline> getTimeline(
    String roomId, {
    int limit = Room.defaultHistoryCount,
    void Function()? onUpdate,
  }) async {
    final room = getRoomById(roomId);
    if (room == null) throw StateError('Unknown Matrix room: $roomId');
    return room.getTimeline(limit: limit, onUpdate: onUpdate);
  }

  Future<void> markRead(String roomId) async {
    final room = getRoomById(roomId);
    final eventId = room?.lastEvent?.eventId;
    if (room == null || eventId == null || eventId.isEmpty) return;
    await MatrixClientService.instance.client.setReadMarker(
      roomId,
      mFullyRead: eventId,
      mRead: eventId,
    );
  }

  Room? _directRoomFor(String matrixUserId, {bool includeInvite = false}) {
    for (final room in MatrixClientService.instance.client.rooms) {
      if (room.directChatMatrixID != matrixUserId) continue;
      if (room.membership == Membership.join) return room;
      if (includeInvite && room.membership == Membership.invite) return room;
    }
    return null;
  }

  bool _isTrustedDirectInvite(Room room) {
    final directUserId = room.directChatMatrixID;
    if (directUserId == null || directUserId.isEmpty) return false;
    final domain = directUserId.split(':').last;
    return domain == MatrixConfig.serverName;
  }

  bool _looksLikeAlreadyJoinedRoomError(Object error) {
    final raw = error.toString().toLowerCase();
    return raw.contains('already joined to room') ||
        raw.contains('m_forbidden');
  }
}
