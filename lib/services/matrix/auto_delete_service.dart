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
  final Map<String, Map<String, String>> _lastChanges = {};
  final Map<String, List<Map<String, String>>> _changeHistory = {};
  final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static const _outboxKey = 'wrytte.auto_delete.registration_outbox';
  final Map<String, Map<String, String>> _outbox = {};
  Timer? _retryTimer;
  Future<void>? _outboxLoad;
  Future<void>? _initializeFuture;

  Future<void> initialize() async {
    final existing = _initializeFuture;
    if (existing != null) return existing;
    final future = _initializeInternal();
    _initializeFuture = future;
    return future;
  }

  Future<void> _initializeInternal() async {
    await _ensureOutboxLoaded();
    await _loadChangeHistory();
    changes.value++;
    if (_outbox.isNotEmpty) unawaited(_retryOutbox());
  }

  List<Map<String, String>> changesForRoom(String roomId) {
    final id = roomId.trim();
    final values = _changeHistory[id] ?? const <Map<String, String>>[];
    return List<Map<String, String>>.unmodifiable(
      values.map((value) => Map<String, String>.from(value)),
    );
  }

  String? durationForRoom(String roomId) {
    final id = roomId.trim();
    final value = _rooms()[id] ?? _roomState(id);
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
    final id = roomId.trim();
    final localValue = _rooms()[id];
    DateTime? parse(dynamic value) {
      if (value is! Map) return null;
      return DateTime.tryParse(
        (value['enabledAt'] ?? value['enabled_at'])?.toString() ?? '',
      )?.toLocal();
    }
    return parse(localValue) ?? parse(_roomState(id));
  }

  String? enabledByForRoom(String roomId) {
    final id = roomId.trim();
    final localValue = _rooms()[id];
    // Room state is authoritative because account data is user-local and can
    // contain the receiving user's old local fallback value.
    final value = _roomState(id) ?? localValue;
    if (value is! Map) return null;
    final sender = value['enabledBy']?.toString().trim();
    return sender == null || sender.isEmpty ? null : sender;
  }

  /// The disappearing-message icon is local UI state: only the user who
  /// enabled the timer should see it. The timer itself remains shared so the
  /// other participant can still render the remote notification and expire
  /// messages correctly.
  bool showIconForRoom(String roomId) {
    final currentUserId = MatrixClientService.instance.client.userID?.trim();
    final enabledBy = enabledByForRoom(roomId)?.trim();
    if (currentUserId == null || currentUserId.isEmpty ||
        enabledBy == null || enabledBy.isEmpty) {
      return false;
    }
    return durationForRoom(roomId) != null &&
        _matrixLocalpart(enabledBy) == _matrixLocalpart(currentUserId);
  }

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':')).toLowerCase();
    }
    return trimmed.toLowerCase();
  }

  Map<String, String>? lastChangeForRoom(String roomId) {
    final id = roomId.trim();
    final change = _lastChanges[id] ?? _roomState(id);
    if (change == null) return null;
    return change.map(
      (key, value) => MapEntry(key, value?.toString() ?? ''),
    );
  }

  Future<void> setDuration(
    String roomId,
    String duration, {
    bool broadcast = true,
    String? enabledBy,
    DateTime? changedAt,
    bool recordHistory = true,
  }) async {
    final id = roomId.trim();
    final client = MatrixClientService.instance.client;
    final userId = client.userID;
    if (id.isEmpty || userId == null || userId.isEmpty) return;

    final effectiveChangedAt = (changedAt ?? DateTime.now()).toUtc();
    final change = <String, String>{
      'duration': duration,
      'enabledBy': enabledBy ?? userId,
      'changedAt': effectiveChangedAt.toIso8601String(),
    };
    _lastChanges[id] = change;
    if (recordHistory) await _appendChange(id, change);

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
      await client.setRoomStateWithKey(id, roomEventType, '', {
        'room_id': id,
        'duration': duration == 'Off' ? null : duration,
        'enabled_at': duration == 'Off'
            ? null
            : (rooms[id] is Map ? rooms[id]['enabledAt'] : null),
        'changed_at': change['changedAt'],
        'sender': userId,
      });
      await room.sendEvent({
        'room_id': id,
        'duration': duration == 'Off' ? null : duration,
        'enabled_at': duration == 'Off'
            ? null
            : (rooms[id] is Map ? rooms[id]['enabledAt'] : null),
        'changed_at': change['changedAt'],
        'sender': userId,
      }, type: roomEventType);
    }
    debugPrint('[AutoDelete] updated room="$id" duration="$duration"');
  }

  Future<void> applyRemoteEvent(
    String roomId,
    Map<String, dynamic> content,
    {String? senderId, DateTime? changedAt}
  ) async {
    final id = roomId.trim();
    if (id.isEmpty) return;
    final duration = content['duration']?.toString() ?? 'Off';
    final enabledBy = senderId ?? content['sender']?.toString() ?? '';
    final eventChangedAt = changedAt ??
        DateTime.tryParse(content['changed_at']?.toString() ?? '') ??
        DateTime.now();
    final enabledAt = DateTime.tryParse(
      content['enabled_at']?.toString() ?? '',
    );
    final change = <String, String>{
      'duration': duration,
      'enabledBy': enabledBy,
      'changedAt': eventChangedAt.toUtc().toIso8601String(),
      if (enabledAt != null) 'enabledAt': enabledAt.toUtc().toIso8601String(),
    };
    _lastChanges[id] = change;
    final rooms = _rooms();
    if (duration == 'Off') {
      rooms.remove(id);
    } else {
      rooms[id] = {
        'duration': duration,
        'enabledAt':
            (enabledAt ?? eventChangedAt).toUtc().toIso8601String(),
        'enabledBy': enabledBy,
      };
    }
    _localRooms = rooms;
    await _appendChange(id, change);
    changes.value++;
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

  static const _historyKey = 'wrytte.auto_delete.change_history';

  Future<void> _loadChangeHistory() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_historyKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final item in decoded.entries) {
        final values = item.value;
        if (values is! List) continue;
        _changeHistory[item.key.toString()] = values
            .whereType<Map>()
            .map((value) => value.map(
                  (key, entry) => MapEntry(key.toString(), entry.toString()),
                ))
            .map((value) => Map<String, String>.from(value))
            .toList();
      }
    } catch (error) {
      debugPrint('[AutoDelete] change history load failed: $error');
    }
  }

  Future<void> _appendChange(
    String roomId,
    Map<String, String> change,
  ) async {
    final history = _changeHistory.putIfAbsent(roomId, () => <Map<String, String>>[]);
    final timestamp = change['changedAt'] ?? '';
    final duplicate = history.any(
      (entry) =>
          entry['duration'] == change['duration'] &&
          entry['enabledBy'] == change['enabledBy'] &&
          entry['changedAt'] == timestamp,
    );
    if (duplicate) return;
    history.add(Map<String, String>.from(change));
    history.sort(
      (a, b) => (a['changedAt'] ?? '').compareTo(b['changedAt'] ?? ''),
    );
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _historyKey,
      jsonEncode(_changeHistory),
    );
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

  Map<String, dynamic>? _roomState(String roomId) {
    final room = MatrixClientService.instance.client.getRoomById(roomId);
    final state = room?.getState(roomEventType)?.content;
    if (state == null || state.isEmpty) return null;
    final duration = state['duration']?.toString().trim();
    return {
      'duration': duration == null || duration.isEmpty ? 'Off' : duration,
      'enabledAt': state['enabled_at'],
      'enabledBy': state['sender'],
    };
  }
}
