import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/ui/screens/channels/channel_edit_screen.dart';
import 'package:wrytte/ui/screens/group_profile_screen.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/ui/widgets/full_screen_image_viewer.dart';
import 'package:wrytte/ui/widgets/full_screen_video_viewer.dart';
import 'package:wrytte/ui/widgets/wrytte_video_thumbnail.dart';
import 'package:wrytte/ui/widgets/wrytte_video_player.dart';

/// Profile page for a channel, opened by tapping the channel header.
/// Layout mirrors the reference: centered avatar, name, @handle,
/// subscriber count, action buttons and Posts/Highlights/Updates/Reposts tabs.
class ChannelProfileScreen extends StatefulWidget {
  final String conversationId;
  final String currentUserId;
  final String title;
  final String? avatarUrl;
  final int subscriberCount;
  final List<ChatMessage> posts;
  final bool isOwner;
  final bool isSubscribed;
  final String? subscribeAlias;

  const ChannelProfileScreen({
    super.key,
    required this.conversationId,
    required this.currentUserId,
    required this.title,
    this.avatarUrl,
    this.subscriberCount = 0,
    this.posts = const [],
    this.isOwner = true,
    this.isSubscribed = false,
    this.subscribeAlias,
  });

  @override
  State<ChannelProfileScreen> createState() => _ChannelProfileScreenState();
}

class _ChannelProfileScreenState extends State<ChannelProfileScreen> {
  static const _tabs = ['Posts', 'Highlights', 'Updates', 'Reposts'];
  int _selectedTab = 0;

  // Editable channel info (seeded from the widget, updated after editing).
  late String _title;
  late bool _isSubscribed;
  String? _avatarUrl;
  String? _customHandle;
  String _description = '';

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _isSubscribed = widget.isSubscribed;
    _avatarUrl = widget.avatarUrl;
    final room = MatrixChatService.instance.getRoomById(widget.conversationId);
    _description = room?.topic.trim() ?? '';
  }

  /// "@carsandtrucks" style handle: the user-edited one if set,
  /// otherwise derived from the channel title.
  String get _handle {
    final custom = _customHandle?.trim() ?? '';
    if (custom.isNotEmpty) {
      return custom.startsWith('@') ? custom : '@$custom';
    }
    final slug = _title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return '@${slug.isEmpty ? 'channel' : slug}';
  }

  String get _avatarCacheIdentity =>
      MatrixChatService.instance.roomProfileCacheIdentity(
        accountId: widget.currentUserId,
        roomId: widget.conversationId,
        avatarUrl: _avatarUrl,
        room: MatrixChatService.instance.getRoomById(widget.conversationId),
      );

  /// Open the edit page and apply the returned changes.
  Future<void> _openEditScreen() async {
    final result = await Navigator.push<ChannelEditResult>(
      context,
      MaterialPageRoute(
        builder:
            (_) => ChannelEditScreen(
              title: _title,
              handle: _handle,
              conversationId: widget.conversationId,
              description: _description.isEmpty ? null : _description,
              avatarUrl: _avatarUrl,
            ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.deleted) {
      Navigator.pop(context, result.pendingAction);
      return;
    }
    setState(() {
      _title = result.name;
      _customHandle = result.handle;
      _description = result.description;
      _avatarUrl = result.avatarUrl ?? _avatarUrl;
    });
  }

  String get _subscriberLabel {
    final count = widget.subscriberCount;
    return '$count ${count == 1 ? 'subscriber' : 'subscribers'}';
  }

  /// Top-level (non-reply, non-deleted) posts, newest first.
  List<ChatMessage> get _topLevelPosts {
    final posts =
        widget.posts
            .where(
              (post) =>
                  !post.isDeletedForMe &&
                  (post.replyToMessageId?.isEmpty ?? true),
            )
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return posts;
  }

  bool _hasVisualMedia(ChatMessage post) =>
      const {'image', 'video'}.contains(post.attachmentType) &&
      (post.attachmentUrl?.trim().isNotEmpty ?? false);

  /// Media contains every publication with an image or video. Captions do not
  /// affect whether an item appears in this gallery.
  List<ChatMessage> get _mediaPosts =>
      _topLevelPosts.where(_hasVisualMedia).toList();

  /// Updates contains text-only publications. A caption attached to media
  /// remains part of its post and is not duplicated here.
  List<ChatMessage> get _textUpdatePosts =>
      _topLevelPosts
          .where(
            (post) => !_hasVisualMedia(post) && post.content.trim().isNotEmpty,
          )
          .toList();

  List<ChatMessage> get _repostPosts =>
      _topLevelPosts.where((post) => post.isForwarded).toList();

  void _showUnavailable(String feature) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$feature will be available soon.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            _profileHeader(),
            const SizedBox(height: 16),
            _actionButtons(),
            const SizedBox(height: 14),
            _tabBar(),
            const SizedBox(height: 4),
            Expanded(child: _tabContent()),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ top bar

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          InkWell(
            onTap: () => Navigator.pop(context),
            borderRadius: BorderRadius.circular(24),
            child: Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                color: Color(0xFF23262C),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_back_ios_new,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
          const Spacer(),
          if (widget.isOwner)
            InkWell(
              onTap: _openEditScreen,
              borderRadius: BorderRadius.circular(24),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: const Color(0xFF23262C),
                  borderRadius: BorderRadius.circular(22),
                ),
                alignment: Alignment.center,
                child: const Text(
                  'Edit',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ header

  Widget _profileHeader() {
    return Column(
      children: [
        UserAvatar(
          imageUrl: _avatarUrl,
          cacheIdentity: _avatarCacheIdentity,
          name: _title,
          size: 96,
        ),
        const SizedBox(height: 12),
        Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 21,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _handle,
          style: const TextStyle(
            color: Color(0xFF4DA3FF),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _subscriberLabel,
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
        if (_description.isNotEmpty) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Text(
              _description,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFB7BAC1),
                fontSize: 15,
                height: 1.35,
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------- action buttons

  Widget _actionButtons() {
    if (!widget.isOwner) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            if (_isSubscribed)
              _actionButton(
                icon: Icons.logout,
                label: 'Leave',
                onTap: _leaveChannel,
              )
            else
              _actionButton(
                icon: Icons.person_add_alt_1,
                label: 'Subscribe',
                onTap: _subscribeChannel,
              ),
            const SizedBox(width: 10),
            _actionButton(
              icon: Icons.ios_share_outlined,
              label: 'Share',
              onTap: _shareChannel,
            ),
            const SizedBox(width: 10),
            _actionButton(
              icon: Icons.search,
              label: 'Search',
              onTap: () => _showUnavailable('Searching posts'),
            ),
            const SizedBox(width: 10),
            _actionButton(
              icon: Icons.notifications_off_outlined,
              label: 'Mute',
              enabled: _isSubscribed,
              onTap: () => _showUnavailable('Muting channels'),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _actionButton(
            icon: Icons.bolt_outlined,
            label: 'Boost',
            onTap: () => _showUnavailable('Boosting'),
          ),
          const SizedBox(width: 10),
          _actionButton(
            icon: Icons.shortcut,
            label: 'Share',
            onTap: () => _showUnavailable('Sharing'),
          ),
          const SizedBox(width: 10),
          _actionButton(
            icon: Icons.search,
            label: 'Search',
            onTap: () => _showUnavailable('Searching posts'),
          ),
          const SizedBox(width: 10),
          _actionButton(
            icon: Icons.more_horiz,
            label: 'More',
            onTap: () => _showUnavailable('More options'),
          ),
        ],
      ),
    );
  }

  Future<void> _subscribeChannel() async {
    final alias = widget.subscribeAlias?.trim() ?? '';
    if (alias.isEmpty) return;
    try {
      await MatrixChatService.instance.joinGroup(alias);
      if (mounted) setState(() => _isSubscribed = true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not subscribe: $error')));
      }
    }
  }

  Future<void> _shareChannel() async {
    final room = MatrixChatService.instance.getRoomById(widget.conversationId);
    final alias = room?.canonicalAlias.trim();
    final link =
        (alias?.isNotEmpty == true)
            ? 'https://matrix.to/#/${Uri.encodeComponent(alias!)}'
            : 'https://matrix.to/#/${Uri.encodeComponent(widget.conversationId)}';
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Channel link copied')));
    }
  }

  Future<void> _leaveChannel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Leave channel?'),
            content: const Text(
              'You will no longer receive posts from this channel.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Leave'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    final room = MatrixChatService.instance.getRoomById(widget.conversationId);
    final alias = room?.canonicalAlias;
    if (mounted) {
      Navigator.pop(
        context,
        GroupExitRequest.leave(
          roomId: widget.conversationId,
          isChannel: true,
          commit: () async {
            await ChatService().dismissDeletedGroupLocally(
              widget.conversationId,
            );
            await MatrixChatService.instance.markPublicGroupDeleted(
              roomId: widget.conversationId,
              canonicalAlias: alias,
            );
            await MatrixChatService.instance.leaveGroup(widget.conversationId);
          },
        ),
      );
    }
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Expanded(
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(26),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            color: const Color(0xFF23262C),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: enabled ? Colors.white : Colors.white38,
                size: 20,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? Colors.white : Colors.white38,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------- tabs

  Widget _tabBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        height: 46,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFF15171B),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Row(
          children: List.generate(_tabs.length, (index) {
            final selected = index == _selectedTab;
            return Expanded(
              child: InkWell(
                onTap: () => setState(() => _selectedTab = index),
                borderRadius: BorderRadius.circular(22),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFF23262C) : null,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Text(
                    _tabs[index],
                    style: TextStyle(
                      color: selected ? Colors.white : const Color(0xFF8C8F95),
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _tabContent() {
    switch (_selectedTab) {
      case 0:
        return _postsTab();
      case 1:
        return _emptyState('No highlights yet');
      case 2:
        return _updatesTab();
      case 3:
      default:
        return _repostsTab();
    }
  }

  Widget _emptyState(String message) {
    return Center(
      child: Text(
        message,
        style: const TextStyle(color: Colors.white54, fontSize: 16),
      ),
    );
  }

  // --------------------------------------------------------------- posts tab

  Widget _postsTab() {
    return _mediaGrid();
  }

  Widget _updatesTab() {
    return _postList(_textUpdatePosts, emptyMessage: 'No updates yet');
  }

  Widget _repostsTab() {
    return _postList(_repostPosts, emptyMessage: 'No reposts yet');
  }

  Widget _postList(List<ChatMessage> posts, {required String emptyMessage}) {
    if (posts.isEmpty) return _emptyState(emptyMessage);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: posts.length,
      separatorBuilder:
          (_, __) => Padding(
            padding: const EdgeInsets.only(left: 52, top: 14, bottom: 14),
            child: SizedBox(
              height: 0.6,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: double.infinity,
                maxHeight: 0.6,
                child: SizedBox(
                  width: MediaQuery.sizeOf(context).width - 72,
                  child: const Divider(
                    color: Color(0xFF3A3D42),
                    thickness: 0.6,
                    height: 0.6,
                  ),
                ),
              ),
            ),
          ),
      itemBuilder: (_, index) => _postTile(posts[index]),
    );
  }

  Widget _mediaGrid() {
    if (_mediaPosts.isEmpty) return _emptyState('No media yet');
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 0.72,
      ),
      itemCount: _mediaPosts.length,
      itemBuilder: (_, index) => _mediaTile(_mediaPosts[index]),
    );
  }

  Widget _mediaTile(ChatMessage post) {
    final url = post.attachmentUrl!.trim();
    final isVideo = post.attachmentType == 'video';
    return GestureDetector(
      onTap:
          () =>
              isVideo
                  ? FullScreenVideoViewer.open(context, url)
                  : FullScreenImageViewer.open(context, url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isVideo)
              WrytteVideoThumbnail(source: url)
            else
              CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder:
                    (_, __) => const ColoredBox(color: Color(0xFF23262C)),
                errorWidget:
                    (_, __, ___) => const ColoredBox(
                      color: Color(0xFF23262C),
                      child: Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white54,
                        ),
                      ),
                    ),
              ),
            if (isVideo)
              const Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(7),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _postTile(ChatMessage post) {
    final hasImage =
        post.attachmentType == 'image' &&
        (post.attachmentUrl?.trim().isNotEmpty ?? false);
    final hasVideo =
        post.attachmentType == 'video' &&
        (post.attachmentUrl?.trim().isNotEmpty ?? false);
    final aspectRatio =
        post.mediaWidth != null &&
                post.mediaHeight != null &&
                post.mediaHeight! > 0
            ? post.mediaWidth! / post.mediaHeight!
            : null;
    final portrait = aspectRatio != null ? aspectRatio < 1 : hasImage;
    final isNineBySixteenMedia =
        (hasImage && aspectRatio == null) ||
        ((hasImage || hasVideo) &&
            aspectRatio != null &&
            (aspectRatio - 9 / 16).abs() <= 0.08);
    final postContent = _mediaDisplayContent(post, hasImage || hasVideo);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(
          imageUrl: _avatarUrl,
          cacheIdentity: _avatarCacheIdentity,
          name: _title,
          size: 40,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$_title · ${_postAge(post.timestamp)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF8C8F95), fontSize: 13),
              ),
              if (hasImage || hasVideo) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.only(
                    right:
                        isNineBySixteenMedia
                            ? 0
                            : portrait
                            ? 50
                            : 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: isNineBySixteenMedia ? 0.70 : 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child:
                            hasVideo
                                ? (aspectRatio == null
                                    ? WrytteVideoPlayer(
                                      source: post.attachmentUrl!,
                                      autoPlayWhenVisible: true,
                                      startMuted: true,
                                      showRemainingTime: true,
                                    )
                                    : AspectRatio(
                                      aspectRatio: aspectRatio,
                                      child: WrytteVideoPlayer(
                                        source: post.attachmentUrl!,
                                        autoPlayWhenVisible: true,
                                        startMuted: true,
                                        showRemainingTime: true,
                                      ),
                                    ))
                                : AspectRatio(
                                  aspectRatio:
                                      isNineBySixteenMedia
                                          ? 9 / 16
                                          : aspectRatio ?? 9 / 16,
                                  child: CachedNetworkImage(
                                    imageUrl: post.attachmentUrl!,
                                    fit: BoxFit.cover,
                                    placeholder:
                                        (_, __) => const ColoredBox(
                                          color: Color(0xFF23262C),
                                          child: Center(
                                            child: CircularProgressIndicator(
                                              color: Color(0xFF4DA3FF),
                                            ),
                                          ),
                                        ),
                                    errorWidget:
                                        (_, __, ___) => const ColoredBox(
                                          color: Color(0xFF23262C),
                                          child: Center(
                                            child: Icon(
                                              Icons.broken_image_outlined,
                                              color: Colors.white54,
                                            ),
                                          ),
                                        ),
                                  ),
                                ),
                      ),
                    ),
                  ),
                ),
              ],
              if (postContent.isNotEmpty) ...[
                SizedBox(height: hasImage || hasVideo ? 8 : 4),
                Text(
                  postContent,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    height: 1.18,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _profilePostActions(post),
            ],
          ),
        ),
      ],
    );
  }

  String _mediaDisplayContent(ChatMessage post, bool hasMedia) {
    final content = post.content.trim();
    if (!hasMedia || content.isEmpty) return content;
    final isGeneratedFilename = RegExp(
      r'^[^/\\]+\.(?:jpg|jpeg|png|gif|webp|svg|mp4|mov|m4v|avi|mkv)$',
      caseSensitive: false,
    ).hasMatch(content);
    return isGeneratedFilename ? '' : content;
  }

  Widget _profilePostActions(ChatMessage post) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: 28,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _profileAction(Icons.comment_outlined, '100'),
            const SizedBox(width: 28),
            _profileAction(Icons.repeat, '100'),
            const SizedBox(width: 28),
            _profileAction(Icons.favorite_border, '100'),
            const SizedBox(width: 28),
            _profileAction(Icons.ios_share_outlined, ''),
            const SizedBox(width: 2),
            _profileAction(Icons.bookmark_border, ''),
            const SizedBox(width: 28),
            _profileAction(Icons.more_horiz, ''),
          ],
        ),
      ),
    );
  }

  Widget _profileAction(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Transform.translate(
        offset: Offset.zero,
        child: Icon(icon, color: const Color(0xFF8C8F95), size: 20),
      ),
      if (label.isNotEmpty) ...[
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF8C8F95), fontSize: 14),
        ),
      ],
    ],
  );

  String _postAge(DateTime timestamp) {
    final elapsed = DateTime.now().difference(timestamp);
    if (elapsed.inMinutes < 1) return 'now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m';
    if (elapsed.inDays < 1) return '${elapsed.inHours}h';
    if (elapsed.inDays < 30) return '${elapsed.inDays}d';
    if (elapsed.inDays < 365) return '${(elapsed.inDays / 30).floor()}mo';
    return '${(elapsed.inDays / 365).floor()}y';
  }
}
