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
  final int avatarVersion;
  final int nameVersion;
  final int descriptionVersion;
  final int linkVersion;
  final int aliasVersion;
  final String? link;

  const MatrixPublicGroup({
    required this.roomId,
    required this.name,
    this.avatarUrl,
    this.canonicalAlias,
    this.topic,
    required this.memberCount,
    required this.worldReadable,
    this.avatarVersion = 0,
    this.nameVersion = 0,
    this.descriptionVersion = 0,
    this.linkVersion = 0,
    this.aliasVersion = 0,
    this.link,
  });

  int get profileVersionFingerprint {
    var value = 17;
    for (final version in [
      avatarVersion,
      nameVersion,
      descriptionVersion,
      linkVersion,
      aliasVersion,
    ]) {
      value = 37 * value + version;
    }
    return value;
  }

  MatrixPublicGroup copyWithProfile(Map<String, dynamic> profile) =>
      MatrixPublicGroup(
        roomId: roomId,
        name:
            profile['name']?.toString().trim().isNotEmpty == true
                ? profile['name'].toString().trim()
                : name,
        avatarUrl:
            profile['avatarUrl']?.toString().trim().isNotEmpty == true
                ? profile['avatarUrl'].toString().trim()
                : avatarUrl,
        canonicalAlias:
            profile['canonicalAlias']?.toString().trim().isNotEmpty == true
                ? profile['canonicalAlias'].toString().trim()
                : canonicalAlias,
        topic: profile['description']?.toString() ?? topic,
        memberCount: memberCount,
        worldReadable: worldReadable,
        avatarVersion: profile['avatarVersion'] as int? ?? avatarVersion,
        nameVersion: profile['nameVersion'] as int? ?? nameVersion,
        descriptionVersion:
            profile['descriptionVersion'] as int? ?? descriptionVersion,
        linkVersion: profile['linkVersion'] as int? ?? linkVersion,
        aliasVersion: profile['aliasVersion'] as int? ?? aliasVersion,
        link: profile['link']?.toString() ?? link,
      );
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
  static const String _deletedGroupsAccountDataType =
      'com.wrytte.deleted_groups';
  // These keys were written by the short-lived preview-membership heuristic.
  // A public preview can hide membership state from non-members, so they are
  // not evidence that a room is empty. Remove the contaminated tombstones once.
  static const Set<String> _invalidPreviewTombstoneKeys = {
    '!uvu0qyktfifvoigk:matrix.wrytte.com',
    '#gr.@4:matrix.wrytte.com',
    '!wfdut1xfcavbf0tb:matrix.wrytte.com',
    '#gr.@5:matrix.wrytte.com',
    '!wppezazplsl6xd8n:matrix.wrytte.com',
    '#gr.@carsandtrucks:matrix.wrytte.com',
    '!sxrcjldzespwe5dq:matrix.wrytte.com',
    '#gr.@6:matrix.wrytte.com',
    '!cpmghoq0lopmbi8x:matrix.wrytte.com',
    '#gr.@1:matrix.wrytte.com',
    '!zac19tjual2e0jcz:matrix.wrytte.com',
    '!jamy5uubhighb0b:matrix.wrytte.com',
    '#gr.@3:matrix.wrytte.com',
    '!2ybwyj3kq4xbuiie:matrix.wrytte.com',
    '#gr.@testgr1:matrix.wrytte.com',
    '!h76radouv5igaacn:matrix.wrytte.com',
    '#gr.@2:matrix.wrytte.com',
  };
  String? _dismissedPublicGroupsLoadedFor;
  List<MatrixPublicGroup>? _cachedPublicGroups;
  DateTime? _cachedPublicGroupsAt;
  static const Duration _publicGroupsCacheTtl = Duration(seconds: 10);
  static const Set<String> _excludedSuggestedRoomIds = {
    '!k2yplerdozzhsqwa:matrix.wrytte.com',
  };

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

  void unregisterCreatedGroupRoom(String roomId) {
    final id = roomId.trim();
    if (id.isNotEmpty) _createdGroupRoomIds.remove(id);
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

  bool isVerifiedDirectRoomFor(String roomId, String matrixUserId) {
    final room = getRoomById(roomId.trim());
    final peer = matrixUserId.trim();
    if (room == null || peer.isEmpty) return false;
    if (room.membership != Membership.join &&
        room.membership != Membership.invite) {
      return false;
    }
    if (room.directChatMatrixID != peer) return false;
    if (isCreatedGroupRoom(room.id) ||
        room.joinRules == JoinRules.public ||
        room.canonicalAlias.trim().isNotEmpty ||
        room.getState('com.wrytte.group.info') != null ||
        groupMemberCount(room) > 2) {
      return false;
    }
    return true;
  }

  Future<List<Room>> discoverAndRepairDirectRooms() async {
    final client = await connect();
    final me = client.userID;
    if (me == null || me.isEmpty) return const [];
    final directRooms = <Room>[];
    for (final room in List<Room>.from(client.rooms)) {
      if (room.membership != Membership.join) continue;
      var peer = room.directChatMatrixID?.trim() ?? '';
      if (peer.isNotEmpty && isVerifiedDirectRoomFor(room.id, peer)) {
        directRooms.add(room);
        continue;
      }
      if (!_looksLikeUnmarkedDirectRoom(room)) continue;
      final peers =
          room
              .getParticipants()
              .map((member) => member.id.trim())
              .where((id) => id.isNotEmpty && id != me)
              .toSet();
      if (peers.length != 1) continue;
      peer = peers.single;
      try {
        await room.addToDirectChat(peer);
        directRooms.add(room);
        apkLog(
          'Matrix.direct',
          'repaired m.direct room_id="${room.id}" peer="$peer"',
        );
      } catch (error) {
        apkLog(
          'Matrix.direct',
          'm.direct repair failed room_id="${room.id}" peer="$peer" error="$error"',
        );
      }
    }
    return directRooms;
  }

  int roomProfileVersion(Room? room) {
    if (room == null) return 0;
    final content = room.getState('com.wrytte.group.info')?.content ?? const {};
    const fields = [
      'avatar_version',
      'name_version',
      'description_version',
      'link_version',
      'alias_version',
    ];
    var fingerprint = 17;
    for (final field in fields) {
      final value = int.tryParse(content[field]?.toString() ?? '') ?? 0;
      fingerprint = 37 * fingerprint + value;
    }
    // Retain compatibility with profiles written before per-field versions.
    final legacy =
        int.tryParse(content['profile_version']?.toString() ?? '') ?? 0;
    return 37 * fingerprint + legacy;
  }

  String roomProfileCacheIdentity({
    required String accountId,
    required String roomId,
    required String? avatarUrl,
    Room? room,
    int? profileVersion,
  }) {
    final owner = accountId.trim().toLowerCase();
    final id = roomId.trim().toLowerCase();
    final version = profileVersion ?? roomProfileVersion(room);
    final avatar = avatarUrl?.trim() ?? '';
    return 'room-profile:$owner:$id:v$version:$avatar';
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
          await firstSync.timeout(
            const Duration(seconds: 30),
            onTimeout: () {},
          );
        } else {
          await client.oneShotSync().timeout(
            const Duration(seconds: 30),
            onTimeout: () => '',
          );
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

  String _fullRoomAlias(String aliasLocalpart) {
    final trimmed = aliasLocalpart.trim();
    if (trimmed.isEmpty) return '';
    final withoutHash =
        trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
    final localpart = withoutHash.split(':').first.trim();
    return localpart.isEmpty ? '' : '#$localpart:${MatrixConfig.serverName}';
  }

  Future<void> replaceGroupAlias({
    required String roomId,
    required String oldAlias,
    required String newAliasLocalpart,
  }) async {
    final client = await connect();
    final room = getRoomById(roomId);
    if (room == null) throw StateError('Unknown Matrix room: $roomId');
    final oldFull = _fullRoomAlias(oldAlias);
    final newFull = _fullRoomAlias(newAliasLocalpart);
    if (oldFull == newFull) return;

    var createdNewAlias = false;
    if (newFull.isNotEmpty) {
      try {
        final resolved = await client.getRoomIdByAlias(newFull);
        if (resolved.roomId != roomId) {
          throw StateError('The group alias $newFull is already in use.');
        }
      } catch (error) {
        final text = error.toString().toUpperCase();
        final available = text.contains('404') || text.contains('M_NOT_FOUND');
        if (!available) rethrow;
        await client.setRoomAlias(newFull, roomId);
        createdNewAlias = true;
      }
    }

    try {
      await client.setRoomStateWithKey(
        roomId,
        EventTypes.RoomCanonicalAlias,
        '',
        newFull.isEmpty ? <String, dynamic>{} : {'alias': newFull},
      );
    } catch (_) {
      if (createdNewAlias) {
        try {
          await client.deleteRoomAlias(newFull);
        } catch (_) {
          // Preserve the original canonical alias error.
        }
      }
      rethrow;
    }

    if (oldFull.isNotEmpty) {
      try {
        await client.deleteRoomAlias(oldFull);
      } catch (error) {
        final text = error.toString().toUpperCase();
        if (!text.contains('404') && !text.contains('M_NOT_FOUND')) rethrow;
      }
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
    final creatorId = client.userID!;

    await ensureSyncedAndAutoJoinInvites();

    if (isPublic && cleanAlias != null && cleanAlias.isNotEmpty) {
      final available = await isRoomAliasAvailable(cleanAlias);
      if (!available) {
        throw StateError(
          'The group alias ${_fullRoomAlias(cleanAlias)} is already in use. '
          'Choose another alias.',
        );
      }
    }

    final roomId = await client.createRoom(
      name: cleanName,
      invite: cleanInvites,
      isDirect: false,
      roomAliasName: isPublic ? cleanAlias : null,
      visibility: isPublic ? Visibility.public : Visibility.private,
      preset:
          isPublic ? CreateRoomPreset.publicChat : CreateRoomPreset.privateChat,
      powerLevelContentOverride: {
        'users': {creatorId: 100},
        'users_default': 0,
        'events_default': 0,
        'state_default': 50,
        'invite': 50,
        'kick': 50,
        'ban': 50,
        'redact': 50,
      },
      initialState: [
        StateEvent(
          content: {
            'owner_user_id': creatorId,
            'group_origin': 'user_created',
            'avatar_version': 0,
            'name_version': 0,
            'description_version': 0,
            'link_version': 0,
            'alias_version': 0,
            'profile_version': 0,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          type: 'com.wrytte.group.info',
        ),
        StateEvent(
          content: {'join_rule': isPublic ? 'public' : 'invite'},
          type: EventTypes.RoomJoinRules,
        ),
        StateEvent(
          content: {
            'history_visibility':
                isPublic
                    // Suggested groups are previewable before joining so a
                    // prospective member can read the conversation first.
                    ? HistoryVisibility.worldReadable.text
                    : HistoryVisibility.invited.text,
          },
          type: EventTypes.HistoryVisibility,
        ),
      ],
    );

    // Dendrite may accept createRoom.initial_state before the room is visible
    // in the local sync store. Write the preview policy directly by room ID as
    // well, then read it back so a public/suggested group is never silently
    // created with restricted history.
    if (isPublic) {
      await client.setRoomStateWithKey(
        roomId,
        EventTypes.HistoryVisibility,
        '',
        {'history_visibility': HistoryVisibility.worldReadable.text},
      );
      final historyState = await client.getRoomStateWithKey(
        roomId,
        EventTypes.HistoryVisibility,
        '',
      );
      final appliedVisibility =
          historyState['history_visibility']?.toString() ?? '';
      if (appliedVisibility != HistoryVisibility.worldReadable.text) {
        throw StateError(
          'Public group $roomId was created without world-readable history.',
        );
      }
      apkLog(
        'Matrix.groups',
        'history visibility verified room_id="$roomId" '
            'history_visibility="$appliedVisibility"',
      );
    }

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
    final powerLevels = await client.getRoomStateWithKey(
      roomId,
      EventTypes.RoomPowerLevels,
      '',
    );
    final creatorLevel =
        (powerLevels['users'] as Map?)?[creatorId]?.toString() ?? '';
    if (creatorLevel != '100') {
      throw StateError(
        'Created group $roomId did not grant admin power to $creatorId.',
      );
    }
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
    final now = DateTime.now();
    final cached = _cachedPublicGroups;
    final cachedAt = _cachedPublicGroupsAt;
    if (limit == null &&
        cached != null &&
        cachedAt != null &&
        now.difference(cachedAt) < _publicGroupsCacheTtl) {
      return cached;
    }

    try {
      final response =
          limit == null
              ? await client.queryPublicRooms()
              : await client.queryPublicRooms(limit: limit);
      final groups =
          response.chunk
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
              // Empty rooms are abandoned/deleted groups. Dendrite can keep
              // advertising them after every user has left or forgotten the
              // room, but they must never be suggestions in Wrytte.
              .where((group) => group.memberCount > 0)
              .where(
                (group) =>
                    !_excludedSuggestedRoomIds.contains(
                      group.roomId.trim().toLowerCase(),
                    ),
              )
              .where((group) => !isPublicGroupDismissed(group))
              .toList();
      if (limit == null) {
        _cachedPublicGroups = groups;
        _cachedPublicGroupsAt = now;
      }
      return groups;
    } catch (e) {
      apkLog('Matrix.groups', 'public rooms fetch failed error="$e"');
      return const [];
    }
  }

  /// Makes future events in existing public groups owned by this user
  /// previewable before joining. Matrix applies history visibility at the
  /// event level, so this cannot expose older events that were sent while the
  /// room was restricted to joined/invited members.
  Future<void> upgradeOwnedPublicGroupsHistoryVisibility() async {
    final client = await connect();
    if (!client.isLogged()) return;

    for (final room in client.rooms) {
      if (room.membership != Membership.join ||
          room.joinRules != JoinRules.public ||
          !isGroupOwner(room) ||
          room.historyVisibility == HistoryVisibility.worldReadable ||
          !room.canChangeHistoryVisibility) {
        continue;
      }

      final previousVisibility = room.historyVisibility?.text ?? 'unknown';
      try {
        await room.setHistoryVisibility(HistoryVisibility.worldReadable);
        apkLog(
          'Matrix.groups',
          'history visibility upgraded room_id="${room.id}" '
              'from="$previousVisibility" to="world_readable"',
        );
      } catch (e) {
        apkLog(
          'Matrix.groups',
          'history visibility upgrade failed room_id="${room.id}" error="$e"',
        );
      }
    }
  }

  Future<void> upgradeCreatedGroupOwnershipProfiles() async {
    final client = await connect();
    final userId = client.userID?.trim() ?? '';
    if (userId.isEmpty) return;
    for (final room in client.rooms) {
      if (!_createdGroupRoomIds.contains(room.id) ||
          room.membership != Membership.join ||
          (!room.creatorUserIds.contains(userId) &&
              room.ownPowerLevel.level < 100)) {
        continue;
      }
      try {
        if (room.ownPowerLevel.level < 100) await room.setPower(userId, 100);
        final current = Map<String, dynamic>.from(
          room.getState('com.wrytte.group.info')?.content ?? const {},
        );
        var changed = false;
        if (!current.containsKey('owner_user_id')) {
          current['owner_user_id'] = userId;
          changed = true;
        }
        if (!current.containsKey('group_origin')) {
          current['group_origin'] = 'user_created';
          changed = true;
        }
        for (final key in const [
          'avatar_version',
          'name_version',
          'description_version',
          'link_version',
          'alias_version',
          'profile_version',
        ]) {
          if (!current.containsKey(key)) {
            current[key] = 0;
            changed = true;
          }
        }
        if (changed) {
          current['updated_at'] = DateTime.now().toUtc().toIso8601String();
          await client.setRoomStateWithKey(
            room.id,
            'com.wrytte.group.info',
            '',
            current,
          );
        }
      } catch (error) {
        apkLog(
          'Matrix.groups',
          'created profile upgrade failed room_id="${room.id}" error="$error"',
        );
      }
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
    if (_dismissedPublicGroupsLoadedFor != userId) {
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
    // Merge this on every discovery request: account data can arrive in a
    // later /sync after the first public-room query on a fresh installation.
    final serverDeletedGroups =
        MatrixClientService
            .instance
            .client
            .accountData[_deletedGroupsAccountDataType]
            ?.content['groups'];
    if (serverDeletedGroups is Map) {
      _dismissedPublicGroupKeys.addAll(
        serverDeletedGroups.keys
            .map((key) => _publicGroupKey(key.toString()))
            .where(
              (key) =>
                  key.isNotEmpty && !_invalidPreviewTombstoneKeys.contains(key),
            ),
      );
    }
    await _rollbackInvalidPreviewTombstones(userId);
  }

  String _previewTombstoneRollbackKey(String userId) =>
      'wrytte.preview_tombstone_rollback_v1.$userId';

  Future<void> _rollbackInvalidPreviewTombstones(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final migrationKey = _previewTombstoneRollbackKey(userId);
    if (prefs.getBool(migrationKey) == true) return;

    _dismissedPublicGroupKeys.removeAll(_invalidPreviewTombstoneKeys);
    await _saveDismissedPublicGroups();

    final client = MatrixClientService.instance.client;
    final existing = client.accountData[_deletedGroupsAccountDataType];
    final existingGroups = existing?.content['groups'];
    if (existingGroups is Map) {
      final groups = <String, Object?>{};
      for (final entry in existingGroups.entries) {
        final key = _publicGroupKey(entry.key.toString());
        if (!_invalidPreviewTombstoneKeys.contains(key)) {
          groups[entry.key.toString()] = entry.value;
        }
      }
      try {
        await client.setAccountData(userId, _deletedGroupsAccountDataType, {
          'groups': groups,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (e) {
        apkLog(
          'Matrix.groups',
          'preview tombstone rollback sync failed user="$userId" error="$e"',
        );
        return;
      }
    }
    await prefs.setBool(migrationKey, true);
    _cachedPublicGroups = null;
    _cachedPublicGroupsAt = null;
    apkLog(
      'Matrix.groups',
      'invalid preview tombstones rolled back user="$userId"',
    );
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
    final dismissed = _publicGroupKeys(
      roomId: group.roomId,
      canonicalAlias: group.canonicalAlias,
    ).any(_dismissedPublicGroupKeys.contains);
    if (dismissed) {
      apkLog(
        'Matrix.groups',
        'dismissed match name="${group.name}" room_id="${group.roomId}" '
            'alias="${group.canonicalAlias}" keys=${_dismissedPublicGroupKeys.length}',
      );
    }
    return dismissed;
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
      _cachedPublicGroups = null;
      _cachedPublicGroupsAt = null;
    }
    apkLog(
      'Matrix.groups',
      'dismissed room_id="$roomId" alias="$canonicalAlias" '
          'total_keys=${_dismissedPublicGroupKeys.length} '
          'user="${MatrixClientService.instance.client.userID}"',
    );
  }

  /// Permanently tombstones a deleted group for this Matrix account.
  ///
  /// Unlike SharedPreferences this follows the user across devices and app
  /// reinstalls. The homeserver purge is still performed by the trusted Wrytte
  /// backend because Dendrite admin credentials must never be shipped in the
  /// mobile application.
  Future<void> markPublicGroupDeleted({
    required String roomId,
    String? canonicalAlias,
    DateTime? deletedAt,
  }) => markPublicGroupsDeleted([
    MatrixPublicGroup(
      roomId: roomId,
      name: '',
      canonicalAlias: canonicalAlias,
      memberCount: 0,
      worldReadable: false,
    ),
  ], deletedAt: deletedAt);

  Future<void> markPublicGroupsDeleted(
    Iterable<MatrixPublicGroup> deletedGroups, {
    DateTime? deletedAt,
  }) async {
    final deleted = deletedGroups.toList(growable: false);
    if (deleted.isEmpty) return;
    await _loadDismissedPublicGroups();
    final timestamp = (deletedAt ?? DateTime.now()).toUtc().toIso8601String();
    for (final group in deleted) {
      for (final key in _publicGroupKeys(
        roomId: group.roomId,
        canonicalAlias: group.canonicalAlias,
      )) {
        _dismissedPublicGroupKeys.add(key);
      }
    }
    await _saveDismissedPublicGroups();
    _cachedPublicGroups = null;
    _cachedPublicGroupsAt = null;

    try {
      final client = await connect();
      final userId = client.userID?.trim() ?? '';
      if (userId.isEmpty) return;
      final existing = client.accountData[_deletedGroupsAccountDataType];
      final existingGroups = existing?.content['groups'];
      final groups = <String, Object?>{};
      if (existingGroups is Map) {
        for (final entry in existingGroups.entries) {
          groups[entry.key.toString()] = entry.value;
        }
      }
      for (final group in deleted) {
        for (final key in _publicGroupKeys(
          roomId: group.roomId,
          canonicalAlias: group.canonicalAlias,
        )) {
          groups[key] = {'deleted_at': timestamp};
        }
      }
      await client.setAccountData(userId, _deletedGroupsAccountDataType, {
        'groups': groups,
        'updated_at': timestamp,
      });
    } catch (e) {
      apkLog(
        'Matrix.groups',
        'deleted group account sync failed count=${deleted.length} error="$e"',
      );
    }
    apkLog(
      'Matrix.groups',
      'deleted group tombstones persisted count=${deleted.length}',
    );
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
      try {
        await client
            .waitForRoomInSync(roomId, join: true)
            .timeout(const Duration(seconds: 12));
      } catch (e) {
        apkLog(
          'Matrix.groups',
          'join room_id="$roomId" succeeded but room not available after wait error="$e"',
        );
      }
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

  Future<void> removeGroupMember({
    required String roomId,
    required String userId,
    String? reason,
  }) async {
    final room = getRoomById(roomId);
    if (room == null || !isMatrixGroupRoom(room)) {
      throw StateError('Member removal is only available in group rooms');
    }
    final currentUserId = room.client.userID?.trim() ?? '';
    final targetUserId = userId.trim();
    if (currentUserId.isEmpty || targetUserId.isEmpty) {
      throw StateError('Invalid Matrix user');
    }
    if (!isGroupOwner(room) || !room.canKick) {
      throw StateError('Only the group owner can remove members');
    }
    if (targetUserId == currentUserId) {
      throw StateError('The group owner cannot remove themselves');
    }
    if (room.getPowerLevelByUserId(targetUserId) >= room.ownPowerLevel) {
      throw StateError('You cannot remove a member with equal or higher power');
    }
    await room.client.kick(
      room.id,
      targetUserId,
      reason: reason ?? 'Removed by group owner',
    );
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
    if (room.getState('com.wrytte.group.info') != null) return false;
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
      if (!isVerifiedDirectRoomFor(room.id, matrixUserId)) continue;
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
