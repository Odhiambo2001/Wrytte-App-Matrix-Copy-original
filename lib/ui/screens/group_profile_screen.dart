import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/widgets/full_screen_image_viewer.dart';
import 'package:wrytte/ui/widgets/full_screen_video_viewer.dart';
import 'package:wrytte/ui/widgets/wrytte_file_card.dart';
import 'package:wrytte/ui/widgets/wrytte_link_preview.dart';
import 'package:wrytte/ui/widgets/wrytte_persistent_image.dart';
import 'package:wrytte/ui/widgets/wrytte_video_thumbnail.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

class GroupProfileScreen extends StatefulWidget {
  final String roomId;
  final String groupName;
  final String? avatarUrl;
  final String? alias;
  final int? initialMemberCount;
  final bool initiallyJoined;

  const GroupProfileScreen({
    super.key,
    required this.roomId,
    required this.groupName,
    this.avatarUrl,
    this.alias,
    this.initialMemberCount,
    this.initiallyJoined = true,
  });

  @override
  State<GroupProfileScreen> createState() => _GroupProfileScreenState();
}

class _GroupProfileScreenState extends State<GroupProfileScreen> {
  final Map<String, String> _memberNames = {};
  final Map<String, String> _memberAvatars = {};
  List<mx.User> _members = const [];
  List<String> _cachedMemberIds = const [];
  String? _localAvatarOverride;
  late bool _joined;
  bool _joiningOrLeaving = false;

  @override
  void initState() {
    super.initState();
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    _joined = widget.initiallyJoined || room?.membership == mx.Membership.join;
    _loadMemberProfiles();
  }

  @override
  Widget build(BuildContext context) {
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    final alias = _displayAlias(room?.canonicalAlias ?? widget.alias ?? '');
    final title = _displayTitle(room?.name ?? '', widget.groupName, alias);
    final memberCount = _memberCount;
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 560;
          final avatarSize = compact ? 84.0 : 112.0;
          final titleSize = compact ? 23.0 : 28.0;
          final actionHeight = compact ? 62.0 : 74.0;

          return DefaultTabController(
            length: 5,
            child: Column(
              children: [
                SizedBox(height: compact ? top * 0.5 : top),
                SizedBox(
                  height: compact ? 48 : kToolbarHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        _roundButton(
                          Icons.arrow_back_ios_new,
                          () => Navigator.pop(context),
                        ),
                        const Spacer(),
                        if (_canEditGroup(room)) _editButton(),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: compact ? 8 : 18),
                UserAvatar(
                  size: avatarSize,
                  imageUrl: widget.avatarUrl ?? room?.avatar?.toString(),
                  localImagePath: _localAvatarOverride,
                  name: title,
                ),
                SizedBox(height: compact ? 10 : 18),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: titleSize,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (alias.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    alias,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF4DA3FF),
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  _memberCountLabel(memberCount),
                  style: const TextStyle(color: Colors.white54, fontSize: 16),
                ),
                SizedBox(height: compact ? 14 : 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      _joinLeaveAction(height: actionHeight),
                      const SizedBox(width: 12),
                      _action(
                        Icons.volume_off_outlined,
                        'Mute',
                        height: actionHeight,
                      ),
                      const SizedBox(width: 12),
                      _action(Icons.search, 'Search', height: actionHeight),
                      const SizedBox(width: 12),
                      _action(Icons.more_horiz, 'More', height: actionHeight),
                    ],
                  ),
                ),
                SizedBox(height: compact ? 14 : 26),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFF111318),
                      borderRadius: BorderRadius.circular(23),
                      border: Border.all(color: const Color(0xFF242830)),
                    ),
                    child: TabBar(
                      isScrollable: true,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 18),
                      indicator: BoxDecoration(
                        color: const Color(0xFF23262C),
                        borderRadius: BorderRadius.circular(23),
                      ),
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white54,
                      labelStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      dividerColor: Colors.transparent,
                      tabs: const [
                        Tab(text: 'Members'),
                        Tab(text: 'Media'),
                        Tab(text: 'Files'),
                        Tab(text: 'Feed'),
                        Tab(text: 'Links'),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: compact ? 10 : 18),
                Expanded(
                  child: TabBarView(
                    children: [
                      _membersTab(widget.roomId),
                      _mediaTab(),
                      _filesTab(),
                      _emptyTab('No feed'),
                      _linksTab(),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _displayAlias(String value) {
    final alias = value.trim();
    if (alias.isEmpty) return '';
    final withoutHash = alias.startsWith('#') ? alias.substring(1) : alias;
    final local = withoutHash.split(':').first;
    return local;
  }

  String _displayTitle(String roomName, String fallbackName, String alias) {
    for (final candidate in [roomName, fallbackName]) {
      final value = candidate.trim();
      if (value.isEmpty) continue;
      if (alias.isNotEmpty && value == alias) continue;
      if (value.startsWith('gr.@')) continue;
      return value;
    }
    return 'Group';
  }

  Widget _roundButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(
          color: Color(0xFF15181D),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _editButton() {
    return GestureDetector(
      onTap: _openEditGroup,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF15181D),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Text(
          'Edit',
          style: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  bool _canEditGroup(mx.Room? room) {
    return room != null &&
        room.membership == mx.Membership.join &&
        MatrixChatService.instance.isGroupOwner(room);
  }

  Widget _action(IconData icon, String label, {double height = 74}) {
    return Expanded(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF15181D),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF242830)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(height: 7),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _joinLeaveAction({double height = 74}) {
    final label = _joined ? 'Leave' : 'Join';
    final icon = _joined ? Icons.logout_rounded : Icons.login_rounded;
    return Expanded(
      child: GestureDetector(
        onTap: _joiningOrLeaving ? null : _toggleMembership,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF15181D),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF242830)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_joiningOrLeaving)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                Icon(icon, color: Colors.white, size: 24),
              const SizedBox(height: 7),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _membersTab(String roomId) {
    final members = _members;
    final matrixMemberIds = members.map((member) => member.id).toSet();
    final cachedMembers =
        _cachedMemberIds.where((id) => !matrixMemberIds.contains(id)).toList();
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        GestureDetector(
          onTap: _openAddMembers,
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF111318),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Row(
              children: [
                SizedBox(width: 18),
                Icon(Icons.person_add_alt_1, color: Color(0xFF4DA3FF)),
                SizedBox(width: 12),
                Text(
                  'Add Members',
                  style: TextStyle(
                    color: Color(0xFF4DA3FF),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        for (final member in members)
          Builder(
            builder: (_) {
              final name = _displayMemberName(
                member.id,
                member.calcDisplayname(),
              );
              final avatar =
                  _memberAvatars[member.id] ?? member.avatarUrl?.toString();
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(size: 44, imageUrl: avatar, name: name),
                title: Text(name, style: const TextStyle(color: Colors.white)),
              );
            },
          ),
        for (final memberId in cachedMembers)
          Builder(
            builder: (_) {
              final name = _displayMemberName(memberId, memberId);
              final avatar = _memberAvatars[memberId];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(size: 44, imageUrl: avatar, name: name),
                title: Text(name, style: const TextStyle(color: Colors.white)),
              );
            },
          ),
      ],
    );
  }

  Widget _emptyTab(String label) {
    return Center(
      child: Text(label, style: const TextStyle(color: Colors.white38)),
    );
  }

  Widget _mediaTab() {
    final items =
        _roomMessages
            .where(
              (m) => m.attachmentType == 'image' || m.attachmentType == 'video',
            )
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (items.isEmpty) return _emptyTab('No media');
    return GridView.builder(
      padding: const EdgeInsets.all(14),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (_, index) => _mediaTile(items[index]),
    );
  }

  Widget _filesTab() {
    final items =
        _roomMessages.where((m) => m.attachmentType == 'file').toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (items.isEmpty) return _emptyTab('No files');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: items.length,
      itemBuilder: (_, index) {
        final item = items[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: WrytteFileCard(
            source: item.attachmentUrl ?? '',
            fileName: item.content.trim().isEmpty ? 'File' : item.content,
            profileStyle: true,
          ),
        );
      },
    );
  }

  Widget _linksTab() {
    final links =
        _roomMessages
            .map((m) => _firstLinkIn(m.content))
            .whereType<String>()
            .toList();
    if (links.isEmpty) return _emptyTab('No links');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      itemCount: links.length,
      itemBuilder:
          (_, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: WrytteLinkPreview(
              url: links[index],
              showOriginalUrl: true,
              compact: true,
            ),
          ),
    );
  }

  Widget _mediaTile(ChatMessage message) {
    final url = message.attachmentUrl?.trim() ?? '';
    if (message.attachmentType == 'video') {
      return GestureDetector(
        onTap: () => FullScreenVideoViewer.open(context, url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              WrytteVideoThumbnail(source: url),
              Container(
                color: Colors.black.withValues(alpha: 0.18),
                child: const Center(
                  child: Icon(Icons.play_arrow_rounded, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: () => FullScreenImageViewer.open(context, url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: WryttePersistentImage(source: url, fit: BoxFit.cover),
      ),
    );
  }

  List<ChatMessage> get _roomMessages =>
      ChatService().getConversationMessages(widget.roomId);

  String? _firstLinkIn(String value) {
    return RegExp(r'https?://[^\s]+').firstMatch(value)?.group(0);
  }

  Future<void> _openEditGroup() async {
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    if (room == null) return;
    final result = await Navigator.push<_GroupEditResult>(
      context,
      MaterialPageRoute(
        builder:
            (_) => _EditGroupScreen(
              roomId: widget.roomId,
              initialName: _displayTitle(
                room.name,
                widget.groupName,
                _displayAlias(
                  room.canonicalAlias.isNotEmpty
                      ? room.canonicalAlias
                      : widget.alias ?? '',
                ),
              ),
              initialAlias: _displayAlias(
                room.canonicalAlias.isNotEmpty
                    ? room.canonicalAlias
                    : widget.alias ?? '',
              ),
              initialAvatarUrl: widget.avatarUrl ?? room.avatar?.toString(),
            ),
      ),
    );
    if (!mounted || result == null) return;
    if (result.closedProfile) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      if (result.localAvatarPath != null) {
        _localAvatarOverride = result.localAvatarPath;
      }
    });
    _loadMemberProfiles();
  }

  Future<void> _openAddMembers() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _AddGroupMembersScreen(roomId: widget.roomId),
      ),
    );
    if (!mounted) return;
    _loadMemberProfiles();
  }

  Future<void> _toggleMembership() async {
    if (_joiningOrLeaving) return;
    if (_joined && !await _confirmLeaveGroup()) {
      apkLog('GroupProfile.leave', 'confirmation cancelled');
      return;
    }
    setState(() => _joiningOrLeaving = true);
    try {
      if (_joined) {
        final shouldLeave = await _showGroupUndoWindow(
          context,
          title: 'Leaving Group',
          message: 'Leaving this group in',
          logTag: 'GroupProfile.leave',
          onShownLog: 'undo window shown',
          onUndoLog: 'undo tapped',
          onExpiredLog: 'countdown expired; leaving Matrix room',
        );
        if (!mounted) return;
        if (!shouldLeave) {
          setState(() => _joiningOrLeaving = false);
          return;
        }
        await _leaveJoinedGroup();
        if (!mounted) return;
        Navigator.pop(context, true);
      } else {
        await MatrixChatService.instance.joinGroup(
          widget.alias?.trim().isNotEmpty == true
              ? widget.alias!
              : widget.roomId,
        );
        if (!mounted) return;
        setState(() {
          _joined = true;
          _joiningOrLeaving = false;
        });
        _loadMemberProfiles();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _joiningOrLeaving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Group update failed: $e')));
    }
  }

  Future<bool> _confirmLeaveGroup() async {
    final title = _displayTitle(
      MatrixChatService.instance.getRoomById(widget.roomId)?.name ?? '',
      widget.groupName,
      widget.alias ?? '',
    );
    return await showDialog<bool>(
          context: context,
          builder:
              (_) => AlertDialog(
                backgroundColor: const Color(0xFF111318),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                title: const Text(
                  'Leave Group',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                content: Text(
                  'Do you want to leave the group $title?',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                actions: [
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF23262C),
                      foregroundColor: const Color(0xFFE85D75),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: const Text('Leave'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF23262C),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
        ) ??
        false;
  }

  Future<void> _leaveJoinedGroup() async {
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    final alias = room?.canonicalAlias ?? widget.alias;
    await MatrixChatService.instance.leaveGroup(widget.roomId);
    await MatrixChatService.instance.dismissPublicGroup(
      roomId: widget.roomId,
      canonicalAlias: alias,
    );
    await ChatService().removeConversationLocally(widget.roomId);
  }

  int get _memberCount {
    if (_members.isNotEmpty || _cachedMemberIds.isNotEmpty) {
      return {
        ..._members.map((member) => member.id),
        ..._cachedMemberIds,
      }.length;
    }
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    if (room != null) {
      final count = MatrixChatService.instance.groupMemberCount(room);
      if (count > 0) return count;
    }
    final initial = widget.initialMemberCount;
    if (initial != null && initial > 0) return initial;
    return 1;
  }

  String _memberCountLabel(int count) {
    return count == 1 ? '1 member' : '$count members';
  }

  void _loadMemberProfiles() {
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    _loadCachedMemberProfiles();
    if (room == null || room.membership != mx.Membership.join) {
      _setMembers(const []);
      return;
    }
    final members = room.getParticipants(_groupMemberships);
    _setMembers(members);
    for (final member in members) {
      unawaited(
        _loadMemberProfile(
          member.id,
          fallbackName: member.calcDisplayname(),
          fallbackAvatar: member.avatarUrl?.toString(),
        ),
      );
    }
    unawaited(_requestFullMemberList(room));
  }

  void _loadCachedMemberProfiles() {
    final cachedMembers = _cachedConversationMemberIds();
    _setCachedMembers(cachedMembers);
    for (final memberId in cachedMembers) {
      unawaited(
        _loadMemberProfile(memberId, fallbackName: _matrixLocalpart(memberId)),
      );
    }
  }

  Future<void> _requestFullMemberList(mx.Room room) async {
    try {
      final members = await room.requestParticipants(
        _groupMemberships,
        true,
        true,
      );
      if (!mounted) return;
      _setMembers(members);
      for (final member in members) {
        unawaited(
          _loadMemberProfile(
            member.id,
            fallbackName: member.calcDisplayname(),
            fallbackAvatar: member.avatarUrl?.toString(),
          ),
        );
      }
    } catch (_) {
      // The room snapshot is still useful if the full member request fails.
    }
  }

  void _setMembers(List<mx.User> members) {
    final seen = <String>{};
    final unique = <mx.User>[];
    for (final member in members) {
      if (seen.add(member.id)) unique.add(member);
    }
    _members = unique;
    if (mounted) setState(() {});
  }

  void _setCachedMembers(List<String> memberIds) {
    final seen = <String>{};
    final unique = <String>[];
    for (final memberId in memberIds) {
      final id = memberId.trim();
      if (id.isEmpty || id.startsWith('!')) continue;
      if (seen.add(id)) unique.add(id);
    }
    _cachedMemberIds = unique;
    if (mounted) setState(() {});
  }

  List<String> _cachedConversationMemberIds() {
    for (final conversation in ChatService().cachedConversationsSnapshot) {
      if (conversation.id == widget.roomId) {
        return conversation.participants;
      }
    }
    return const [];
  }

  Future<void> _loadMemberProfile(
    String matrixId, {
    required String fallbackName,
    String? fallbackAvatar,
  }) async {
    final fallback = _cleanMemberName(fallbackName);
    if (fallback.isNotEmpty && !_memberNames.containsKey(matrixId)) {
      _memberNames[matrixId] = fallback;
    }
    final avatar = fallbackAvatar?.trim() ?? '';
    if (avatar.isNotEmpty && !_memberAvatars.containsKey(matrixId)) {
      _memberAvatars[matrixId] = avatar;
    }
    if (mounted) setState(() {});

    try {
      final localpart = _matrixLocalpart(matrixId);
      final currentUserId = await AuthService.instance.getCurrentUserId();
      final isMe =
          localpart.isNotEmpty &&
          _matrixLocalpart(currentUserId ?? '') == localpart;
      final UserProfile? profile =
          isMe
              ? await UserProfileService.instance.getCurrentUserProfile(
                forceRefresh: false,
              )
              : await UserProfileService.instance.getProfileByUid(
                localpart.isNotEmpty ? localpart : matrixId,
                forceRefresh: false,
              );
      if (!mounted || profile == null) return;

      final profileName = _cleanMemberName(profile.displayName);
      final profileAvatar = profile.profileImage.trim();
      setState(() {
        if (profileName.isNotEmpty) _memberNames[matrixId] = profileName;
        if (profileAvatar.isNotEmpty) _memberAvatars[matrixId] = profileAvatar;
      });
    } catch (_) {
      // Keep the Matrix fallback if the backend profile is unavailable.
    }
  }

  String _displayMemberName(String matrixId, String fallbackName) {
    final resolved = _cleanMemberName(_memberNames[matrixId] ?? '');
    if (resolved.isNotEmpty) return resolved;
    final fallback = _cleanMemberName(fallbackName);
    if (fallback.isNotEmpty) return fallback;
    return 'Member';
  }

  String _cleanMemberName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final localpart = _matrixLocalpart(trimmed);
    if (RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart)) {
      return '';
    }
    if (trimmed.startsWith('@') && trimmed.contains(':')) return '';
    return trimmed;
  }

  String _matrixLocalpart(String value) {
    var trimmed = value.trim();
    if (trimmed.startsWith('@')) trimmed = trimmed.substring(1);
    final colon = trimmed.indexOf(':');
    if (colon >= 0) trimmed = trimmed.substring(0, colon);
    return trimmed;
  }

  static const List<mx.Membership> _groupMemberships = [
    mx.Membership.join,
    mx.Membership.invite,
  ];
}

class _GroupEditResult {
  final String? localAvatarPath;
  final bool closedProfile;

  const _GroupEditResult({this.localAvatarPath, this.closedProfile = false});
}

Future<bool> _showGroupUndoWindow(
  BuildContext context, {
  required String title,
  required String message,
  String? logTag,
  String? onShownLog,
  String? onUndoLog,
  String? onExpiredLog,
}) async {
  if (logTag != null && onShownLog != null) {
    apkLog(logTag, onShownLog);
  }
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder:
            (_) => _GroupUndoDialog(
              title: title,
              message: message,
              logTag: logTag,
              onUndoLog: onUndoLog,
              onExpiredLog: onExpiredLog,
            ),
      ) ??
      false;
}

class _GroupUndoDialog extends StatefulWidget {
  final String title;
  final String message;
  final String? logTag;
  final String? onUndoLog;
  final String? onExpiredLog;

  const _GroupUndoDialog({
    required this.title,
    required this.message,
    this.logTag,
    this.onUndoLog,
    this.onExpiredLog,
  });

  @override
  State<_GroupUndoDialog> createState() => _GroupUndoDialogState();
}

class _GroupUndoDialogState extends State<_GroupUndoDialog> {
  static const int _undoSeconds = 3;
  Timer? _timer;
  int _remainingSeconds = _undoSeconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_remainingSeconds <= 1) {
        timer.cancel();
        _writeLog(widget.onExpiredLog);
        Navigator.of(context).pop(true);
        return;
      }
      setState(() => _remainingSeconds -= 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _writeLog(String? message) {
    final tag = widget.logTag;
    if (tag == null || message == null) return;
    apkLog(tag, message);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: const Color(0xFF111318),
        insetPadding: const EdgeInsets.symmetric(horizontal: 42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${widget.message} $_remainingSeconds...',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    _writeLog(widget.onUndoLog);
                    Navigator.of(context).pop(false);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF23262C),
                    foregroundColor: const Color(0xFF4DA3FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text('Undo'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditGroupScreen extends StatefulWidget {
  final String roomId;
  final String initialName;
  final String initialAlias;
  final String? initialAvatarUrl;

  const _EditGroupScreen({
    required this.roomId,
    required this.initialName,
    required this.initialAlias,
    this.initialAvatarUrl,
  });

  @override
  State<_EditGroupScreen> createState() => _EditGroupScreenState();
}

class _EditGroupScreenState extends State<_EditGroupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _aliasController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  File? _pickedImageFile;
  bool _saving = false;
  bool _leaving = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    _nameController.text = widget.initialName;
    _aliasController.text = widget.initialAlias;
    _descriptionController.text = room?.topic ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _aliasController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null) return;
      setState(() => _pickedImageFile = File(picked.path));
    } catch (_) {
      _showSnack('Could not select photo.', isError: true);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    if (room == null) {
      _showSnack('Group is unavailable.', isError: true);
      return;
    }
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showSnack('Group name is required.', isError: true);
      return;
    }

    setState(() => _saving = true);
    try {
      String? localAvatarPath;
      if (_pickedImageFile != null) {
        final matrixFile = mx.MatrixFile(
          bytes: await _pickedImageFile!.readAsBytes(),
          name: _pickedImageFile!.path.split(Platform.pathSeparator).last,
        );
        await room.setAvatar(matrixFile);
        localAvatarPath = _pickedImageFile!.path;
      }

      if (name != room.name.trim()) {
        await room.setName(name);
      }

      final alias = _cleanAlias(_aliasController.text);
      final currentAlias = _cleanAlias(room.canonicalAlias);
      if (alias.isNotEmpty && alias != currentAlias) {
        await room.setCanonicalAlias('#$alias:${MatrixConfig.serverName}');
      }

      final description = _descriptionController.text.trim();
      if (description != room.topic.trim()) {
        await room.setDescription(description);
      }

      if (!mounted) return;
      Navigator.pop(
        context,
        _GroupEditResult(localAvatarPath: localAvatarPath),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showSnack('Failed to save group: $e', isError: true);
    }
  }

  Future<void> _leaveGroup() async {
    if (_leaving || _deleting) return;
    setState(() => _leaving = true);
    try {
      final shouldLeave = await _showGroupUndoWindow(
        context,
        title: 'Leaving Group',
        message: 'Leaving this group in',
        logTag: 'GroupProfile.leave',
        onShownLog: 'undo window shown',
        onUndoLog: 'undo tapped',
        onExpiredLog: 'countdown expired; leaving Matrix room',
      );
      if (!mounted) return;
      if (!shouldLeave) {
        setState(() => _leaving = false);
        return;
      }
      final room = MatrixChatService.instance.getRoomById(widget.roomId);
      await MatrixChatService.instance.leaveGroup(widget.roomId);
      await MatrixChatService.instance.dismissPublicGroup(
        roomId: widget.roomId,
        canonicalAlias: room?.canonicalAlias,
      );
      await ChatService().removeConversationLocally(widget.roomId);
      if (!mounted) return;
      Navigator.pop(context, const _GroupEditResult(closedProfile: true));
    } catch (e) {
      if (!mounted) return;
      setState(() => _leaving = false);
      _showSnack('Failed to leave group: $e', isError: true);
    }
  }

  Future<void> _deleteGroup() async {
    if (_deleting || _leaving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (_) => AlertDialog(
            backgroundColor: const Color(0xFF23262C),
            title: const Text(
              'Delete Group',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'This will remove all joined and invited members, then leave and remove the group from this device.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Color(0xFFE85D75)),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true) return;

    setState(() => _deleting = true);
    try {
      final shouldDelete = await _showGroupUndoWindow(
        context,
        title: 'Deleting Group',
        message: 'Deleting this group in',
      );
      if (!shouldDelete) {
        if (!mounted) return;
        setState(() => _deleting = false);
        return;
      }
      final room = MatrixChatService.instance.getRoomById(widget.roomId);
      if (room != null) {
        await _removeMembersAndClose(room);
        await MatrixChatService.instance.dismissPublicGroup(
          roomId: widget.roomId,
          canonicalAlias: room.canonicalAlias,
        );
      }
      await ChatService().removeConversationLocally(widget.roomId);
      if (!mounted) return;
      Navigator.pop(context, const _GroupEditResult(closedProfile: true));
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _showSnack('Failed to delete group: $e', isError: true);
    }
  }

  String _cleanAlias(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final withoutHash =
        trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
    final localpart = withoutHash.split(':').first.trim();
    return localpart.replaceAll(RegExp(r'\s+'), '');
  }

  Future<void> _removeMembersAndClose(mx.Room room) async {
    final currentUserId = room.client.userID?.trim() ?? '';
    final members =
        room.getParticipants([
          mx.Membership.join,
          mx.Membership.invite,
        ]).toList();

    for (final member in members) {
      final userId = member.id.trim();
      if (userId.isEmpty || userId == currentUserId) continue;
      await room.kick(userId);
    }

    if (room.membership == mx.Membership.join) {
      await room.leave();
    }
    await room.forget();
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor:
            isError ? const Color(0xFFE05252) : const Color(0xFF4DA3FF),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _inputPill(
    String hint,
    TextEditingController controller, {
    FontWeight fontWeight = FontWeight.w400,
    Color? textColor,
    String? prefixText,
    int maxLines = 1,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF23262C),
        borderRadius: BorderRadius.circular(24),
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        style: TextStyle(
          color: textColor ?? Colors.white,
          fontSize: 16,
          fontWeight: fontWeight,
        ),
        decoration: InputDecoration(
          hintText: hint,
          prefixText: prefixText,
          prefixStyle: TextStyle(
            color: textColor ?? Colors.white,
            fontSize: 16,
            fontWeight: fontWeight,
          ),
          hintStyle: const TextStyle(color: Color(0xFF9A9CA3)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 14,
          ),
        ),
      ),
    );
  }

  Widget _valuePill(String label, String value, {Color? valueColor}) {
    final hasLabel = label.trim().isNotEmpty;
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF23262C),
        borderRadius: BorderRadius.circular(27),
      ),
      child: Row(
        children: [
          if (hasLabel) ...[
            Text(
              label,
              style: const TextStyle(color: Color(0xFF9A9CA3), fontSize: 16),
            ),
            const Spacer(),
          ],
          Text(
            value,
            style: TextStyle(color: valueColor ?? Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _avatar() {
    if (_pickedImageFile != null) {
      return ClipOval(
        child: Image.file(
          _pickedImageFile!,
          width: 142,
          height: 142,
          fit: BoxFit.cover,
        ),
      );
    }

    final imageUrl = widget.initialAvatarUrl?.trim() ?? '';
    if (imageUrl.isNotEmpty) {
      return UserAvatar(
        size: 142,
        imageUrl: imageUrl,
        name: _nameController.text,
      );
    }

    return Container(
      width: 142,
      height: 142,
      decoration: const BoxDecoration(
        color: Color(0xFF0E4B86),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.camera_alt_rounded,
        color: Color(0xFF4DA3FF),
        size: 58,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF08090B);
    const accent = Color(0xFF4DA3FF);
    const danger = Color(0xFFE85D75);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white, fontSize: 17),
              ),
            ),
            TextButton(
              onPressed: _saving ? null : _save,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child:
                  _saving
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                      : const Text(
                        'Save',
                        style: TextStyle(color: Colors.white, fontSize: 17),
                      ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(
            children: [
              const SizedBox(height: 34),
              GestureDetector(onTap: _pickImage, child: _avatar()),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: _pickImage,
                child: const Text(
                  'Set new photo',
                  style: TextStyle(color: accent, fontSize: 16),
                ),
              ),
              const SizedBox(height: 28),
              _inputPill(
                'Group name',
                _nameController,
                fontWeight: FontWeight.w800,
              ),
              const SizedBox(height: 14),
              _inputPill('Alias', _aliasController, textColor: accent),
              const SizedBox(height: 14),
              _inputPill('Description', _descriptionController, maxLines: 1),
              const SizedBox(height: 14),
              _valuePill('Link', 'Add'),
              const SizedBox(height: 14),
              _valuePill('Channel', 'Add'),
              const SizedBox(height: 180),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF23262C),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  children: [
                    TextButton(
                      onPressed: _deleting ? null : _deleteGroup,
                      child:
                          _deleting
                              ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: danger,
                                ),
                              )
                              : const Text(
                                'Delete Group',
                                style: TextStyle(color: danger, fontSize: 16),
                              ),
                    ),
                    TextButton(
                      onPressed: _leaving ? null : _leaveGroup,
                      child:
                          _leaving
                              ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: danger,
                                ),
                              )
                              : const Text(
                                'Leave Group',
                                style: TextStyle(color: danger, fontSize: 16),
                              ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddGroupMembersScreen extends StatefulWidget {
  final String roomId;

  const _AddGroupMembersScreen({required this.roomId});

  @override
  State<_AddGroupMembersScreen> createState() => _AddGroupMembersScreenState();
}

class _AddGroupMembersScreenState extends State<_AddGroupMembersScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedKeys = {};
  List<Contact> _contacts = const [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    final owner = await AuthService.instance.getCurrentUserId() ?? '';
    if (owner.trim().isEmpty) return;
    final contacts = await ContactLocalDb.loadSavedContacts(ownerUserId: owner);
    final existing = _existingMemberIds();
    if (!mounted) return;
    setState(() {
      _contacts =
          contacts.where((contact) {
              final key = _contactKey(contact);
              return key.isNotEmpty && !existing.contains(_toMatrixUserId(key));
            }).toList()
            ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
    });
  }

  Set<String> _existingMemberIds() {
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    return {
      for (final user
          in room?.getParticipants([
                mx.Membership.join,
                mx.Membership.invite,
              ]) ??
              const <mx.User>[])
        user.id,
    };
  }

  String _contactKey(Contact contact) {
    return (contact.wrytteUserId?.trim().isNotEmpty == true
                ? contact.wrytteUserId
                : contact.primaryPhone)
            ?.trim() ??
        '';
  }

  String _toMatrixUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    final localpart = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
    return '@$localpart:${MatrixConfig.serverName}';
  }

  List<Contact> get _visibleContacts {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _contacts;
    return _contacts
        .where(
          (contact) =>
              contact.formattedName.toLowerCase().contains(query) ||
              contact.primaryPhone.toLowerCase().contains(query),
        )
        .toList();
  }

  Future<void> _addMembers() async {
    if (_saving || _selectedKeys.isEmpty) return;
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    if (room == null) return;
    setState(() => _saving = true);
    try {
      for (final key in _selectedKeys) {
        await room.invite(_toMatrixUserId(key));
      }
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to add member: $e')));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                  const Expanded(
                    child: Text(
                      'Add members',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed:
                        _selectedKeys.isEmpty || _saving ? null : _addMembers,
                    child:
                        _saving
                            ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Text('Add'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF23262C),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, color: Colors.white38),
                    hintText: 'Search',
                    hintStyle: TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child:
                  _visibleContacts.isEmpty
                      ? const Center(
                        child: Text(
                          'No contacts to add',
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                      : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        itemCount: _visibleContacts.length,
                        itemBuilder: (context, index) {
                          final contact = _visibleContacts[index];
                          final key = _contactKey(contact);
                          final selected = _selectedKeys.contains(key);
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 6,
                            ),
                            leading: UserAvatar(
                              imageUrl: contact.avatarUrl,
                              name: contact.formattedName,
                              size: 54,
                            ),
                            title: Text(
                              contact.formattedName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle:
                                contact.primaryPhone.isEmpty
                                    ? null
                                    : Text(
                                      contact.primaryPhone,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                      ),
                                    ),
                            trailing: Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color:
                                  selected
                                      ? const Color(0xFF1ECB6B)
                                      : Colors.white38,
                            ),
                            onTap: () {
                              if (key.isEmpty) return;
                              setState(() {
                                if (selected) {
                                  _selectedKeys.remove(key);
                                } else {
                                  _selectedKeys.add(key);
                                }
                              });
                            },
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}
