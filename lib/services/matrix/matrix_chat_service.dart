import 'dart:async';
import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;

import 'matrix_auth_service.dart';
import 'matrix_client.dart';

class MatrixChatService {
  MatrixChatService._();
  static final MatrixChatService instance = MatrixChatService._();

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

  Future<Room> getOrCreateDirectRoom(String matrixUserId) async {
    final client = await connect();
    final roomId = await client.startDirectChat(matrixUserId);
    await client.waitForRoomInSync(roomId, join: true);
    final room = getRoomById(roomId);
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
}
