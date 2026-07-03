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
      body: DefaultTabController(
        length: 5,
        child: Column(
          children: [
            SizedBox(height: top),
            SizedBox(
              height: kToolbarHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _roundButton(
                      Icons.arrow_back_ios_new,
                      () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    _editButton(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            UserAvatar(
              size: 112,
              imageUrl: widget.avatarUrl ?? room?.avatar?.toString(),
              localImagePath: _localAvatarOverride,
              name: title,
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (alias.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                alias,
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
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  _joinLeaveAction(),
                  const SizedBox(width: 12),
                  _action(Icons.volume_off_outlined, 'Mute'),
                  const SizedBox(width: 12),
                  _action(Icons.search, 'Search'),
                  const SizedBox(width: 12),
                  _action(Icons.more_horiz, 'More'),
                ],
              ),
            ),
            const SizedBox(height: 26),
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
            const SizedBox(height: 18),
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
      onTap: _changeGroupAvatar,
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

  Widget _action(IconData icon, String label) {
    return Expanded(
      child: Container(
        height: 74,
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

  Widget _joinLeaveAction() {
    final label = _joined ? 'Leave' : 'Join';
    final icon = _joined ? Icons.logout_rounded : Icons.login_rounded;
    return Expanded(
      child: GestureDetector(
        onTap: _joiningOrLeaving ? null : _toggleMembership,
        child: Container(
          height: 74,
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

  Future<void> _changeGroupAvatar() async {
    final room = MatrixChatService.instance.getRoomById(widget.roomId);
    if (room == null) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    try {
      final file = File(picked.path);
      final matrixFile = mx.MatrixFile(
        bytes: await file.readAsBytes(),
        name: picked.name,
      );
      await room.setAvatar(matrixFile);
      if (!mounted) return;
      setState(() => _localAvatarOverride = picked.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update group avatar: $e')),
      );
    }
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
    setState(() => _joiningOrLeaving = true);
    try {
      if (_joined) {
        await MatrixChatService.instance.leaveGroup(widget.roomId);
        if (!mounted) return;
        setState(() {
          _joined = false;
          _members = const [];
          _joiningOrLeaving = false;
        });
      } else {
        final joinedFrom = DateTime.now();
        final room = await MatrixChatService.instance.joinGroup(
          widget.alias?.trim().isNotEmpty == true
              ? widget.alias!
              : widget.roomId,
        );
        if (room != null) {
          await ChatService().markGroupJoinedFrom(room.id, joinedFrom);
        }
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

  int get _memberCount {
    if (_members.isNotEmpty) return _members.length;
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
