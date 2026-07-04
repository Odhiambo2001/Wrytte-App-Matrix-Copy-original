import 'dart:async';
import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/services/file_upload_limits.dart';

import 'matrix_auth_service.dart';
import 'matrix_client.dart';
import 'matrix_config.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

class MatrixPublicGroup {
  final String roomId;
  final String name;
  final String? avatarUrl;
  final String? canonicalAlias;
  final String? topic;
  final int memberCount;
  final bool worldReadable;

  const MatrixPublicGroup({
    required this.roomId,
    required this.name,
    this.avatarUrl,
    this.canonicalAlias,
    this.topic,
    required this.memberCount,
    required this.worldReadable,
  });
}

class MatrixCreatedGroupRoom {
  final String roomId;
  final Room? room;

  const MatrixCreatedGroupRoom({required this.roomId, this.room});
}

class MatrixChatService {
  MatrixChatService._();
  static final MatrixChatService instance = MatrixChatService._();

  bool _initialSyncComplete = false;
  bool get initialSyncComplete => _initialSyncComplete;
  Future<void>? _syncAndJoinFuture;
  final Map<String, Future<Room>> _directRoomFutures = {};
  final Set<String> _dismissedPublicGroupKeys = {};
  String? _dismissedPublicGroupsLoadedFor;

  // Room IDs the app knows to be groups (created or restored via ChatService).
  // This is an authoritative signal that distinguishes a 2-member group from a
  // 1:1 DM — member count alone cannot. ChatService pushes its persisted set
  // down via registerCreatedGroupRooms() on startup, and createGroupRoom()
  // registers newly created rooms immediately.
  final Set<String> _createdGroupRoomIds = {};

  Stream<Event> get timelineEvents =>
      MatrixClientService.instance.client.onTimelineEvent.stream;

  Stream<SyncUpdate> get syncStream =>
      MatrixClientService.instance.client.onSync.stream;

  Future<Client> connect() => MatrixAuthService.instance.restore();

  List<Room> get rooms {
    if (!MatrixClientService.instance.isInitialized) return const [];
    return MatrixClientService.instance.client.rooms;
  }

  void resetRuntimeState() {
    _initialSyncComplete = false;
    _syncAndJoinFuture = null;
    _directRoomFutures.clear();
  }

  // ── Created-group registry ─────────────────────────────────────────────────

  /// Register a single room ID as a known group. Safe to call repeatedly.
  void registerCreatedGroupRoom(String roomId) {
    final id = roomId.trim();
    if (id.isNotEmpty) _createdGroupRoomIds.add(id);
  }

  /// Register many room IDs as known groups (e.g. ChatService's persisted set).
  void registerCreatedGroupRooms(Iterable<String> roomIds) {
    for (final id in roomIds) {
      registerCreatedGroupRoom(id);
    }
  }

  /// True if the room was created/known as a group by the app.
  bool isCreatedGroupRoom(String roomId) =>
      _createdGroupRoomIds.contains(roomId.trim());

  Room? getRoomById(String roomId) {
    if (!MatrixClientService.instance.isInitialized) return null;
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
          // CHANGED: 8s -> 30s to match the slow dev homeserver.
          await firstSync.timeout(const Duration(seconds: 30), onTimeout: () {});
        } else {
          await client
              .oneShotSync()
              .timeout(const Duration(seconds: 30), onTimeout: () => '');
        }
      } catch (_) {
        // The background sync will keep running. We still inspect loaded rooms.
      }
      _initialSyncComplete = true;
      // ADDED: visibility into whether rooms actually loaded.
      apkLog(
        'Matrix.sync',
        'ensureSynced done rooms=${client.rooms.length} user_id="${client.userID}"',
      );
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

  Future<bool> isRoomAliasAvailable(String aliasLocalpart) async {
    final client = await connect();
    if (!client.isLogged()) return false;

    final localpart = aliasLocalpart.trim();
    if (localpart.isEmpty) return false;
    final fullAlias = '#$localpart:${MatrixConfig.serverName}';
    try {
      await client.getRoomIdByAlias(fullAlias);
      return false;
    } catch (e) {
      final text = e.toString().toUpperCase();
      if (text.contains('404') ||
          text.contains('M_NOT_FOUND') ||
          text.contains('NOT_FOUND')) {
        return true;
      }
      apkLog(
        'Matrix.alias',
        'alias check failed alias="$fullAlias" error="$e"',
      );
      return false;
    }
  }

  Future<MatrixCreatedGroupRoom> createGroupRoom({
    required String name,
    required bool isPublic,
    String? aliasLocalpart,
    List<String> invite = const [],
  }) async {
    final client = await connect();
    if (!client.isLogged()) {
      throw StateError('Matrix session is not available.');
    }

    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('Group name is required.');
    }
    final cleanAlias = aliasLocalpart?.trim();
    final cleanInvites =
        invite
            .map((id) => id.trim())
            .where((id) => id.startsWith('@') && id.contains(':'))
            .toSet()
            .toList();

    await ensureSyncedAndAutoJoinInvites();

    final roomId = await client.createRoom(
      name: cleanName,
      invite: cleanInvites,
      isDirect: false,
      roomAliasName: isPublic ? cleanAlias : null,
      visibility: isPublic ? Visibility.public : Visibility.private,
      preset:
          isPublic ? CreateRoomPreset.publicChat : CreateRoomPreset.privateChat,
      initialState: [
        StateEvent(
          content: {'join_rule': isPublic ? 'public' : 'invite'},
          type: EventTypes.RoomJoinRules,
        ),
        StateEvent(
          content: {
            'history_visibility':
                isPublic
                    ? HistoryVisibility.joined.text
                    : HistoryVisibility.invited.text,
          },
          type: EventTypes.HistoryVisibility,
        ),
      ],
    );

    // Register immediately so this room is authoritatively known as a group,
    // even if it only has 2 members (creator + one invitee).
    registerCreatedGroupRoom(roomId);

    try {
      await client
          .waitForRoomInSync(roomId, join: true)
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      // The background sync may still have the room; inspect loaded rooms below.
    }
    final room = getRoomById(roomId);
    if (room == null) {
      apkLog(
        'Matrix.groups',
        'created room_id="$roomId" but room not available after wait; continuing with local group shell',
      );
    }
    if (isPublic && cleanAlias != null && cleanAlias.isNotEmpty) {
      if (room != null) {
        try {
          await room.setCanonicalAlias(
            '#$cleanAlias:${MatrixConfig.serverName}',
          );
        } catch (e) {
          apkLog(
            'Matrix.alias',
            'set canonical alias skipped room_id="$roomId" alias="$cleanAlias" error="$e"',
          );
        }
      } else {
        apkLog(
          'Matrix.alias',
          'canonical alias deferred room_id="$roomId" alias="$cleanAlias" reason="room not synced"',
        );
      }
    }
    return MatrixCreatedGroupRoom(roomId: roomId, room: room);
  }

  Future<List<MatrixPublicGroup>> fetchPublicGroups({int? limit}) async {
    final client = await connect();
    if (!client.isLogged()) return const [];
    await _loadDismissedPublicGroups();

    try {
      final response =
          limit == null
              ? await client.queryPublicRooms()
              : await client.queryPublicRooms(limit: limit);
      return response.chunk
          .map(
            (room) => MatrixPublicGroup(
              roomId: room.roomId,
              name:
                  room.name?.trim().isNotEmpty == true
                      ? room.name!.trim()
                      : _displayAlias(room.canonicalAlias) ?? 'Group',
              avatarUrl: room.avatarUrl?.toString(),
              canonicalAlias: room.canonicalAlias,
              topic: room.topic,
              memberCount: room.numJoinedMembers,
              worldReadable: room.worldReadable,
            ),
          )
          .where((group) => !isPublicGroupDismissed(group))
          .toList();
    } catch (e) {
      apkLog('Matrix.groups', 'public rooms fetch failed error="$e"');
      return const [];
    }
  }

  String _dismissedPublicGroupsKey(String userId) =>
      'wrytte.dismissed_public_groups.$userId';

  String _publicGroupKey(String value) => value.trim().toLowerCase();

  Iterable<String> _publicGroupKeys({
    required String roomId,
    String? canonicalAlias,
  }) sync* {
    final id = _publicGroupKey(roomId);
    if (id.isNotEmpty) yield id;
    final alias = _publicGroupKey(canonicalAlias ?? '');
    if (alias.isNotEmpty) yield alias;
  }

  Future<void> _loadDismissedPublicGroups() async {
    final userId = MatrixClientService.instance.client.userID?.trim() ?? '';
    if (userId.isEmpty) return;
    if (_dismissedPublicGroupsLoadedFor == userId) return;
    final prefs = await SharedPreferences.getInstance();
    _dismissedPublicGroupKeys
      ..clear()
      ..addAll(
        (prefs.getStringList(_dismissedPublicGroupsKey(userId)) ?? const [])
            .map(_publicGroupKey)
            .where((key) => key.isNotEmpty),
      );
    _dismissedPublicGroupsLoadedFor = userId;
  }

  Future<void> _saveDismissedPublicGroups() async {
    final userId = MatrixClientService.instance.client.userID?.trim() ?? '';
    if (userId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _dismissedPublicGroupsKey(userId),
      _dismissedPublicGroupKeys.toList(growable: false),
    );
  }

  bool isPublicGroupDismissed(MatrixPublicGroup group) {
    return _publicGroupKeys(
      roomId: group.roomId,
      canonicalAlias: group.canonicalAlias,
    ).any(_dismissedPublicGroupKeys.contains);
  }

  Future<void> dismissPublicGroup({
    required String roomId,
    String? canonicalAlias,
  }) async {
    await _loadDismissedPublicGroups();
    final before = _dismissedPublicGroupKeys.length;
    _dismissedPublicGroupKeys.addAll(
      _publicGroupKeys(roomId: roomId, canonicalAlias: canonicalAlias),
    );
    if (_dismissedPublicGroupKeys.length != before) {
      await _saveDismissedPublicGroups();
    }
  }

  Future<Room?> joinGroup(String roomIdOrAlias) async {
    final client = await connect();
    if (!client.isLogged()) return null;
    final target = roomIdOrAlias.trim();
    if (target.isEmpty) return null;

    final existing = getRoomById(target);
    if (existing != null && existing.membership == Membership.join) {
      return existing;
    }

    try {
      final roomId =
          target.startsWith('!')
              ? await client.joinRoomById(target)
              : await client.joinRoom(target);
      await client
          .waitForRoomInSync(roomId, join: true)
          .timeout(const Duration(seconds: 12));
      return getRoomById(roomId);
    } catch (e) {
      apkLog('Matrix.groups', 'join failed target="$target" error="$e"');
      rethrow;
    }
  }

  Future<void> leaveGroup(String roomId) async {
    final room = getRoomById(roomId);
    if (room == null) return;
    await room.leave();
  }

  bool isGroupOwner(Room room) {
    final userId = MatrixClientService.instance.client.userID;
    if (userId == null || userId.isEmpty) return false;
    return room.creatorUserIds.contains(userId) ||
        room.ownPowerLevel.level >= 100;
  }

  bool isMatrixGroupRoom(Room room) {
    // a public room is always a group
    if (room.joinRules == JoinRules.public) return true;
    // a room with a canonical alias is always a group
    if (room.canonicalAlias.trim().isNotEmpty) return true;
    // a room the app created/knows as a group is always a group
    // (this is the only reliable signal for a 2-member group)
    if (isCreatedGroupRoom(room.id)) return true;
    // a 3+ member room is a group, period
    if (groupMemberCount(room) > 2) return true;
    if (room.isDirectChat) return false;
    if (_looksLikeUnmarkedDirectRoom(room)) return false;
    return false;
  }

  bool looksLikeUnmarkedDirectRoom(Room room) =>
      _looksLikeUnmarkedDirectRoom(room);

  bool _looksLikeUnmarkedDirectRoom(Room room) {
    if (room.joinRules == JoinRules.public) return false;
    final alias = room.canonicalAlias.trim();
    if (alias.isNotEmpty) return false;
    // A known group is never an unmarked direct room, even with 2 members.
    if (isCreatedGroupRoom(room.id)) return false;
    final participantCount =
        room
            .getParticipants([Membership.join, Membership.invite])
            .map((user) => user.id.trim())
            .where((id) => id.isNotEmpty)
            .toSet()
            .length;
    return participantCount > 0 && participantCount <= 2;
  }

  int groupMemberCount(Room room) {
    final ids =
        room
            .getParticipants([Membership.join, Membership.invite])
            .map((user) => user.id.trim())
            .where((id) => id.isNotEmpty)
            .toSet();
    if (ids.isNotEmpty) return ids.length;
    return room.getParticipants().map((user) => user.id).toSet().length;
  }

  String? _displayAlias(String? alias) {
    final raw = alias?.trim() ?? '';
    if (raw.isEmpty) return null;
    final withoutHash = raw.startsWith('#') ? raw.substring(1) : raw;
    return withoutHash.split(':').first;
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
      roomId = await client.startDirectChat(
        matrixUserId,
        waitForSync: false,
        initialState: [
          StateEvent(
            content: {'history_visibility': HistoryVisibility.invited.text},
            type: EventTypes.HistoryVisibility,
          ),
        ],
      );
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
    await FileUploadLimits.validatePath(
      filePath,
      maxBytes: FileUploadLimits.chatFileMaxBytes,
      label: 'Attachment',
    );
    final matrixFile = MatrixFile.fromMimeType(
      bytes: await file.readAsBytes(),
      name: p.basename(filePath),
      mimeType: mimeType,
    );
    return room.sendFileEvent(matrixFile);
  }

  Future<Timeline> getTimeline(
    String roomId, {
    int? limit,
    void Function()? onUpdate,
  }) async {
    final room = getRoomById(roomId);
    if (room == null) throw StateError('Unknown Matrix room: $roomId');
    return room.getTimeline(limit: limit, onUpdate: onUpdate);
  }

  Future<void> markRead(String roomId, {String? eventId}) async {
    final room = getRoomById(roomId);
    final readEventId = eventId ?? room?.lastEvent?.eventId;
    if (room == null || readEventId == null || readEventId.isEmpty) return;
    await MatrixClientService.instance.client.setReadMarker(
      roomId,
      mFullyRead: readEventId,
      mRead: readEventId,
    );
  }

  Room? _directRoomFor(String matrixUserId, {bool includeInvite = false}) {
    for (final room in MatrixClientService.instance.client.rooms) {
      if (room.directChatMatrixID != matrixUserId) continue;
      // A known group (including a 2-member group) is never a direct room.
      if (isCreatedGroupRoom(room.id)) continue;
      // 3+ members can't be a real 1:1 — skip it.
      if (groupMemberCount(room) > 2) continue;
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
    var participants = room.getParticipants([
      Membership.join,
      Membership.invite,
    ]);
    try {
      participants = await room
          .requestParticipants([Membership.join, Membership.invite], true, true)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      apkLog(
        'Matrix.invite',
        'participant request failed room_id="${room.id}" target="$matrixUserId" error="$e"',
      );
    }
    User? peer;
    for (final participant in participants) {
      if (participant.id == matrixUserId) {
        peer = participant;
        break;
      }
    }
    if (peer != null &&
        (peer.membership == Membership.join ||
            peer.membership == Membership.invite)) {
      apkLog(
        'Matrix.invite',
        'peer present room_id="${room.id}" target="$matrixUserId" membership="${peer.membership.name}"',
      );
      return;
    }
    if (peer != null) {
      apkLog(
        'Matrix.invite',
        'peer present but not joined; refreshing invite room_id="${room.id}" target="$matrixUserId" membership="${peer.membership.name}"',
      );
    }

    apkLog(
      'Matrix.invite',
      'POST /_matrix/client/v3/rooms/${room.id}/invite target="$matrixUserId"',
    );
    try {
      await room.invite(matrixUserId).timeout(const Duration(seconds: 12));
      apkLog(
        'Matrix.invite',
        'invite sent room_id="${room.id}" target="$matrixUserId"',
      );
      await _waitForPeerMembership(room, matrixUserId);
    } catch (e) {
      if (_looksLikeAlreadyInvitedOrJoined(e)) {
        apkLog(
          'Matrix.invite',
          'invite already satisfied room_id="${room.id}" target="$matrixUserId" error="$e"',
        );
        return;
      }
      apkLog(
        'Matrix.invite',
        'invite failed room_id="${room.id}" target="$matrixUserId" error="$e"',
      );
      rethrow;
    }
  }

  Future<void> _waitForPeerMembership(Room room, String matrixUserId) async {
    final client = MatrixClientService.instance.client;
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    Object? lastError;

    while (DateTime.now().isBefore(deadline)) {
      try {
        await client
            .waitForRoomInSync(room.id)
            .timeout(const Duration(seconds: 3));
        final participants = await room
            .requestParticipants(
              [Membership.join, Membership.invite],
              true,
              true,
            )
            .timeout(const Duration(seconds: 4));
        for (final participant in participants) {
          if (participant.id == matrixUserId) {
            apkLog(
              'Matrix.invite',
              'peer membership confirmed room_id="${room.id}" target="$matrixUserId" membership="${participant.membership.name}"',
            );
            return;
          }
        }
      } catch (e) {
        lastError = e;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    throw TimeoutException(
      'Timed out waiting for $matrixUserId to appear as invited/joined in ${room.id}. Last error: $lastError',
    );
  }

  bool _looksLikeAlreadyInvitedOrJoined(Object error) {
    final raw = error.toString().toLowerCase();
    return raw.contains('already') || raw.contains('membership');
  }
}
