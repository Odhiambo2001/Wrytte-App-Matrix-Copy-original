import 'dart:async';
import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;

import 'matrix_auth_service.dart';
import 'matrix_client.dart';
import 'matrix_config.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

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

    final invitedRooms =
        client.rooms
            .where((room) => room.membership == Membership.invite)
            .toList();

    apkLog(
      'Matrix.join',
      'checking invites count=${invitedRooms.length} user_id="${client.userID}"',
    );

    final invites = invitedRooms.where(_isTrustedDirectInvite).toList();

    for (final room in invites) {
      try {
        apkLog(
          'Matrix.join',
          'joining invite room_id="${room.id}" directUser="${room.directChatMatrixID}" user_id="${client.userID}"',
        );
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
        apkLog(
          'Matrix.join',
          'joined invite room_id="${room.id}" user_id="${client.userID}"',
        );
      } catch (_) {
        apkLog(
          'Matrix.join',
          'join invite failed room_id="${room.id}" user_id="${client.userID}"',
        );
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
    apkLog(
      'Matrix.createRoom',
      'session userID="${client.userID}" serverName="${MatrixConfig.serverName}" target="$matrixUserId"',
    );
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
      apkLog(
        'Matrix.join',
        'joining invited direct room room_id="${inviteRoom.id}" user_id="${client.userID}" target="$matrixUserId"',
      );
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
    if (room != null && room.membership == Membership.join) {
      apkLog(
        'Matrix.createRoom',
        'reusing joined direct room room_id="${room.id}" user_id="${client.userID}" target="$matrixUserId"',
      );
      return room;
    }

    // Another path may have joined/created the room while we were syncing.
    room = _directRoomFor(matrixUserId, includeInvite: true);
    if (room != null && room.membership == Membership.join) {
      apkLog(
        'Matrix.createRoom',
        'reusing joined direct room room_id="${room.id}" user_id="${client.userID}" target="$matrixUserId"',
      );
      return room;
    }

    late final String roomId;
    try {
      apkLog(
        'Matrix.createRoom',
        'POST /_matrix/client/r0/createRoom user_id="${client.userID}" invite=["$matrixUserId"] is_direct=true target="$matrixUserId"',
      );
      roomId = await client.startDirectChat(matrixUserId, waitForSync: false);
      apkLog(
        'Matrix.createRoom',
        'Creating new room roomID="$roomId" userID="${client.userID}" target="$matrixUserId"',
      );
    } catch (e) {
      apkLog(
        'Matrix.createRoom',
        'createRoom failed user_id="${client.userID}" target="$matrixUserId" error="$e"',
      );
      if (!_looksLikeAlreadyJoinedRoomError(e)) rethrow;
      await ensureSyncedAndAutoJoinInvites(forceSync: true);
      final createdRoom = _directRoomFor(matrixUserId, includeInvite: true);
      if (createdRoom != null && createdRoom.membership == Membership.join) {
        apkLog(
          'Matrix.createRoom',
          'resolved already-joined room room_id="${createdRoom.id}" user_id="${client.userID}" target="$matrixUserId"',
        );
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
    await _ensureDirectPeerInvited(room, matrixUserId);
    apkLog(
      'Matrix.createRoom',
      'room ready room_id="${room.id}" roomID="$roomId" user_id="${client.userID}" target="$matrixUserId"',
    );
    return room;
  }

  Future<String?> sendText({
    required String roomId,
    required String body,
  }) async {
    final room = getRoomById(roomId);
    if (room == null) throw StateError('Unknown Matrix room: $roomId');
    final eventId = await room.sendTextEvent(body);
    apkLog(
      'Matrix.send',
      'Sent event to roomserver event_id="$eventId" room_id="$roomId" user_id="${MatrixClientService.instance.client.userID}" type="m.room.message"',
    );
    return eventId;
  }

  Future<void> ensurePeerInvited({
    required String roomId,
    required String matrixUserId,
  }) async {
    final room = getRoomById(roomId);
    if (room == null) throw StateError('Unknown Matrix room: $roomId');
    await _ensureDirectPeerInvited(room, matrixUserId);
  }

  Future<String?> sendDirectText({
    required String matrixUserId,
    required String body,
  }) async {
    final room = await getOrCreateDirectRoom(matrixUserId);
    final eventId = await room.sendTextEvent(body);
    apkLog(
      'Matrix.send',
      'Sent event to roomserver event_id="$eventId" room_id="${room.id}" user_id="${MatrixClientService.instance.client.userID}" type="m.room.message"',
    );
    return eventId;
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
    if (directUserId == null || directUserId.isEmpty) {
      final trustedRoomServer =
          room.id.split(':').last == MatrixConfig.serverName;
      apkLog(
        'Matrix.join',
        'invite trust fallback room_id="${room.id}" directUser=null trustedRoomServer=$trustedRoomServer',
      );
      return trustedRoomServer;
    }
    final domain = directUserId.split(':').last;
    final trusted = domain == MatrixConfig.serverName;
    apkLog(
      'Matrix.join',
      'invite trust check room_id="${room.id}" directUser="$directUserId" trusted=$trusted',
    );
    return trusted;
  }

  bool _looksLikeAlreadyJoinedRoomError(Object error) {
    final raw = error.toString().toLowerCase();
    return raw.contains('already joined to room') ||
        raw.contains('m_forbidden');
  }

  Future<void> _ensureDirectPeerInvited(Room room, String matrixUserId) async {
    final participants = room.getParticipants([
      Membership.join,
      Membership.invite,
    ]);
    User? peer;
    for (final participant in participants) {
      if (participant.id == matrixUserId) {
        peer = participant;
        break;
      }
    }
    if (peer != null) {
      apkLog(
        'Matrix.invite',
        'peer present room_id="${room.id}" target="$matrixUserId" membership="${peer.membership.name}"',
      );
      return;
    }

    apkLog(
      'Matrix.invite',
      'peer missing after createRoom; POST /_matrix/client/v3/rooms/${room.id}/invite target="$matrixUserId"',
    );
    try {
      await room.invite(matrixUserId).timeout(const Duration(seconds: 12));
      apkLog(
        'Matrix.invite',
        'invite sent room_id="${room.id}" target="$matrixUserId"',
      );
    } catch (e) {
      apkLog(
        'Matrix.invite',
        'invite failed room_id="${room.id}" target="$matrixUserId" error="$e"',
      );
      rethrow;
    }
  }
}
