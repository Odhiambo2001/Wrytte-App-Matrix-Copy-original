import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores the selected per-room disappearing-message duration in Matrix
/// account data. The value is also read synchronously by the home list from
/// the client's cached account data.
class AutoDeleteService {
  AutoDeleteService._();
  static final instance = AutoDeleteService._();

  static const accountDataType = 'com.wrytte.auto_delete';
  static const roomEventType = 'com.wrytte.auto_delete';
  static const registerPath = '/api/matrix/auto-delete/register';
  Map<String, dynamic>? _localRooms;
  final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static const _outboxKey = 'wrytte.auto_delete.registration_outbox';
  final Map<String, Map<String, String>> _outbox = {};
  Timer? _retryTimer;
  Future<void>? _outboxLoad;

  Future<void> initialize() async {
    await _ensureOutboxLoaded();
    if (_outbox.isNotEmpty) unawaited(_retryOutbox());
  }

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

  String? enabledByForRoom(String roomId) {
    final value = _rooms()[roomId.trim()];
    if (value is! Map) return null;
    final sender = value['enabledBy']?.toString().trim();
    return sender == null || sender.isEmpty ? null : sender;
  }

  Future<void> setDuration(
    String roomId,
    String duration, {
    bool broadcast = true,
    String? enabledBy,
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
        'enabledBy': enabledBy ?? userId,
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
    {String? senderId}
  ) async {
    final duration = content['duration']?.toString() ?? 'Off';
    await setDuration(
      roomId,
      duration,
      broadcast: false,
      enabledBy: senderId ?? content['sender']?.toString(),
    );
    debugPrint('[AutoDelete] remote event applied room="$roomId" duration="$duration"');
  }

  /// Registers a sent Matrix event with the server-side expiry worker.
  ///
  /// This is deliberately best-effort: sending a message must not fail just
  /// because the module is temporarily unavailable. The message remains in
  /// Matrix and can be retried by the caller or a future outbox.
  Future<void> registerMessage({
    required String roomId,
    required String eventId,
  }) async {
    final duration = durationForRoom(roomId);
    final client = MatrixClientService.instance.client;
    final matrixToken = client.accessToken;
    final backendToken = await AuthService.instance.getValidBackendToken();
    if (duration == null || matrixToken == null || matrixToken.isEmpty ||
        backendToken == null || backendToken.isEmpty) return;

    final timerMs = _durationToMilliseconds(duration);
    if (timerMs == null || timerMs <= 0) {
      debugPrint('[AutoDelete] unsupported duration="$duration"');
      return;
    }

    final key = '$roomId|$eventId';
    await _ensureOutboxLoaded();
    _outbox[key] = {'room_id': roomId, 'event_id': eventId};
    await _saveOutbox();
    _startRetryTimer();
    await _attemptRegistration(key, backendToken, matrixToken, timerMs);
  }

  Future<void> _attemptRegistration(
    String key,
    String backendToken,
    String matrixToken,
    int timerMs,
  ) async {
    final item = _outbox[key];
    if (item == null) return;
    final roomId = item['room_id']!;
    final eventId = item['event_id']!;
    try {
      await ApiService.postJson(
            registerPath,
            token: backendToken,
            body: {
              'room_id': roomId,
              'event_id': eventId,
              'timer_ms': timerMs,
              'matrix_access_token': matrixToken,
            },
          );
      _outbox.remove(key);
      await _saveOutbox();
      debugPrint(
        '[AutoDelete] registered room="$roomId" event="$eventId" '
        'timer_ms=$timerMs',
      );
    } catch (error) {
      debugPrint(
        '[AutoDelete] registration unavailable room="$roomId" '
        'event="$eventId" error=$error',
      );
    }
  }

  Future<void> _retryOutbox() async {
    await _ensureOutboxLoaded();
    final client = MatrixClientService.instance.client;
    final matrixToken = client.accessToken;
    final backendToken = await AuthService.instance.getValidBackendToken();
    if (matrixToken == null || matrixToken.isEmpty ||
        backendToken == null || backendToken.isEmpty) return;
    for (final key in List<String>.of(_outbox.keys)) {
      final roomId = _outbox[key]!['room_id']!;
      final duration = durationForRoom(roomId);
      final timerMs = duration == null ? null : _durationToMilliseconds(duration);
      if (timerMs == null || timerMs <= 0) {
        _outbox.remove(key);
        continue;
      }
      await _attemptRegistration(key, backendToken, matrixToken, timerMs);
    }
    await _saveOutbox();
    if (_outbox.isEmpty) _retryTimer?.cancel();
  }

  void _startRetryTimer() {
    _retryTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_retryOutbox());
    });
  }

  Future<void> _ensureOutboxLoaded() {
    return _outboxLoad ??= _loadOutbox();
  }

  Future<void> _loadOutbox() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_outboxKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is Map && item['room_id'] is String && item['event_id'] is String) {
          final roomId = item['room_id'] as String;
          final eventId = item['event_id'] as String;
          _outbox['$roomId|$eventId'] = {
            'room_id': roomId,
            'event_id': eventId,
          };
        }
      }
      if (_outbox.isNotEmpty) _startRetryTimer();
    } catch (error) {
      debugPrint('[AutoDelete] invalid registration outbox: $error');
    }
  }

  Future<void> _saveOutbox() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_outboxKey, jsonEncode(_outbox.values.toList()));
  }

  int? _durationToMilliseconds(String value) {
    final normalized = value.trim().toLowerCase();
    final match = RegExp(
      r'^(\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w)$',
    )
        .firstMatch(normalized);
    if (match == null) return null;
    final amount = double.tryParse(match.group(1)!);
    if (amount == null) return null;
    final unit = match.group(2)!;
    final multiplier = switch (unit) {
      'm' || 'min' || 'mins' || 'minute' || 'minutes' => 60 * 1000,
      'h' || 'hr' || 'hrs' || 'hour' || 'hours' => 60 * 60 * 1000,
      'd' || 'day' || 'days' => 24 * 60 * 60 * 1000,
      'w' || 'week' || 'weeks' => 7 * 24 * 60 * 60 * 1000,
      _ => 0,
    };
    return (amount * multiplier).round();
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
