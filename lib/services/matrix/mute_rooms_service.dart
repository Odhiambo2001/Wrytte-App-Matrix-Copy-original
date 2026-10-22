import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';

/// Persists per-room mute state in private Matrix account data.
class MuteRoomsService {
  MuteRoomsService._();
  static final instance = MuteRoomsService._();

  static const accountDataType = 'mute_rooms';
  Future<void> _writeQueue = Future<void>.value();
  Map<String, dynamic>? _localRooms;

  Future<void> mute(String roomId, Duration duration) {
    final until = DateTime.now().toUtc().add(duration);
    return _enqueue(() => _write(roomId, until));
  }

  Future<void> muteForever(String roomId) =>
      _enqueue(() => _write(roomId, null));

  Future<void> unmute(String roomId) => _enqueue(() => _write(roomId, null, remove: true));

  Future<bool> isMuted(String roomId) async {
    final id = roomId.trim();
    if (id.isEmpty || !MatrixClientService.instance.isInitialized) return false;
    final rooms = _roomsFromAccountData();
    final raw = rooms[id];
    if (raw == null) return false;
    final until = DateTime.tryParse(raw.toString());
    if (until == null || until.isAfter(DateTime.now().toUtc())) return true;
    await unmute(id);
    return false;
  }

  Future<void> _write(String roomId, DateTime? until, {bool remove = false}) async {
    final id = roomId.trim();
    final client = MatrixClientService.instance.client;
    final userId = client.userID;
    if (id.isEmpty || userId == null || userId.isEmpty) return;
    final rooms = _roomsFromAccountData();
    if (remove) {
      rooms.remove(id);
    } else {
      rooms[id] = until?.toIso8601String() ?? 'forever';
    }
    await client.setAccountData(userId, accountDataType, {'rooms': rooms});
    _localRooms = rooms;
    debugPrint('[MuteRooms] updated room="$id" muted=${!remove}');
  }

  Map<String, dynamic> _roomsFromAccountData() {
    if (_localRooms != null) return Map<String, dynamic>.from(_localRooms!);
    final event = MatrixClientService.instance.client.accountData[accountDataType];
    final raw = event?.content['rooms'];
    if (raw is! Map) return <String, dynamic>{};
    final rooms = Map<String, dynamic>.from(raw);
    _localRooms = rooms;
    return Map<String, dynamic>.from(rooms);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _writeQueue.then((_) => operation());
    _writeQueue = next.catchError((Object error, StackTrace stack) {
      debugPrint('[MuteRooms] account data update failed: $error');
    });
    return next;
  }
}
