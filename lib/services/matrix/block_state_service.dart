import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;

import 'package:wrytte/services/matrix/matrix_client.dart';

/// Frontend-side block state and account-data contract.
///
/// The server remains authoritative, but this service gives every FE entry
/// point the same BLOCKLIST, BBB, and BLOCKEDMSG representation.
class BlockStateService {
  BlockStateService._();
  static final BlockStateService instance = BlockStateService._();

  static const blocklistType = 'com.wrytte.blocklist';
  static const bbbType = 'com.wrytte.bbb';
  static const blockedMessagesType = 'com.wrytte.blockedmsg';
  static const blockedEventType = 'com.wrytte.user.blocked';
  static const unblockedEventType = 'com.wrytte.user.unblocked';

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  Map<String, dynamic> _blocklist = <String, dynamic>{};
  Map<String, dynamic> _bbb = <String, dynamic>{};
  Map<String, dynamic> _blockedMessages = <String, dynamic>{};
  Future<void> _writeQueue = Future<void>.value();

  mx.Client get _client => MatrixClientService.instance.client;

  Future<void> load() async {
    try {
      _blocklist = _content(blocklistType);
      _bbb = _content(bbbType);
      _blockedMessages = _content(blockedMessagesType);
      revision.value++;
    } catch (error) {
      debugPrint('[BlockState] load failed error=$error');
    }
  }

  void handleSyncUpdate(mx.SyncUpdate update) {
    if (update.accountData?.any(
          (event) => event.type == blocklistType ||
              event.type == bbbType ||
              event.type == blockedMessagesType,
        ) ??
        false) {
      unawaited(load());
    }
    for (final entry in
        update.rooms?.join?.entries ??
        const <String, mx.JoinedRoomUpdate>{}.entries) {
      final roomId = entry.key;
      for (final event in entry.value.timeline?.events ?? const <mx.MatrixEvent>[]) {
        if (event.type == blockedEventType) {
          unawaited(recordBlockedBy({
            'blocked_by': event.senderId,
            'blocked_user_id': _client.userID,
            'room_id': roomId,
            'blocked_at': event.content['timestamp']?.toString() ??
                event.originServerTs.toUtc().toIso8601String(),
          }));
        } else if (event.type == unblockedEventType) {
          unawaited(removeBlockedBy(
            blockedBy: event.senderId,
            roomId: roomId,
          ));
        }
      }
    }
  }

  bool isRoomBlocked(String roomId, {String? peerId}) {
    final room = roomId.trim();
    final peer = peerId?.trim();
    return _entries(_blocklist).any((entry) {
      return entry['room_id']?.toString() == room ||
          (peer != null && entry['user_id']?.toString() == peer);
    }) ||
        _entries(_bbb).any((entry) {
          return entry['room_id']?.toString() == room ||
              (peer != null && entry['blocked_by']?.toString() == peer);
        });
  }

  bool isBlocklisted(String roomId, {String? peerId}) {
    final room = roomId.trim();
    final peer = peerId?.trim();
    return _entries(_blocklist).any((entry) {
      return (room.isNotEmpty && entry['room_id']?.toString() == room) ||
          (peer != null && peer.isNotEmpty && entry['user_id']?.toString() == peer);
    });
  }

  bool isBlockedByBbb(String userId, {String? roomId}) {
    final peer = userId.trim();
    final room = roomId?.trim() ?? '';
    if (peer.isEmpty) return false;
    String localpart(String value) {
      final normalized = value.trim().toLowerCase();
      final withoutAt = normalized.startsWith('@')
          ? normalized.substring(1)
          : normalized;
      final separator = withoutAt.indexOf(':');
      return separator == -1 ? withoutAt : withoutAt.substring(0, separator);
    }
    final target = localpart(peer);
    return _entries(_bbb).any((entry) {
      final blockedBy = localpart(entry['blocked_by']?.toString() ?? '');
      final entryRoom = entry['room_id']?.toString().trim() ?? '';
      return blockedBy == target && (room.isEmpty || entryRoom == room);
    });
  }

  bool isBlockedBy(String userId, {String? roomId}) => isRoomBlocked(
    roomId ?? '',
    peerId: userId,
  );

  List<Map<String, dynamic>> get blocklist => _entries(_blocklist);
  List<Map<String, dynamic>> get bbb => _entries(_bbb);
  List<Map<String, dynamic>> get blockedMessages => _entries(_blockedMessages);

  Future<void> addBlock({required String userId, required String roomId}) async {
    await _update(blocklistType, _blocklist, (entries) {
      entries.removeWhere((e) => e['user_id'] == userId || e['room_id'] == roomId);
      entries.add({
        'user_id': userId,
        'room_id': roomId,
        'blocked_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    await _sendRoomNotice(roomId, blockedEventType, {
      'blocked_by': _client.userID,
      'blocked_user_id': userId,
      'room_id': roomId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> removeBlock({required String userId, required String roomId}) async {
    await _update(blocklistType, _blocklist, (entries) {
      entries.removeWhere((e) => e['user_id'] == userId || e['room_id'] == roomId);
    });
    await _sendRoomNotice(roomId, unblockedEventType, {
      'blocked_by': _client.userID,
      'blocked_user_id': userId,
      'room_id': roomId,
    });
  }

  Future<void> recordBlockedBy(Map<String, dynamic> entry) async {
    await _update(bbbType, _bbb, (entries) {
      entries.removeWhere((e) =>
          e['blocked_by'] == entry['blocked_by'] &&
          e['room_id'] == entry['room_id']);
      entries.add(entry);
    });
  }

  Future<void> removeBlockedBy({required String blockedBy, required String roomId}) async {
    await _update(bbbType, _bbb, (entries) {
      entries.removeWhere((e) =>
          e['blocked_by'] == blockedBy && e['room_id'] == roomId);
    });
  }

  Future<void> recordBlockedMessage({
    required String roomId,
    required String eventId,
    required String text,
    required DateTime time,
  }) async {
    await _update(blockedMessagesType, _blockedMessages, (entries) {
      final nextSequence = entries.fold<int>(0, (max, entry) {
        final value = entry['sequence'];
        final sequence = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
        return sequence > max ? sequence : max;
      }) + 1;
      entries.add({
        'room_id': roomId,
        'event_id': eventId,
        'blocked_message_id': 'blocked_$nextSequence',
        'text': text,
        'time': time.toUtc().toIso8601String(),
        'sequence': nextSequence,
        'status': 'sent',
        'recovery_status': 'pending',
      });
    });
  }

  Map<String, dynamic> _content(String type) => Map<String, dynamic>.from(
      _client.accountData[type]?.content ?? const <String, dynamic>{});

  List<Map<String, dynamic>> _entries(Map<String, dynamic> content) {
    final raw = content['entries'];
    if (raw is! Iterable) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  Future<void> _update(
    String type,
    Map<String, dynamic> current,
    void Function(List<Map<String, dynamic>>) change,
  ) async {
    final userId = _client.userID;
    if (userId == null || userId.isEmpty) return;
    final previous = _writeQueue;
    final write = previous.then((_) async {
      final source = type == blocklistType
          ? _blocklist
          : type == bbbType
              ? _bbb
              : _blockedMessages;
      final entries = _entries(source.isEmpty ? current : source);
      change(entries);
      final next = <String, dynamic>{'entries': entries};
      await _client.setAccountData(userId, type, next);
      if (type == blocklistType) _blocklist = next;
      if (type == bbbType) _bbb = next;
      if (type == blockedMessagesType) _blockedMessages = next;
      revision.value++;
    });
    _writeQueue = write.catchError((Object error) {
      debugPrint('[BlockState] account data update failed type=$type error=$error');
    });
    await write;
  }

  Future<void> _sendRoomNotice(
    String roomId,
    String type,
    Map<String, dynamic> content,
  ) async {
    try {
      final room = _client.getRoomById(roomId);
      if (room != null) await room.sendEvent(content, type: type);
    } catch (error) {
      debugPrint('[BlockState] event failed type=$type error=$error');
    }
  }
}
