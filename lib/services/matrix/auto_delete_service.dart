import 'package:flutter/foundation.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';

/// Stores the selected per-room disappearing-message duration in Matrix
/// account data. The value is also read synchronously by the home list from
/// the client's cached account data.
class AutoDeleteService {
  AutoDeleteService._();
  static final instance = AutoDeleteService._();

  static const accountDataType = 'com.wrytte.auto_delete';
  Map<String, dynamic>? _localRooms;
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  String? durationForRoom(String roomId) {
    final value = _rooms()[roomId.trim()];
    final duration = value is Map
        ? value['duration']?.toString().trim()
        : value?.toString().trim();
    return duration == null || duration.isEmpty || duration == 'Off'
        ? null
        : duration;
  }

  DateTime? enabledAtForRoom(String roomId) {
    final value = _rooms()[roomId.trim()];
    if (value is! Map) return null;
    return DateTime.tryParse(value['enabledAt']?.toString() ?? '')?.toLocal();
  }

  Future<void> setDuration(String roomId, String duration) async {
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
    debugPrint('[AutoDelete] updated room="$id" duration="$duration"');
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
