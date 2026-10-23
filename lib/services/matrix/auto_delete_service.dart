import 'package:flutter/foundation.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';

/// Stores the selected per-room disappearing-message duration in Matrix
/// account data. The value is also read synchronously by the home list from
/// the client's cached account data.
class AutoDeleteService {
  AutoDeleteService._();
  static final instance = AutoDeleteService._();

  static const accountDataType = 'com.wrytte.auto_delete';
  static const roomEventType = 'com.wrytte.auto_delete';
  Map<String, dynamic>? _localRooms;
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  String? durationForRoom(String roomId) {
    final value = _rooms()[roomId.trim()];
    var duration = value is Map
        ? value['duration']?.toString().trim()
        : value?.toString().trim();
    // Recover values written by older builds as a Dart map string.
    if (duration != null && duration.startsWith('{duration:')) {
      final match = RegExp(r'^\{duration:\s*([^,}]+)').firstMatch(duration);
      duration = match?.group(1)?.trim();
    }
    return duration == null || duration.isEmpty || duration == 'Off'
        ? null
        : duration;
  }

  DateTime? enabledAtForRoom(String roomId) {
    final value = _rooms()[roomId.trim()];
    if (value is! Map) return null;
    return DateTime.tryParse(value['enabledAt']?.toString() ?? '')?.toLocal();
  }

  Future<void> setDuration(
    String roomId,
    String duration, {
    bool broadcast = true,
  }) async {
    final id = roomId.trim();
    final client = MatrixClientService.instance.client;
    final userId = client.userID;
    if (id.isEmpty || userId == null || userId.isEmpty) return;

    final rooms = _rooms();
    if (duration == 'Off') {
      rooms.remove(id);
    } else {
      rooms[id] = {
        'duration': duration,
        'enabledAt': DateTime.now().toUtc().toIso8601String(),
      };
    }
    await client.setAccountData(userId, accountDataType, {'rooms': rooms});
    _localRooms = rooms;
    changes.value++;
    final room = client.getRoomById(id);
    if (broadcast && room != null) {
      await room.sendEvent({
        'room_id': id,
        'duration': duration == 'Off' ? null : duration,
        'enabled_at': duration == 'Off'
            ? null
            : (rooms[id] is Map ? rooms[id]['enabledAt'] : null),
        'sender': userId,
      }, type: roomEventType);
    }
    debugPrint('[AutoDelete] updated room="$id" duration="$duration"');
  }

  Future<void> applyRemoteEvent(
    String roomId,
    Map<String, dynamic> content,
  ) async {
    final duration = content['duration']?.toString() ?? 'Off';
    await setDuration(roomId, duration, broadcast: false);
    debugPrint('[AutoDelete] remote event applied room="$roomId" duration="$duration"');
  }

  Map<String, dynamic> _rooms() {
    if (_localRooms != null) return Map<String, dynamic>.from(_localRooms!);
    final event = MatrixClientService.instance.client.accountData[accountDataType];
    final raw = event?.content['rooms'];
    if (raw is! Map) return <String, dynamic>{};
    _localRooms = Map<String, dynamic>.from(raw);
    return Map<String, dynamic>.from(_localRooms!);
  }
}
