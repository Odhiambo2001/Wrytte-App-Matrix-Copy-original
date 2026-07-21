import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/ui/screens/channels/channel_edit_screen.dart';

/// Profile page for a channel, opened by tapping the channel header.
/// Layout mirrors the reference: centered avatar, name, @handle,
/// subscriber count, action buttons and Posts/Media/Highlights/Reposts tabs.
class ChannelProfileScreen extends StatefulWidget {
  final String conversationId;
  final String currentUserId;
  final String title;
  final String? avatarUrl;
  final int subscriberCount;
  final List<ChatMessage> posts;
  final bool isOwner;

  const ChannelProfileScreen({
    super.key,
    required this.conversationId,
    required this.currentUserId,
    required this.title,
    this.avatarUrl,
    this.subscriberCount = 0,
    this.posts = const [],
    this.isOwner = true,
  });

  @override
  State<ChannelProfileScreen> createState() => _ChannelProfileScreenState();
}

class _ChannelProfileScreenState extends State<ChannelProfileScreen> {
  static const _tabs = ['Posts', 'Media', 'Highlights', 'Reposts'];
  int _selectedTab = 0;

  // Editable channel info (seeded from the widget, updated after editing).
  late String _title;
  String? _customHandle;
  String _description = '';

  @override
  void initState() {
    super.initState();
    _title = widget.title;
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
              avatarUrl: widget.avatarUrl,
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

  List<ChatMessage> get _mediaPosts =>
      _topLevelPosts
          .where(
            (post) =>
                post.attachmentType == 'image' &&
                (post.attachmentUrl?.trim().isNotEmpty ?? false),
          )
          .toList();

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
        UserAvatar(imageUrl: widget.avatarUrl, name: _title, size: 96),
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
      ],
    );
  }

  // ---------------------------------------------------------- action buttons

  Widget _actionButtons() {
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

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
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
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
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
        return _mediaTab();
      case 2:
        return _emptyState('No highlights yet');
      case 3:
      default:
        return _emptyState('No reposts yet');
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
    final posts = _topLevelPosts;
    if (posts.isEmpty) return _emptyState('No posts yet');
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: posts.length,
      separatorBuilder:
          (_, __) => const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(
              color: Color(0xFF3A3D42),
              thickness: 0.6,
              height: 0.6,
            ),
          ),
      itemBuilder: (_, index) => _postTile(posts[index]),
    );
  }

  Widget _postTile(ChatMessage post) {
    final hasImage =
        post.attachmentType == 'image' &&
        (post.attachmentUrl?.trim().isNotEmpty ?? false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(imageUrl: widget.avatarUrl, name: _title, size: 40),
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
              if (hasImage) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 4 / 5,
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
              ],
              if (post.content.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  post.content,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------- media tab

  Widget _mediaTab() {
    final media = _mediaPosts;
    if (media.isEmpty) return _emptyState('No media yet');
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: media.length,
      itemBuilder: (_, index) {
        final post = media[index];
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: post.attachmentUrl!,
            fit: BoxFit.cover,
            placeholder: (_, __) => const ColoredBox(color: Color(0xFF23262C)),
            errorWidget:
                (_, __, ___) => const ColoredBox(
                  color: Color(0xFF23262C),
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                  ),
                ),
          ),
        );
      },
    );
  }

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
