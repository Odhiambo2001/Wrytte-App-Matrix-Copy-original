import 'dart:async';
import 'dart:convert';

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
  final StreamController<({String blockedBy, String roomId})>
  _unblockController =
      StreamController<({String blockedBy, String roomId})>.broadcast();
  Map<String, dynamic> _blocklist = <String, dynamic>{};
  Map<String, dynamic> _bbb = <String, dynamic>{};
  Map<String, dynamic> _blockedMessages = <String, dynamic>{};
  final Map<String, Map<String, dynamic>> _optimisticBlocks =
      <String, Map<String, dynamic>>{};
  final Set<String> _optimisticUnblocks = <String>{};
  Future<void> _writeQueue = Future<void>.value();
  Future<void>? _eventBackfill;
  Future<void>? _loadInFlight;
  Future<void> _eventApplyQueue = Future<void>.value();
  bool _eventBackfillCompleted = false;
  bool _ready = false;
  final Map<String, DateTime> _profileUnblockedAt = <String, DateTime>{};

  mx.Client get _client => MatrixClientService.instance.client;

  Stream<({String blockedBy, String roomId})> get unblockStream =>
      _unblockController.stream;

  bool get isReady => _ready;

  Future<void> load() async {
    final existing = _loadInFlight;
    if (existing != null) return existing;
    final request = _loadInternal();
    _loadInFlight = request;
    return request.whenComplete(() => _loadInFlight = null);
  }

  Future<void> _loadInternal() async {
    try {
      // Account data exposed by the SDK can lag behind a local write. Only
      // hydrate BBB from it during the initial load; later sync notifications
      // must not replace the authoritative in-memory state with that stale
      // snapshot while event backfill is still running.
      final storedBlocklist = _content(blocklistType);
      _blocklist = _sanitizeBlocklist(storedBlocklist);
      if (_entries(storedBlocklist).length != _entries(_blocklist).length) {
        // Migrate stale self-block records produced by the old flow instead
        // of merely hiding them in memory; otherwise they return on the next
        // sync/login and can corrupt directional block decisions again.
        await _update(blocklistType, _blocklist, (entries) {
          entries.removeWhere(
            (entry) => _sameUser(
              entry['user_id']?.toString() ?? '',
              _client.userID?.toString() ?? '',
            ),
          );
        });
      }
      // Matrix account-data can briefly return a stale snapshot after a
      // successful write. Preserve explicit local block/unblock decisions
      // until the server catches up or the user changes the decision again.
      final loadedBlocks = _entries(_blocklist);
      loadedBlocks.removeWhere((entry) {
        final key = _blockKey(
          entry['user_id']?.toString() ?? '',
          entry['room_id']?.toString() ?? '',
        );
        return _optimisticUnblocks.contains(key);
      });
      for (final entry in _optimisticBlocks.values) {
        loadedBlocks.removeWhere(
          (existing) =>
              existing['user_id'] == entry['user_id'] ||
              existing['room_id'] == entry['room_id'],
        );
        loadedBlocks.add(entry);
      }
      _blocklist = <String, dynamic>{'entries': loadedBlocks};
      if (!_ready) {
        _bbb = _sanitizeBbb(_content(bbbType));
      }
      _blockedMessages = _content(blockedMessagesType);
      if (!_eventBackfillCompleted) {
        await _backfillBlockEvents();
      }
      _ready = true;
      revision.value++;
      debugPrint(
        '[BlockState][DIAG] load done ready=$_ready '
        'self="${_client.userID}" '
        'bbb=${_entries(_bbb)} blocklist=${_entries(_blocklist)}',
      );
    } catch (error) {
      debugPrint('[BlockState] load failed error=$error');
    }
  }

  Future<void> _backfillBlockEvents() {
    final existing = _eventBackfill;
    if (existing != null) return existing;
    final request = _backfillBlockEventsInternal();
    _eventBackfill = request;
    return request.whenComplete(() => _eventBackfill = null);
  }

  Future<void> _backfillBlockEventsInternal() async {
    final userId = _client.userID;
    if (userId == null || userId.isEmpty) return;

    final filter = jsonEncode(
      mx.StateFilter(
        types: [blockedEventType, unblockedEventType],
        lazyLoadMembers: true,
      ).toJson(),
    );

    final latestByRoom = <String, mx.MatrixEvent>{};
    for (final room in List<mx.Room>.from(_client.rooms)) {
      try {
        final response = await _client.getRoomEvents(
          room.id,
          mx.Direction.b,
          limit: 100,
          filter: filter,
        );
        for (final matrixEvent in response.chunk) {
          final type = matrixEvent.type;
          if (type != blockedEventType && type != unblockedEventType) continue;
          final content = Map<String, dynamic>.from(matrixEvent.content);
          final eventRoom = content['room_id']?.toString() ?? room.id;
          final previous = latestByRoom[eventRoom];
          if (previous == null ||
              matrixEvent.originServerTs.isAfter(previous.originServerTs) ||
              (matrixEvent.originServerTs == previous.originServerTs &&
                  matrixEvent.eventId.compareTo(previous.eventId) > 0)) {
            latestByRoom[eventRoom] = matrixEvent;
          }
        }
      } catch (error) {
        debugPrint(
          '[BlockState] backfill failed room="${room.id}" error=$error',
        );
      }
    }

    final latestEvents = latestByRoom.entries.toList()
      ..sort((a, b) {
        final timestamp = a.value.originServerTs.compareTo(
          b.value.originServerTs,
        );
        return timestamp != 0
            ? timestamp
            : a.value.eventId.compareTo(b.value.eventId);
      });

    debugPrint(
      '[BlockState][DIAG] backfill rooms_scanned=${_client.rooms.length} '
      'latest_events=${latestEvents.length}',
    );

    for (final latest in latestEvents) {
      try {
        final matrixEvent = latest.value;
        final type = matrixEvent.type;
        final content = Map<String, dynamic>.from(matrixEvent.content);
        final eventRoom = latest.key;
        final blockedBy =
            content['blocked_by']?.toString() ?? matrixEvent.senderId;
        if (blockedBy.isEmpty) continue;
        debugPrint(
          '[BlockState] backfill event type="$type" receiver="$userId" '
          'sender="$blockedBy" room="$eventRoom" content=$content',
        );
        if (type == blockedEventType) {
          final blockedUser = content['blocked_user_id']?.toString();
          if (blockedUser != null &&
              blockedUser.isNotEmpty &&
              blockedUser != userId) {
            continue;
          }
          await _applyBlockEvent(
            () => recordBlockedBy({
              'blocked_by': blockedBy,
              'blocked_user_id': userId,
              'room_id': eventRoom,
              'blocked_at':
                  content['timestamp']?.toString() ??
                  matrixEvent.originServerTs.toUtc().toIso8601String(),
            }),
          );
        } else {
          await _applyBlockEvent(
            () => removeBlockedBy(blockedBy: blockedBy, roomId: eventRoom),
          );
        }
      } catch (error) {
        debugPrint('[BlockState] backfill event apply failed error=$error');
      }
    }
    _eventBackfillCompleted = true;
  }

  Future<void> _applyBlockEvent(Future<void> Function() operation) {
    final result = _eventApplyQueue.then((_) => operation());
    _eventApplyQueue = result.catchError((error, stackTrace) {
      debugPrint('[BlockState] queued event apply failed error=$error');
    });
    return result;
  }

  void handleSyncUpdate(mx.SyncUpdate update) {
    debugPrint(
      '[BlockState] sync received user="${_client.userID}" '
      'account_data=${update.accountData?.length ?? 0} '
      'joined_rooms=${update.rooms?.join?.length ?? 0}',
    );
    if (update.accountData?.any(
          (event) =>
              event.type == blocklistType ||
              event.type == bbbType ||
              event.type == blockedMessagesType,
        ) ??
        false) {
      unawaited(load());
    }
    for (final entry
        in update.rooms?.join?.entries ??
            const <String, mx.JoinedRoomUpdate>{}.entries) {
      final roomId = entry.key;
      for (final event
          in entry.value.timeline?.events ?? const <mx.MatrixEvent>[]) {
        if (event.type == blockedEventType ||
            event.type == unblockedEventType) {
          debugPrint(
            '[BlockState] block event received type="${event.type}" '
            'receiver="${_client.userID}" sender="${event.senderId}" '
            'room="$roomId" content=${event.content}',
          );
        }
        if (event.type == blockedEventType) {
          unawaited(
            _applyBlockEvent(
              () => recordBlockedBy({
                'blocked_by':
                    event.content['blocked_by']?.toString() ?? event.senderId,
                'blocked_user_id': _client.userID,
                'room_id': event.content['room_id']?.toString() ?? roomId,
                'blocked_at':
                    event.content['timestamp']?.toString() ??
                    event.originServerTs.toUtc().toIso8601String(),
              }),
            ),
          );
        } else if (event.type == unblockedEventType) {
          unawaited(
            _applyBlockEvent(
              () => removeBlockedBy(blockedBy: event.senderId, roomId: roomId),
            ),
          );
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
          (peer != null &&
              peer.isNotEmpty &&
              entry['user_id']?.toString() == peer);
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
    final matched = _entries(_bbb).any((entry) {
      final blockedBy = localpart(entry['blocked_by']?.toString() ?? '');
      // The relationship is user-scoped. Room IDs are event context only;
      // direct rooms can be recreated or differ across delivery paths.
      final peerMatch = blockedBy == target;
      return peerMatch;
    });
    debugPrint(
      '[BlockState][DIAG] BBB lookup peer="$userId" room="$room" '
      'targetLocalpart="$target" matched=$matched ready=$_ready '
      'entries=${_entries(_bbb)}',
    );
    return matched;
  }

  /// Privacy-safe decision for profile/avatar consumers.
  ///
  /// Loading is not the same as redaction. Consumers must be able to render
  /// already-cached profile data while the block state is being hydrated. A
  /// real BBB match is still fail-closed and suppresses the profile/avatar.
  bool isRedactedByBbb(String userId, {String? roomId}) {
    final matched = isBlockedByBbb(userId, roomId: roomId);
    final result = matched;
    debugPrint(
      '[BlockState][DIAG] isRedactedByBbb peer="$userId" room="${roomId ?? ''}" '
      'ready=$_ready matched=$matched action=${result ? 'suppress' : 'allow_cached'}',
    );
    return result;
  }

  /// Privacy-safe decision for every profile surface. This covers both
  /// directions: the viewer's BLOCKLIST and the viewer's BBB state.
  /// Unknown state fails closed until account data/event backfill is ready.
  bool isRedactedForViewer(String userId, {String? roomId}) {
    return !_ready || isRoomBlocked(roomId ?? '', peerId: userId);
  }

  bool isBlockedBy(String userId, {String? roomId}) =>
      isRoomBlocked(roomId ?? '', peerId: userId);

  List<Map<String, dynamic>> get blocklist => _entries(_blocklist);
  List<Map<String, dynamic>> get bbb => _entries(_bbb);
  List<Map<String, dynamic>> get blockedMessages => _entries(_blockedMessages);

  Future<void> addBlock({
    required String userId,
    required String roomId,
  }) async {
    final targetUserId = userId.trim();
    final targetRoomId = roomId.trim();
    final blockerUserId = _client.userID?.trim() ?? '';
    if (targetUserId.isEmpty || targetRoomId.isEmpty) {
      throw ArgumentError('Block requires a target user and room');
    }
    if (_sameUser(targetUserId, blockerUserId)) {
      throw StateError('Refusing to block the signed-in user');
    }
    final key = _blockKey(targetUserId, targetRoomId);
    _optimisticUnblocks.remove(key);
    _optimisticBlocks[key] = {
      'user_id': targetUserId,
      'room_id': targetRoomId,
      'blocked_at': DateTime.now().toUtc().toIso8601String(),
    };
    debugPrint(
      '[BlockState][DIAG] addBlock blocker="$blockerUserId" '
      'blocked_user="$targetUserId" room="$targetRoomId"',
    );
    await _update(blocklistType, _blocklist, (entries) {
      entries.removeWhere(
        (e) => e['user_id'] == targetUserId || e['room_id'] == targetRoomId,
      );
      entries.add({
        'user_id': targetUserId,
        'room_id': targetRoomId,
        'blocked_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    await _sendRoomNotice(targetRoomId, blockedEventType, {
      'blocked_by': blockerUserId,
      'blocked_user_id': targetUserId,
      'room_id': targetRoomId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> removeBlock({
    required String userId,
    required String roomId,
  }) async {
    final key = _blockKey(userId, roomId);
    _optimisticBlocks.remove(key);
    _optimisticUnblocks.add(key);
    final exists = _entries(_blocklist).any(
      (entry) =>
          entry['user_id']?.toString() == userId ||
          entry['room_id']?.toString() == roomId,
    );
    if (!exists) {
      debugPrint(
        '[BlockState] unblock ignored: no matching BLOCKLIST entry '
        'user="$userId" room="$roomId"',
      );
      return;
    }
    debugPrint('[BlockState][DIAG] removeBlock user="$userId" room="$roomId"');
    await _update(blocklistType, _blocklist, (entries) {
      entries.removeWhere(
        (e) => e['user_id'] == userId || e['room_id'] == roomId,
      );
    });
    await _sendRoomNotice(roomId, unblockedEventType, {
      'blocked_by': _client.userID,
      'blocked_user_id': userId,
      'room_id': roomId,
    });
  }

  String _blockKey(String userId, String roomId) =>
      '${userId.trim()}|${roomId.trim()}';

  bool _sameUser(String left, String right) {
    String localpart(String value) {
      final normalized = value.trim().toLowerCase();
      final withoutAt = normalized.startsWith('@')
          ? normalized.substring(1)
          : normalized;
      final separator = withoutAt.indexOf(':');
      return separator == -1 ? withoutAt : withoutAt.substring(0, separator);
    }

    final a = localpart(left);
    final b = localpart(right);
    return a.isNotEmpty && a == b;
  }

  Map<String, dynamic> _sanitizeBbb(Map<String, dynamic> content) {
    final receiver = _client.userID?.trim() ?? '';
    final valid = _entries(content).where((entry) {
      final blockedBy = entry['blocked_by']?.toString() ?? '';
      final blockedUser = entry['blocked_user_id']?.toString() ?? '';
      return blockedBy.isNotEmpty &&
          _sameUser(blockedUser, receiver) &&
          !_sameUser(blockedBy, blockedUser);
    }).toList();
    return <String, dynamic>{'entries': valid};
  }

  Map<String, dynamic> _sanitizeBlocklist(Map<String, dynamic> content) {
    final localUserId = _client.userID?.trim() ?? '';
    final valid = _entries(content).where((entry) {
      final target = entry['user_id']?.toString().trim() ?? '';
      final room = entry['room_id']?.toString().trim() ?? '';
      // A blocklist entry is always authored by the signed-in user. A record
      // targeting that same user is stale/corrupt data from the old flow and
      // must never affect privacy decisions.
      return target.isNotEmpty &&
          room.isNotEmpty &&
          !_sameUser(target, localUserId);
    }).toList();
    return <String, dynamic>{'entries': valid};
  }

  Future<void> recordBlockedBy(Map<String, dynamic> entry) async {
    final blockedBy =
        entry['blocked_by']?.toString().trim().toLowerCase() ?? '';
    final blockedUserId = entry['blocked_user_id']?.toString().trim() ?? '';
    final localUserId = _client.userID?.trim() ?? '';
    if (blockedBy.isEmpty ||
        blockedUserId.isEmpty ||
        !_sameUser(blockedUserId, localUserId) ||
        _sameUser(blockedBy, blockedUserId)) {
      debugPrint(
        '[BlockState] rejected invalid BBB entry blocked_by="$blockedBy" '
        'blocked_user_id="$blockedUserId" receiver="$localUserId"',
      );
      return;
    }
    final blockedAt = DateTime.tryParse(entry['blocked_at']?.toString() ?? '');
    final unblockedAt = _profileUnblockedAt[blockedBy];
    if (blockedAt != null &&
        unblockedAt != null &&
        !blockedAt.isAfter(unblockedAt)) {
      debugPrint(
        '[BlockState] ignored stale blocked event blocked_by="$blockedBy" '
        'blocked_at="$blockedAt" unblocked_at="$unblockedAt"',
      );
      return;
    }
    debugPrint(
      '[BlockState] persisting BBB receiver="${_client.userID}" entry=$entry',
    );
    await _update(bbbType, _bbb, (entries) {
      entries.removeWhere(
        (e) =>
            e['blocked_by'] == entry['blocked_by'] &&
            e['room_id'] == entry['room_id'],
      );
      entries.add(entry);
    });
    debugPrint(
      '[BlockState][DIAG] BBB after record self="${_client.userID}" '
      'entries=${_entries(_bbb)}',
    );
  }

  Future<void> removeBlockedBy({
    required String blockedBy,
    required String roomId,
  }) async {
    debugPrint(
      '[BlockState][DIAG] removeBlockedBy blockedBy="$blockedBy" room="$roomId"',
    );
    await _update(bbbType, _bbb, (entries) {
      entries.removeWhere(
        (e) => e['blocked_by'] == blockedBy && e['room_id'] == roomId,
      );
    });
    _unblockController.add((blockedBy: blockedBy, roomId: roomId));
  }

  Future<void> reconcileProfileUnblocked(String blockedBy) async {
    final target = blockedBy.trim().toLowerCase();
    if (target.isEmpty) return;
    final now = DateTime.now().toUtc();
    final previous = _profileUnblockedAt[target];
    if (previous == null || now.isAfter(previous)) {
      _profileUnblockedAt[target] = now;
    }
    final before = _entries(_bbb).length;
    await _update(bbbType, _bbb, (entries) {
      entries.removeWhere((entry) {
        final value = entry['blocked_by']?.toString().trim().toLowerCase();
        return value == target;
      });
    });
    if (_entries(_bbb).length != before) {
      _unblockController.add((blockedBy: blockedBy, roomId: ''));
      revision.value++;
      debugPrint(
        '[BlockState][DIAG] reconciled stale BBB blocked_by="$blockedBy" '
        'entries=${_entries(_bbb)}',
      );
    }
  }

  Future<void> recordBlockedMessage({
    required String roomId,
    required String eventId,
    required String text,
    required DateTime time,
  }) async {
    await _update(blockedMessagesType, _blockedMessages, (entries) {
      final nextSequence =
          entries.fold<int>(0, (max, entry) {
            final value = entry['sequence'];
            final sequence = value is num
                ? value.toInt()
                : int.tryParse('$value') ?? 0;
            return sequence > max ? sequence : max;
          }) +
          1;
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
    _client.accountData[type]?.content ?? const <String, dynamic>{},
  );

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
      if (type == blocklistType) _blocklist = next;
      if (type == bbbType) _bbb = next;
      if (type == blockedMessagesType) _blockedMessages = next;
      // Publish the local state before the network write. A slow/offline
      // Matrix server must not prevent the chat/profile UI from reflecting
      // the user's block action.
      revision.value++;
      await _client.setAccountData(userId, type, next);
    });
    _writeQueue = write.catchError((Object error) {
      debugPrint(
        '[BlockState] account data update failed type=$type error=$error',
      );
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
