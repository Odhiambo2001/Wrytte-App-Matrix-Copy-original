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
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/profile_screen.dart';
import 'package:wrytte/ui/screens/calls/call_screen.dart';
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
  static const String _groupInfoStateType = 'com.wrytte.group.info';
  final Map<String, String> _memberNames = {};
  final Map<String, String> _memberAvatars = {};
  final Map<String, String> _memberPhones = {};
  final Map<String, String> _savedContactNamesByUserId = {};
  final Map<String, String> _savedContactNamesByPhone = {};
  final Map<String, String> _savedContactAvatarsByUserId = {};
  final Map<String, String> _savedContactAvatarsByPhone = {};
  List<mx.User> _members = const [];
  List<String> _cachedMemberIds = const [];
  String? _localAvatarOverride;
  late bool _joined;
  bool _joiningOrLeaving = false;
  StreamSubscription<String>? _contactsChangedSub;
  StreamSubscription<mx.SyncUpdate>? _matrixSyncSub;
  Timer? _matrixRefreshDebounce;

  @override
  void initState() {
    super.initState();
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    _joined = widget.initiallyJoined || room?.membership == mx.Membership.join;
    _subscribeToProfileUpdates();
    unawaited(_initialiseMemberProfiles());
  }

  @override
  void dispose() {
    _contactsChangedSub?.cancel();
    _matrixSyncSub?.cancel();
    _matrixRefreshDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    final alias = _displayAlias(room?.canonicalAlias ?? widget.alias ?? '');
    final title = _displayTitle(room?.name ?? '', widget.groupName, alias);
    final isDeleted = ChatService().isConversationDeleted(widget.roomId);
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
                  key: ValueKey(
                    MatrixChatService.instance.roomProfileCacheIdentity(
                      accountId: room?.client.userID ?? '',
                      roomId: widget.roomId,
                      avatarUrl: _safeGroupRoomAvatarUrl(room),
                      room: room,
                    ),
                  ),
                  size: avatarSize,
                  imageUrl: _safeGroupRoomAvatarUrl(room),
                  cacheIdentity: MatrixChatService.instance
                      .roomProfileCacheIdentity(
                        accountId: room?.client.userID ?? '',
                        roomId: widget.roomId,
                        avatarUrl: _safeGroupRoomAvatarUrl(room),
                        room: room,
                      ),
                  localImagePath: _localAvatarOverride,
                  name: title,
                  isDeleted: isDeleted,
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
                if (_roomDescription(room).isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _roomDescription(room),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
                if (_roomProfileLink(room).isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _roomProfileLink(room),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF4DA3FF),
                      fontSize: 14,
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
                      _joined
                          ? _voiceChatAction(height: actionHeight)
                          : _joinLeaveAction(height: actionHeight),
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

  String _roomDescription(mx.Room? room) => room?.topic.trim() ?? '';

  String _roomProfileLink(mx.Room? room) =>
      room?.getState(_groupInfoStateType)?.content['link']?.toString().trim() ??
      '';

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
    const label = 'Join';
    const icon = Icons.login_rounded;
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

  Widget _voiceChatAction({double height = 74}) {
    return Expanded(
      child: GestureDetector(
        onTap: _startVoiceChat,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF15181D),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF242830)),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.call_outlined, color: Colors.white, size: 24),
              SizedBox(height: 7),
              Text(
                'Voice Chat',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startVoiceChat() async {
    try {
      await CallService.instance.makeGroupVoiceCall(roomId: widget.roomId);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => CallScreen(
                remoteUserId: widget.roomId,
                remoteUserName: _displayTitle(
                  MatrixChatService.instance.getRoomById(widget.roomId)?.name ??
                      '',
                  widget.groupName,
                  widget.alias ?? '',
                ),
                remoteUserAvatar: _safeGroupRoomAvatarUrl(
                  MatrixChatService.instance.getRoomById(widget.roomId),
                ),
                type: CallType.voice,
                isCaller: true,
              ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start voice chat: $error')),
      );
    }
  }

  Widget _membersTab(String roomId) {
    if (ChatService().isConversationDeleted(roomId)) {
      return _emptyTab('No members');
    }
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
              if (name == null) return const SizedBox.shrink();
              final avatar = _displayMemberAvatar(
                member.id,
                member.avatarUrl?.toString(),
              );
              return ListTile(
                key: ValueKey('member:${widget.roomId}:${member.id}'),
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(size: 44, imageUrl: avatar, name: name),
                title: Text(name, style: const TextStyle(color: Colors.white)),
                onTap: () => _openMemberProfile(member.id, name),
              );
            },
          ),
        for (final memberId in cachedMembers)
          Builder(
            builder: (_) {
              final name = _displayMemberName(memberId, memberId);
              if (name == null) return const SizedBox.shrink();
              final avatar = _displayMemberAvatar(memberId, null);
              return ListTile(
                key: ValueKey('member:${widget.roomId}:$memberId'),
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(size: 44, imageUrl: avatar, name: name),
                title: Text(name, style: const TextStyle(color: Colors.white)),
                onTap: () => _openMemberProfile(memberId, name),
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
              initialAvatarUrl: _safeGroupRoomAvatarUrl(room),
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
    await MatrixChatService.instance.dismissPublicGroup(
      roomId: widget.roomId,
      canonicalAlias: alias,
    );
    await MatrixChatService.instance.leaveGroup(widget.roomId);
    await ChatService().removeConversationLocally(widget.roomId);
  }

  int get _memberCount {
    if (ChatService().isConversationDeleted(widget.roomId)) return 0;
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

  Future<void> _initialiseMemberProfiles() async {
    await _loadOwnerSavedContactNames();
    if (!mounted) return;
    await _loadSuggestedPreviewMemberProfiles();
    if (!mounted) return;
    _loadMemberProfiles();
  }

  void _subscribeToProfileUpdates() {
    _contactsChangedSub = ContactService.contactsChanged.listen((
      ownerId,
    ) async {
      final currentUserId = await AuthService.instance.getCurrentUserId();
      if (!mounted ||
          currentUserId == null ||
          ownerId.trim().toLowerCase() != currentUserId.trim().toLowerCase()) {
        return;
      }
      await _loadOwnerSavedContactNames();
      if (mounted) _loadMemberProfiles();
    });
    _matrixSyncSub = MatrixChatService.instance.syncStream.listen((_) {
      _matrixRefreshDebounce?.cancel();
      _matrixRefreshDebounce = Timer(const Duration(milliseconds: 250), () {
        if (!mounted) return;
        final room = MatrixChatService.instance.getRoomById(widget.roomId);
        _joined = room?.membership == mx.Membership.join || _joined;
        _loadMemberProfiles();
        setState(() {
          // The local file is only an immediate post-edit preview. Once Matrix
          // sync exposes authoritative room avatar state, stop overriding it.
          if (_safeGroupRoomAvatarUrl(room)?.isNotEmpty == true) {
            _localAvatarOverride = null;
          }
        }); // Re-read the complete room profile using this roomId.
      });
    });
  }

  void _openMemberProfile(String userId, String savedNameHint) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => ProfileScreen(
              uid: userId,
              conversationId: widget.roomId,
              savedNameHint: savedNameHint,
            ),
      ),
    );
  }

  Future<void> _loadSuggestedPreviewMemberProfiles() async {
    if (_joined) return;
    try {
      final members = await ChatService().loadSuggestedPreviewMembers(
        widget.roomId,
      );
      final memberIds = <String>[];
      for (final member in members) {
        final userId = member['userId']?.toString().trim() ?? '';
        if (userId.isEmpty) continue;
        memberIds.add(userId);
        final displayName = member['displayName']?.toString().trim() ?? '';
        final avatarUrl = member['avatarUrl']?.toString().trim() ?? '';
        if (displayName.isNotEmpty) _memberNames[userId] = displayName;
        if (avatarUrl.isNotEmpty) _memberAvatars[userId] = avatarUrl;
      }
      _setCachedMembers(memberIds);
      for (final userId in memberIds) {
        unawaited(
          _loadMemberProfile(
            userId,
            fallbackName: _memberNames[userId] ?? _matrixLocalpart(userId),
            fallbackAvatar: _memberAvatars[userId],
          ),
        );
      }
      apkLog(
        'SuggestedPreview',
        'members loaded room_id="${widget.roomId}" members=${memberIds.length}',
      );
    } catch (e) {
      apkLog(
        'SuggestedPreview',
        'members load failed room_id="${widget.roomId}" error="$e"',
      );
    }
  }

  void _loadMemberProfiles() {
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    if (ChatService().isConversationDeleted(widget.roomId)) {
      _setMembers(const []);
      _setCachedMembers(const []);
      return;
    }
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
    final cachedMembers =
        {..._cachedMemberIds, ..._cachedConversationMemberIds()}.toList();
    _setCachedMembers(cachedMembers);
    for (final memberId in cachedMembers) {
      unawaited(
        _loadMemberProfile(memberId, fallbackName: _matrixLocalpart(memberId)),
      );
    }
  }

  Future<void> _requestFullMemberList(mx.Room room) async {
    if (ChatService().isConversationDeleted(widget.roomId)) return;
    try {
      final members = await room.requestParticipants(
        _groupMemberships,
        true,
        true,
      );
      if (!mounted) return;
      if (ChatService().isConversationDeleted(widget.roomId)) {
        _setMembers(const []);
        _setCachedMembers(const []);
        return;
      }
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
    final savedName = _savedContactNameFor(matrixId);
    if (savedName != null) {
      _memberNames[matrixId] = savedName;
    } else if (fallback.isNotEmpty && !_memberNames.containsKey(matrixId)) {
      _memberNames[matrixId] = fallback;
    }
    final avatar = fallbackAvatar?.trim() ?? '';
    if (avatar.isNotEmpty && !_memberAvatars.containsKey(matrixId)) {
      _memberAvatars[matrixId] = avatar;
    }
    if (mounted) setState(() {});
    // Profile 2 is the complete local saved-contact representation and wins.
    if (savedName != null) return;

    try {
      final localpart = _matrixLocalpart(matrixId);
      final currentUserId = await AuthService.instance.getCurrentUserId();
      final localProfile1 =
          currentUserId == null || currentUserId.trim().isEmpty
              ? null
              : await ContactIdentityCache.instance.findByMatrixId(
                ownerUserId: currentUserId,
                matrixUserId: matrixId,
              );
      if (localProfile1 != null && mounted) {
        final profile1Name = _cleanMemberName(localProfile1.profileName ?? '');
        final profile1Avatar = localProfile1.avatarUrl?.trim() ?? '';
        final profile1Phone = _normalizePhone(localProfile1.phone ?? '');
        setState(() {
          if (_savedContactNameFor(matrixId, phone: profile1Phone) == null &&
              profile1Name.isNotEmpty) {
            _memberNames[matrixId] = profile1Name;
          }
          if (profile1Avatar.isNotEmpty) {
            _memberAvatars[matrixId] = profile1Avatar;
          }
          if (profile1Phone.isNotEmpty) {
            _memberPhones[matrixId] = profile1Phone;
          }
        });
        // A local Profile 1 exists; the BE is only consulted when neither
        // local Profile 2 nor local Profile 1 is available.
        return;
      }
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
      final profilePhone = _normalizePhone(profile.phone);
      final ownerSavedName = _savedContactNameFor(
        matrixId,
        phone: profilePhone,
      );
      setState(() {
        if (profilePhone.isNotEmpty) _memberPhones[matrixId] = profilePhone;
        if (ownerSavedName != null) {
          _memberNames[matrixId] = ownerSavedName;
        } else if (profileName.isNotEmpty) {
          _memberNames[matrixId] = profileName;
        }
        if (profileAvatar.isNotEmpty) _memberAvatars[matrixId] = profileAvatar;
      });
      if (currentUserId != null && currentUserId.trim().isNotEmpty) {
        await ContactIdentityCache.instance.upsert(
          ownerUserId: currentUserId,
          matrixUserId: matrixId,
          phone: profilePhone,
          profileName: profileName,
          avatarUrl: profileAvatar,
          bio: profile.bio,
        );
      }
    } catch (_) {
      // Keep the Matrix fallback if the backend profile is unavailable.
    }
  }

  Future<void> _loadOwnerSavedContactNames() async {
    try {
      final currentUserId = await AuthService.instance.getCurrentUserId();
      if (currentUserId == null || currentUserId.trim().isEmpty) return;
      final contacts = await ContactLocalDb.loadSavedContacts(
        ownerUserId: currentUserId,
      );
      if (!mounted) return;

      final byUserId = <String, String>{};
      final byPhone = <String, String>{};
      final avatarsByUserId = <String, String>{};
      final avatarsByPhone = <String, String>{};
      for (final contact in contacts) {
        final savedName = _cleanMemberName(contact.formattedName);
        if (savedName.isEmpty) continue;

        for (final key in _contactUserKeys(contact.wrytteUserId)) {
          byUserId[key] = savedName;
          final avatar = contact.avatarUrl?.trim() ?? '';
          if (avatar.isNotEmpty) avatarsByUserId[key] = avatar;
        }
        for (final phone in contact.phones) {
          final normalized = _normalizePhone(phone);
          if (normalized.isNotEmpty) {
            byPhone[normalized] = savedName;
            final avatar = contact.avatarUrl?.trim() ?? '';
            if (avatar.isNotEmpty) avatarsByPhone[normalized] = avatar;
          }
        }
      }

      setState(() {
        _savedContactNamesByUserId
          ..clear()
          ..addAll(byUserId);
        _savedContactNamesByPhone
          ..clear()
          ..addAll(byPhone);
        _savedContactAvatarsByUserId
          ..clear()
          ..addAll(avatarsByUserId);
        _savedContactAvatarsByPhone
          ..clear()
          ..addAll(avatarsByPhone);

        for (final member in _members) {
          final savedName = _savedContactNameFor(member.id);
          if (savedName != null) _memberNames[member.id] = savedName;
        }
        for (final memberId in _cachedMemberIds) {
          final savedName = _savedContactNameFor(memberId);
          if (savedName != null) _memberNames[memberId] = savedName;
        }
      });
    } catch (e) {
      apkLog('GroupProfile.members', 'saved contact names unavailable: $e');
    }
  }

  String? _displayMemberName(String matrixId, String fallbackName) {
    final savedName = _savedContactNameFor(matrixId);
    if (savedName != null) return savedName;
    final resolved = _cleanMemberName(_memberNames[matrixId] ?? '');
    if (resolved.isNotEmpty) return resolved;
    final fallback = _cleanMemberName(fallbackName);
    if (fallback.isNotEmpty) return fallback;
    return null;
  }

  String? _savedContactNameFor(String matrixId, {String? phone}) {
    for (final key in _contactUserKeys(matrixId)) {
      final name = _cleanMemberName(_savedContactNamesByUserId[key] ?? '');
      if (name.isNotEmpty) return name;
    }
    final normalizedPhone = _normalizePhone(
      phone ?? _memberPhones[matrixId] ?? '',
    );
    if (normalizedPhone.isNotEmpty) {
      final name = _cleanMemberName(
        _savedContactNamesByPhone[normalizedPhone] ?? '',
      );
      if (name.isNotEmpty) return name;
    }
    return null;
  }

  String? _displayMemberAvatar(String matrixId, String? matrixFallback) {
    for (final key in _contactUserKeys(matrixId)) {
      final avatar = _savedContactAvatarsByUserId[key]?.trim() ?? '';
      if (avatar.isNotEmpty) return avatar;
    }
    final phone = _normalizePhone(_memberPhones[matrixId] ?? '');
    if (phone.isNotEmpty) {
      final avatar = _savedContactAvatarsByPhone[phone]?.trim() ?? '';
      if (avatar.isNotEmpty) return avatar;
    }
    final backendAvatar = _memberAvatars[matrixId]?.trim() ?? '';
    if (backendAvatar.isNotEmpty) return backendAvatar;
    final roomMemberAvatar = matrixFallback?.trim() ?? '';
    return roomMemberAvatar.isEmpty ? null : roomMemberAvatar;
  }

  Iterable<String> _contactUserKeys(String? value) sync* {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return;
    yield trimmed.toLowerCase();
    final localpart = _matrixLocalpart(trimmed);
    if (localpart.isNotEmpty) yield localpart.toLowerCase();
    final matrixId = _toMatrixUserId(localpart);
    if (matrixId.isNotEmpty) yield matrixId.toLowerCase();
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return _stripInvalidNorthAmericaPrefix(cleaned);
  }

  String _stripInvalidNorthAmericaPrefix(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (!phone.startsWith('+1')) return phone;
    if (digits.length <= 11) return phone;
    return '+${digits.substring(1)}';
  }

  String _toMatrixUserId(String localpart) {
    final cleanLocalpart = localpart.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9._=-]'),
      '',
    );
    if (cleanLocalpart.isEmpty) return '';
    return '@$cleanLocalpart:${MatrixConfig.serverName}';
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

  String? _safeGroupRoomAvatarUrl(mx.Room? room) {
    final raw = room?.getState(mx.EventTypes.RoomAvatar)?.content['url'];
    final avatar = raw is String ? raw.trim() : '';
    if (avatar.isEmpty || _matchesGroupParticipantAvatar(room, avatar)) {
      return null;
    }
    return avatar;
  }

  bool _matchesGroupParticipantAvatar(mx.Room? room, String avatarUrl) {
    if (room == null) return false;
    final normalizedAvatar = _normaliseAvatarIdentity(avatarUrl);
    if (normalizedAvatar.isEmpty) return false;
    for (final member in room.getParticipants(_groupMemberships)) {
      if (member.id == room.client.userID) continue;
      final memberAvatar = _normaliseAvatarIdentity(
        member.avatarUrl?.toString(),
      );
      if (memberAvatar.isNotEmpty && memberAvatar == normalizedAvatar) {
        return true;
      }
    }
    return false;
  }

  String _normaliseAvatarIdentity(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed;
    if (uri.scheme == 'mxc') {
      return 'mxc://${uri.host}${uri.path}';
    }
    return trimmed;
  }
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
  static const String _groupInfoStateType = 'com.wrytte.group.info';

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _aliasController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _linkController = TextEditingController();
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
    _linkController.text =
        room?.getState(_groupInfoStateType)?.content['link']?.toString() ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _aliasController.dispose();
    _descriptionController.dispose();
    _linkController.dispose();
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
      var profileChanged = false;
      var avatarChanged = false;
      var nameChanged = false;
      var aliasChanged = false;
      var descriptionChanged = false;
      var linkChanged = false;
      if (_pickedImageFile != null) {
        final matrixFile = mx.MatrixFile(
          bytes: await _pickedImageFile!.readAsBytes(),
          name: _pickedImageFile!.path.split(Platform.pathSeparator).last,
        );
        await room.setAvatar(matrixFile);
        localAvatarPath = _pickedImageFile!.path;
        profileChanged = true;
        avatarChanged = true;
      }

      if (name != room.name.trim()) {
        await room.setName(name);
        profileChanged = true;
        nameChanged = true;
      }

      final alias = _cleanAlias(_aliasController.text);
      final currentAlias = _cleanAlias(room.canonicalAlias);
      if (alias.isNotEmpty && alias != currentAlias) {
        await room.setCanonicalAlias('#$alias:${MatrixConfig.serverName}');
        profileChanged = true;
        aliasChanged = true;
      }

      final description = _descriptionController.text.trim();
      if (description != room.topic.trim()) {
        await room.setDescription(description);
        profileChanged = true;
        descriptionChanged = true;
      }

      final link = _linkController.text.trim();
      final currentInfo = Map<String, dynamic>.from(
        room.getState(_groupInfoStateType)?.content ?? const {},
      );
      final currentLink = currentInfo['link']?.toString().trim() ?? '';
      if (link != currentLink) {
        if (link.isEmpty) {
          currentInfo.remove('link');
        } else {
          currentInfo['link'] = link;
        }
        profileChanged = true;
        linkChanged = true;
      }
      if (profileChanged) {
        void incrementVersion(String key) {
          final previous =
              int.tryParse(currentInfo[key]?.toString() ?? '') ?? 0;
          currentInfo[key] = previous + 1;
        }

        if (avatarChanged) incrementVersion('avatar_version');
        if (nameChanged) incrementVersion('name_version');
        if (aliasChanged) incrementVersion('alias_version');
        if (descriptionChanged) incrementVersion('description_version');
        if (linkChanged) incrementVersion('link_version');
        final previousVersion =
            int.tryParse(currentInfo['profile_version']?.toString() ?? '') ?? 0;
        currentInfo['profile_version'] = previousVersion + 1;
        currentInfo['updated_at'] = DateTime.now().toUtc().toIso8601String();
        await room.client.setRoomStateWithKey(
          room.id,
          _groupInfoStateType,
          '',
          currentInfo,
        );
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
    final ownedRoom = MatrixChatService.instance.getRoomById(widget.roomId);
    if (ownedRoom == null ||
        !MatrixChatService.instance.isGroupOwner(ownedRoom)) {
      _showSnack(
        'Only the user who created this group can delete it.',
        isError: true,
      );
      return;
    }
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
    if (!mounted) return;

    setState(() => _deleting = true);
    try {
      final shouldDelete = await _showGroupUndoWindow(
        context,
        title: 'Deleting Group',
        message: 'Deleting this group in',
        logTag: 'GroupProfile.delete',
        onShownLog: 'undo window shown',
        onUndoLog: 'undo tapped',
        onExpiredLog: 'countdown expired; announcing deletion',
      );
      if (!shouldDelete) {
        if (!mounted) return;
        setState(() => _deleting = false);
        return;
      }

      final room = MatrixChatService.instance.getRoomById(widget.roomId);
      if (room != null) {
        final deletedAt = DateTime.now().toUtc();
        final title =
            _nameController.text.trim().isNotEmpty
                ? _nameController.text.trim()
                : widget.initialName;

        // Dismiss FIRST — cheap local write, must persist even if the
        // network steps below rate-limit. Otherwise the group returns to
        // Suggested via the public directory.
        await MatrixChatService.instance.markPublicGroupDeleted(
          roomId: widget.roomId,
          canonicalAlias:
              room.canonicalAlias.isNotEmpty
                  ? room.canonicalAlias
                  : widget.initialAlias,
          deletedAt: deletedAt,
        );
        await ChatService().markGroupDeletedLocally(
          roomId: widget.roomId,
          name: title,
          avatarUrl: null,
          participants:
              room.getParticipants().map((member) => member.id).toList(),
          deletedAt: deletedAt,
          deletedBy: room.client.userID,
        );

        // Best-effort network cleanup — allowed to fail on M_LIMIT_EXCEEDED
        // without reverting the dismissal above.
        try {
          await _announceGroupDeleted(room, deletedAt);
          await _removeMembersAndClose(room);
        } catch (e) {
          apkLog(
            'GroupProfile.delete',
            'network cleanup failed (dismissal already persisted) room_id="${widget.roomId}" error="$e"',
          );
        }
      } else {
        final deletedAt = DateTime.now().toUtc();
        await ChatService().markGroupDeletedLocally(
          roomId: widget.roomId,
          name: widget.initialName,
          avatarUrl: widget.initialAvatarUrl,
          deletedAt: deletedAt,
        );
        await MatrixChatService.instance.markPublicGroupDeleted(
          roomId: widget.roomId,
          canonicalAlias: widget.initialAlias,
          deletedAt: deletedAt,
        );
      }
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
    // The creator can immediately remove the room from public discovery even
    // though the final database purge requires a Dendrite server admin.
    try {
      await room.client.setRoomVisibilityOnDirectory(
        room.id,
        visibility: mx.Visibility.private,
      );
    } catch (e) {
      apkLog(
        'GroupProfile.delete',
        'directory unpublish failed room_id="${room.id}" error="$e"',
      );
    }
    try {
      if (room.canChangeJoinRules) {
        await room.setJoinRules(mx.JoinRules.invite);
      }
    } catch (e) {
      apkLog(
        'GroupProfile.delete',
        'join rule close failed room_id="${room.id}" error="$e"',
      );
    }

    final currentUserId = room.client.userID?.trim() ?? '';
    final members =
        room.getParticipants([
          mx.Membership.join,
          mx.Membership.invite,
        ]).toList();

    for (final member in members) {
      final userId = member.id.trim();
      if (userId.isEmpty || userId == currentUserId) continue;
      try {
        await room.kick(userId);
      } catch (e) {
        apkLog(
          'GroupProfile.delete',
          'member removal failed room_id="${room.id}" user_id="$userId" error="$e"',
        );
      }
    }

    if (room.membership == mx.Membership.join) {
      await room.leave();
    }
    await room.forget();
  }

  Future<void> _announceGroupDeleted(mx.Room room, DateTime deletedAt) async {
    final deletedBy = room.client.userID?.trim() ?? '';
    final timestamp = deletedAt.toIso8601String();
    apkLog(
      'GroupProfile.delete',
      'announcing deleted room_id="${room.id}" deleted_at="$timestamp" deleted_by="$deletedBy"',
    );
    await room.sendEvent({
      'msgtype': mx.MessageTypes.Notice,
      'body': 'This group has been deleted at $timestamp',
      ChatService.groupDeletedEventKey: true,
      ChatService.groupDeletedAtKey: timestamp,
      if (deletedBy.isNotEmpty) ChatService.groupDeletedByKey: deletedBy,
    }, displayPendingEvent: false);
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

  Widget _valuePill(
    String label,
    String value, {
    Color? valueColor,
    VoidCallback? onTap,
    bool alignValueRight = true,
  }) {
    final hasLabel = label.trim().isNotEmpty;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: const Color(0xFF23262C),
          borderRadius: BorderRadius.circular(27),
        ),
        child: Row(
          children: [
            if (hasLabel) ...[
              SizedBox(
                width: 92,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9A9CA3),
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: alignValueRight ? TextAlign.right : TextAlign.left,
                style: TextStyle(
                  color: valueColor ?? Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editLink() async {
    final result = await showDialog<String>(
      context: context,
      builder:
          (context) => _GroupLinkDialog(initialValue: _linkController.text),
    );
    if (result == null || !mounted) return;
    setState(() => _linkController.text = result.trim());
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
              _valuePill(
                'Link',
                _linkController.text.trim().isEmpty
                    ? 'Add'
                    : _linkController.text.trim(),
                valueColor:
                    _linkController.text.trim().isEmpty
                        ? null
                        : const Color(0xFF4DA3FF),
                onTap: _saving ? null : _editLink,
                alignValueRight: _linkController.text.trim().isEmpty,
              ),
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
                      onPressed: null,
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

class _GroupLinkDialog extends StatefulWidget {
  final String initialValue;

  const _GroupLinkDialog({required this.initialValue});

  @override
  State<_GroupLinkDialog> createState() => _GroupLinkDialogState();
}

class _GroupLinkDialogState extends State<_GroupLinkDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close([String? value]) {
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF23262C),
      title: const Text('Group Link', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'https://example.com',
          hintStyle: TextStyle(color: Color(0xFF9A9CA3)),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF4DA3FF)),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF4DA3FF)),
          ),
        ),
        onSubmitted: (_) => _close(_controller.text),
      ),
      actions: [
        TextButton(
          onPressed: _close,
          child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: () => _close(''),
          child: const Text(
            'Remove',
            style: TextStyle(color: Color(0xFFE85D75)),
          ),
        ),
        TextButton(
          onPressed: () => _close(_controller.text),
          child: const Text('Done', style: TextStyle(color: Color(0xFF4DA3FF))),
        ),
      ],
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
