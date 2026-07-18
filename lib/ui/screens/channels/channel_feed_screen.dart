import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/chat/chat_service.dart';

class ChannelFeedScreen extends StatefulWidget {
  final String conversationId;
  final String currentUserId;
  final String title;
  final String? avatarUrl;
  final List<ChatMessage> initialPosts;
  final int subscriberCount;

  const ChannelFeedScreen({
    super.key,
    required this.conversationId,
    required this.currentUserId,
    required this.title,
    this.avatarUrl,
    this.initialPosts = const [],
    this.subscriberCount = 0,
  });

  @override
  State<ChannelFeedScreen> createState() => _ChannelFeedScreenState();
}

class _ChannelFeedScreenState extends State<ChannelFeedScreen> {
  final ChatService _chat = ChatService();
  final TextEditingController _postController = TextEditingController();
  StreamSubscription<List<ChatMessage>>? _postsSubscription;
  late List<ChatMessage> _posts;
  final Set<String> _repostedPostIds = {};
  final Set<String> _likedPostIds = {};
  final Set<String> _bookmarkedPostIds = {};
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _posts = List<ChatMessage>.from(widget.initialPosts);
    _loadPosts();
    _postsSubscription = _chat.messagesStreamFor(widget.conversationId).listen((
      posts,
    ) {
      if (!mounted) return;
      setState(() => _posts = List<ChatMessage>.from(posts));
    });
  }

  @override
  void dispose() {
    _postsSubscription?.cancel();
    _postController.dispose();
    super.dispose();
  }

  Future<void> _loadPosts() async {
    final posts = await _chat.hydrateConversation(widget.conversationId);
    if (!mounted) return;
    setState(() => _posts = posts);
  }

  Future<void> _publishPost() async {
    final content = _postController.text.trim();
    if (content.isEmpty || _publishing) return;
    setState(() => _publishing = true);
    _postController.clear();
    try {
      await _chat.sendMessage(
        ChatMessage(
          id: 'opt_${DateTime.now().millisecondsSinceEpoch}',
          conversationId: widget.conversationId,
          senderId: widget.currentUserId,
          receiverId: widget.conversationId,
          content: content,
          timestamp: DateTime.now(),
          status: MessageStatus.sending,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not publish post: $error')));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  String get _subscriberLabel {
    final count = widget.subscriberCount;
    return '$count ${count == 1 ? 'subscriber' : 'subscribers'}';
  }

  @override
  Widget build(BuildContext context) {
    final posts =
        _posts.where((post) => !post.isDeletedForMe).toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Column(
          children: [
            _channelHeader(),
            Expanded(
              child:
                  posts.isEmpty
                      ? const Center(
                        child: Text(
                          'No posts yet',
                          style: TextStyle(color: Colors.white54, fontSize: 16),
                        ),
                      )
                      : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 22, 20, 112),
                        itemCount: posts.length,
                        separatorBuilder:
                            (_, __) => const Divider(
                              color: Color(0xFF22242A),
                              height: 28,
                            ),
                        itemBuilder: (_, index) => _channelPost(posts[index]),
                      ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _postComposer(),
    );
  }

  Widget _channelHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(
        children: [
          _circleButton(
            Icons.arrow_back_ios_new,
            () => Navigator.pop(context),
            size: 64,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 76,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF23262C),
                borderRadius: BorderRadius.circular(38),
              ),
              child: Row(
                children: [
                  UserAvatar(
                    imageUrl: widget.avatarUrl,
                    name: widget.title,
                    size: 54,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _subscriberLabel,
                            maxLines: 1,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          _circleButton(Icons.more_vert, () {}, size: 64),
        ],
      ),
    );
  }

  Widget _channelPost(ChatMessage post) {
    final hasImage =
        post.attachmentType == 'image' &&
        (post.attachmentUrl?.trim().isNotEmpty ?? false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(imageUrl: widget.avatarUrl, name: widget.title, size: 56),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    ' · ${_postAge(post.timestamp)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ],
              ),
              if (hasImage) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
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
                const SizedBox(height: 12),
                Text(
                  post.content,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _postActions(post),
            ],
          ),
        ),
      ],
    );
  }

  Widget _postActions(ChatMessage post) {
    final postId = post.id;
    final commentCount =
        _posts
            .where((candidate) => candidate.replyToMessageId == postId)
            .length;
    final reposted = _repostedPostIds.contains(postId);
    final liked = _likedPostIds.contains(postId);
    final bookmarked = _bookmarkedPostIds.contains(postId);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _PostAction(
          icon: Icons.mode_comment_outlined,
          label: _formatCount(commentCount),
          onTap: () => _showUnavailable('Comments'),
        ),
        _PostAction(
          icon: Icons.repeat,
          label: _formatCount(reposted ? 1 : 0),
          color: reposted ? const Color(0xFF4DA3FF) : null,
          onTap: () => _toggleRepost(postId),
        ),
        _PostAction(
          icon: liked ? Icons.favorite : Icons.favorite_border,
          label: _formatCount(liked ? 1 : 0),
          color: liked ? const Color(0xFFE85D75) : null,
          onTap: () => _toggleLike(postId),
        ),
        _PostAction(
          icon: Icons.ios_share_outlined,
          onTap: () => _showUnavailable('Sharing'),
        ),
        _PostAction(
          icon: bookmarked ? Icons.bookmark : Icons.bookmark_border,
          color: bookmarked ? const Color(0xFF4DA3FF) : null,
          onTap: () => _toggleBookmark(postId),
        ),
        _PostAction(
          icon: Icons.more_horiz,
          onTap: () => _showUnavailable('More options'),
        ),
      ],
    );
  }

  void _toggleRepost(String postId) {
    setState(() {
      if (!_repostedPostIds.add(postId)) _repostedPostIds.remove(postId);
    });
  }

  void _toggleLike(String postId) {
    setState(() {
      if (!_likedPostIds.add(postId)) _likedPostIds.remove(postId);
    });
  }

  void _toggleBookmark(String postId) {
    setState(() {
      if (!_bookmarkedPostIds.add(postId)) _bookmarkedPostIds.remove(postId);
    });
  }

  void _showUnavailable(String feature) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$feature will be available soon.')));
  }

  String? _formatCount(int count) {
    if (count == 0) return null;
    if (count < 1000) return '$count';
    return '${(count / 1000).toStringAsFixed(count % 1000 == 0 ? 0 : 1)}K';
  }

  Widget _postComposer() {
    return SafeArea(
      top: false,
      child: Container(
        height: 82,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        decoration: const BoxDecoration(color: Color(0xFF08090B)),
        child: Row(
          children: [
            _circleButton(Icons.add, () {}, size: 54),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: const Color(0xFF23262C),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: TextField(
                  controller: _postController,
                  onSubmitted: (_) => _publishPost(),
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                  decoration: const InputDecoration(
                    hintText: 'Write post',
                    hintStyle: TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            _circleButton(
              _publishing ? Icons.hourglass_top : Icons.camera_alt_outlined,
              () {},
              size: 54,
            ),
          ],
        ),
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback? onTap, {double size = 68}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xFF23262C),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.42),
      ),
    );
  }

  String _postAge(DateTime timestamp) {
    final elapsed = DateTime.now().difference(timestamp);
    if (elapsed.inMinutes < 1) return 'now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m';
    if (elapsed.inDays < 1) return '${elapsed.inHours}h';
    if (elapsed.inDays < 30) return '${elapsed.inDays}d';
    return '${(elapsed.inDays / 30).floor()}mo';
  }
}

class _PostAction extends StatelessWidget {
  final IconData icon;
  final String? label;
  final Color? color;
  final VoidCallback? onTap;

  const _PostAction({required this.icon, this.label, this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final actionColor = color ?? const Color(0xFF8C8F95);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: actionColor, size: 27),
            if (label != null) ...[
              const SizedBox(width: 5),
              Text(label!, style: TextStyle(color: actionColor)),
            ],
          ],
        ),
      ),
    );
  }
}
