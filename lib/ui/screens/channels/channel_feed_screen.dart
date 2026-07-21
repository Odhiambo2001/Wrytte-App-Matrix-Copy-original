import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/ui/screens/channels/channel_profile_screen.dart';
import 'package:wrytte/ui/screens/group_profile_screen.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/ui/widgets/wrytte_video_player.dart';

class ChannelFeedScreen extends StatefulWidget {
  final String conversationId;
  final String currentUserId;
  final String title;
  final String? avatarUrl;
  final List<ChatMessage> initialPosts;
  final int subscriberCount;
  final bool readOnlyUntilSubscribe;
  final String? subscribeAlias;
  final bool canPost;

  const ChannelFeedScreen({
    super.key,
    required this.conversationId,
    required this.currentUserId,
    required this.title,
    this.avatarUrl,
    this.initialPosts = const [],
    this.subscriberCount = 0,
    this.readOnlyUntilSubscribe = false,
    this.subscribeAlias,
    this.canPost = false,
  });

  @override
  State<ChannelFeedScreen> createState() => _ChannelFeedScreenState();
}

class _ChannelFeedScreenState extends State<ChannelFeedScreen> {
  final ChatService _chat = ChatService();
  final TextEditingController _postController = TextEditingController();
  StreamSubscription<List<ChatMessage>>? _postsSubscription;
  StreamSubscription? _syncSubscription;
  late List<ChatMessage> _posts;

  // Which posts THIS user has interacted with (drives icon highlight).
  final Set<String> _repostedPostIds = {};
  final Set<String> _likedPostIds = {};
  final Set<String> _bookmarkedPostIds = {};

  // Incremental per-post counters. Counts start at 0 and only move when an
  // interaction happens. When server-side reaction storage is added, seed
  // these maps from the server instead.
  final Map<String, int> _viewCounts = {};
  final Map<String, int> _repostCounts = {};
  final Map<String, int> _likeCounts = {};

  // A post counts one view per session, the first time it appears on screen.
  final Set<String> _viewedPostIds = {};

  bool _publishing = false;
  int _subscriberCount = 0;
  String? _channelAvatarUrl;

  String get _channelAvatarCacheIdentity =>
      MatrixChatService.instance.roomProfileCacheIdentity(
        accountId: widget.currentUserId,
        roomId: widget.conversationId,
        avatarUrl: _channelAvatarUrl,
        room: MatrixChatService.instance.getRoomById(widget.conversationId),
      );

  @override
  void initState() {
    super.initState();
    _postController.addListener(_onPostTextChanged);
    _posts = List<ChatMessage>.from(widget.initialPosts);
    _subscriberCount = widget.subscriberCount;
    _channelAvatarUrl =
        widget.avatarUrl?.trim().isNotEmpty == true
            ? widget.avatarUrl!.trim()
            : null;
    _loadPosts();
    _loadInteractionState();
    _resolveChannelAvatar();
    _postsSubscription = _chat.messagesStreamFor(widget.conversationId).listen((
      posts,
    ) {
      if (!mounted) return;
      setState(() => _posts = List<ChatMessage>.from(posts));
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshSubscriberCount();
    });
    try {
      _syncSubscription = MatrixClientService.instance.client.onSync.stream
          .listen((_) => _refreshSubscriberCount());
    } catch (_) {
      // Matrix client not ready yet; fallbacks cover it.
    }
  }

  @override
  void dispose() {
    _postsSubscription?.cancel();
    _syncSubscription?.cancel();
    _postController.removeListener(_onPostTextChanged);
    _postController.dispose();
    super.dispose();
  }

  void _onPostTextChanged() {
    if (mounted) setState(() {});
  }

  String _interactionKey(String type, String postId) =>
      'channel_interaction_${widget.currentUserId}_${type}_'
      '${widget.conversationId}_$postId';

  Future<void> _loadInteractionState() async {
    final preferences = await SharedPreferences.getInstance();
    final postIds = _posts.map((post) => post.id).toSet();
    for (final postId in postIds) {
      final liked =
          preferences.getBool(_interactionKey('liked', postId)) ?? false;
      final reposted =
          preferences.getBool(_interactionKey('reposted', postId)) ?? false;
      final likeCount =
          preferences.getInt(_interactionKey('like_count', postId)) ?? 0;
      final repostCount =
          preferences.getInt(_interactionKey('repost_count', postId)) ?? 0;
      if (liked) _likedPostIds.add(postId);
      if (reposted) _repostedPostIds.add(postId);
      if (likeCount > 0) _likeCounts[postId] = likeCount;
      if (repostCount > 0) _repostCounts[postId] = repostCount;
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveInteractionState(String type, String postId) async {
    final preferences = await SharedPreferences.getInstance();
    if (type == 'liked') {
      await preferences.setBool(
        _interactionKey(type, postId),
        _likedPostIds.contains(postId),
      );
      await preferences.setInt(
        _interactionKey('like_count', postId),
        _likeCounts[postId] ?? 0,
      );
    } else {
      await preferences.setBool(
        _interactionKey(type, postId),
        _repostedPostIds.contains(postId),
      );
      await preferences.setInt(
        _interactionKey('repost_count', postId),
        _repostCounts[postId] ?? 0,
      );
    }
  }

  /// Resolve only the avatar belonging to this channel room.
  Future<void> _resolveChannelAvatar() async {
    if (_channelAvatarUrl != null) return;

    // 2. Matrix room avatar.
    try {
      final room = MatrixClientService.instance.client.getRoomById(
        widget.conversationId,
      );
      final roomAvatar = room?.avatar?.toString().trim() ?? '';
      if (roomAvatar.isNotEmpty) {
        if (!mounted) return;
        setState(() => _channelAvatarUrl = roomAvatar);
        return;
      }
    } catch (_) {}

  }

  void _refreshSubscriberCount() {
    if (!mounted) return;
    final count = _liveSubscriberCount();
    if (count != _subscriberCount) {
      setState(() => _subscriberCount = count);
    }
  }

  int _liveSubscriberCount() {
    try {
      final room = MatrixClientService.instance.client.getRoomById(
        widget.conversationId,
      );
      if (room == null) return _subscriberCount;
      final joined = room.getParticipants([mx.Membership.join]).length;
      return joined > 0 ? joined : _subscriberCount;
    } catch (_) {
      return _subscriberCount;
    }
  }

  Future<void> _loadPosts() async {
    final posts = await _chat.hydrateConversation(widget.conversationId);
    if (!mounted) return;
    setState(() => _posts = posts);
    await _loadInteractionState();
  }

  /// Open the channel profile page (tapping the header pill).
  Future<void> _openChannelProfile() async {
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder:
            (_) => ChannelProfileScreen(
              conversationId: widget.conversationId,
              currentUserId: widget.currentUserId,
              title: widget.title,
              avatarUrl: _channelAvatarUrl,
              subscriberCount: _subscriberCount,
              posts: _posts,
              isOwner: widget.canPost,
              isSubscribed: !widget.readOnlyUntilSubscribe && !widget.canPost,
            ),
      ),
    );
    if (result is GroupExitRequest && mounted) {
      Navigator.pop(context, result);
    }
  }

  Future<void> _publishPost() async {
    if (widget.readOnlyUntilSubscribe || !widget.canPost) return;
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

  Future<void> _publishComment(ChatMessage post, String content) async {
    final text = content.trim();
    if (text.isEmpty) return;
    try {
      await _chat.sendMessage(
        ChatMessage(
          id: 'opt_${DateTime.now().millisecondsSinceEpoch}',
          conversationId: widget.conversationId,
          senderId: widget.currentUserId,
          receiverId: widget.conversationId,
          content: text,
          timestamp: DateTime.now(),
          status: MessageStatus.sending,
          replyToMessageId: post.id,
          replyPreview:
              post.content.length > 120
                  ? '${post.content.substring(0, 120)}...'
                  : post.content,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not post comment: $error')));
    }
  }

  String get _subscriberLabel {
    final count = _subscriberCount;
    return '$count ${count == 1 ? 'subscriber' : 'subscribers'}';
  }

  void _registerView(ChatMessage post) {
    if (_viewedPostIds.contains(post.id)) return;
    _viewedPostIds.add(post.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _viewCounts[post.id] = (_viewCounts[post.id] ?? 0) + 1;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final posts =
        _posts
            .where(
              (post) =>
                  !post.isDeletedForMe &&
                  (post.replyToMessageId?.isEmpty ?? true),
            )
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return Scaffold(
      resizeToAvoidBottomInset: true,
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
                      : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 22, 16, 112),
                        itemCount: posts.length,
                        itemBuilder: (_, index) {
                          final post = posts[index];
                          _registerView(post);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _channelPost(post),
                              // Divider under every post, like the reference.
                              const Padding(
                                padding: EdgeInsets.only(
                                  left: 56,
                                  top: 14,
                                  bottom: 16,
                                ),
                                child: Divider(
                                  color: Color(0xFF3A3D42),
                                  thickness: 0.6,
                                  height: 0.6,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: _postComposer(),
      ),
    );
  }

  Widget _channelHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      child: Row(
        children: [
          _circleButton(
            Icons.arrow_back_ios_new,
            () => Navigator.pop(context),
            size: 48,
          ),
          const SizedBox(width: 10),
          Expanded(
            // Tapping the header pill opens the channel profile.
            child: InkWell(
              onTap: _openChannelProfile,
              borderRadius: BorderRadius.circular(28),
              child: Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF23262C),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Row(
                  children: [
                    UserAvatar(
                      imageUrl: _channelAvatarUrl,
                      cacheIdentity: _channelAvatarCacheIdentity,
                      name: widget.title,
                      size: 40,
                    ),
                    const SizedBox(width: 6),
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
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            _subscriberLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _circleButton(Icons.more_vert, () {}, size: 48),
        ],
      ),
    );
  }

  Widget _channelPost(ChatMessage post) {
    final hasImage =
        post.attachmentType == 'image' &&
        (post.attachmentUrl?.trim().isNotEmpty ?? false);
    final hasVideo =
        post.attachmentType == 'video' &&
        (post.attachmentUrl?.trim().isNotEmpty ?? false);
    final mediaAspectRatio =
        post.mediaWidth != null && post.mediaHeight != null && post.mediaHeight! > 0
            ? post.mediaWidth! / post.mediaHeight!
            : null;
    final isPortraitMedia = mediaAspectRatio != null
        ? mediaAspectRatio < 1
        : hasImage;
    final viewLabel = _formatCount(_viewCounts[post.id] ?? 0);
    final viewCount = _viewCounts[post.id] ?? 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _openChannelProfile,
          child: UserAvatar(
            imageUrl: _channelAvatarUrl,
            cacheIdentity: _channelAvatarCacheIdentity,
            name: widget.title,
            size: 44,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: GestureDetector(
                      onTap: _openChannelProfile,
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    ' · ${_postAge(post.timestamp)}',
                    style: const TextStyle(
                      color: Color(0xFF8C8F95),
                      fontSize: 13.5,
                    ),
                  ),
                  if (viewLabel != null)
                    Text(
                      ' · $viewLabel ${viewCount == 1 ? 'view' : 'views'}',
                      style: const TextStyle(
                        color: Color(0xFF8C8F95),
                        fontSize: 13.5,
                      ),
                    ),
                ],
              ),
              if (hasImage || hasVideo) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: EdgeInsets.only(right: isPortraitMedia ? 50 : 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: hasVideo
                        ? (mediaAspectRatio == null
                            ? WrytteVideoPlayer(
                                source: post.attachmentUrl!,
                                borderRadius: BorderRadius.circular(14),
                              )
                            : AspectRatio(
                                aspectRatio: mediaAspectRatio,
                                child: WrytteVideoPlayer(
                                  source: post.attachmentUrl!,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ))
                        : AspectRatio(
                            aspectRatio: mediaAspectRatio ?? 9 / 16,
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
              ],
              if (post.content.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    post.content,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
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
            .where(
              (candidate) =>
                  candidate.replyToMessageId == postId &&
                  !candidate.isDeletedForMe,
            )
            .length;
    final reposted = _repostedPostIds.contains(postId);
    final liked = _likedPostIds.contains(postId);
    final bookmarked = _bookmarkedPostIds.contains(postId);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
          _PostAction(
            icon: Icons.comment_outlined,
            label: _formatCount(commentCount),
            onTap: () => _openComments(post),
          ),
          const SizedBox(width: 18),
          _PostAction(
            icon: Icons.repeat,
            label: _formatCount(_repostCounts[postId] ?? 0),
            color: reposted ? const Color(0xFF4DA3FF) : null,
            onTap: () => _toggleRepost(postId),
          ),
          const SizedBox(width: 18),
          _PostAction(
            icon: liked ? Icons.favorite : Icons.favorite_border,
            label: _formatCount(_likeCounts[postId] ?? 0),
            color: liked ? const Color(0xFFE85D75) : null,
            onTap: () => _toggleLike(postId),
          ),
          const SizedBox(width: 18),
          _PostAction(
            icon: Icons.ios_share_outlined,
            onTap: () => _openShareSheet(post),
          ),
          const SizedBox(width: 8),
          _PostAction(
            icon: bookmarked ? Icons.bookmark : Icons.bookmark_border,
            color: bookmarked ? const Color(0xFF4DA3FF) : null,
            onTap: () => _toggleBookmark(postId),
          ),
          const SizedBox(width: 18),
          _PostAction(
            icon: Icons.more_horiz,
            onTap: () => _openMoreOptions(post),
          ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- comments

  void _openComments(ChatMessage post) {
    final commentController = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF15171B),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              final comments =
                  _posts
                      .where(
                        (candidate) =>
                            candidate.replyToMessageId == post.id &&
                            !candidate.isDeletedForMe,
                      )
                      .toList()
                    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
              return SizedBox(
                height: MediaQuery.of(sheetContext).size.height * 0.6,
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Comments',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child:
                          comments.isEmpty
                              ? const Center(
                                child: Text(
                                  'No comments yet. Be the first!',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              )
                              : ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                itemCount: comments.length,
                                itemBuilder: (_, index) {
                                  final comment = comments[index];
                                  final isMine = comment.senderId.contains(
                                    widget.currentUserId,
                                  );
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        UserAvatar(
                                          imageUrl:
                                              isMine ? _channelAvatarUrl : null,
                                          name:
                                              comment.senderName ??
                                              comment.senderId,
                                          size: 32,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${isMine ? widget.title : (comment.senderName ?? 'Subscriber')} · ${_postAge(comment.timestamp)}',
                                                style: const TextStyle(
                                                  color: Color(0xFF8C8F95),
                                                  fontSize: 12.5,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                comment.content,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 15,
                                                  height: 1.3,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF23262C),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: TextField(
                                controller: commentController,
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  hintText: 'Add a comment',
                                  hintStyle: TextStyle(color: Colors.white38),
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(
                              Icons.send,
                              color: Color(0xFF4DA3FF),
                            ),
                            onPressed: () async {
                              if (!sheetContext.mounted) return;
                              final text = commentController.text.trim();
                              if (text.isEmpty) return;
                              commentController.clear();
                              await _publishComment(post, text);
                              if (sheetContext.mounted) setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    ).whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        commentController.dispose();
      });
    });
  }

  // ------------------------------------------------------------------- share

  String _postLink(ChatMessage post) {
    final roomId = Uri.encodeComponent(widget.conversationId);
    final eventId = Uri.encodeComponent(post.id);
    return 'https://matrix.to/#/$roomId/$eventId';
  }

  void _openShareSheet(ChatMessage post) {
    Clipboard.setData(ClipboardData(text: _postLink(post))).then((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post link copied')),
      );
    });
  }

  // ----------------------------------------------------------- more options

  void _openMoreOptions(ChatMessage post) {
    final isMine = post.senderId.contains(widget.currentUserId);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF15171B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.white),
                title: const Text(
                  'Copy text',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: post.content));
                  if (!sheetContext.mounted) return;
                  Navigator.pop(sheetContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
              ),
              if (isMine)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Color(0xFFE85D75),
                  ),
                  title: const Text(
                    'Delete post',
                    style: TextStyle(color: Color(0xFFE85D75)),
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    try {
                      await _chat.deleteMessageForEveryone(post);
                      if (!mounted) return;
                      setState(() {
                        _posts.removeWhere((item) => item.id == post.id);
                      });
                    } catch (error) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Could not delete post: $error'),
                        ),
                      );
                    }
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _toggleRepost(String postId) {
    setState(() {
      if (_repostedPostIds.add(postId)) {
        _repostCounts[postId] = (_repostCounts[postId] ?? 0) + 1;
      } else {
        _repostedPostIds.remove(postId);
        _repostCounts[postId] = (_repostCounts[postId] ?? 1) - 1;
      }
    });
    unawaited(_saveInteractionState('reposted', postId));
  }

  void _toggleLike(String postId) {
    setState(() {
      if (_likedPostIds.add(postId)) {
        _likeCounts[postId] = (_likeCounts[postId] ?? 0) + 1;
      } else {
        _likedPostIds.remove(postId);
        _likeCounts[postId] = (_likeCounts[postId] ?? 1) - 1;
      }
    });
    unawaited(_saveInteractionState('liked', postId));
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
    if (count <= 0) return null;
    if (count < 1000) return '$count';
    return '${(count / 1000).toStringAsFixed(count % 1000 == 0 ? 0 : 1)}K';
  }

  Widget _postComposer() {
    if (widget.readOnlyUntilSubscribe) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              onPressed: _subscribeToChannel,
              child: const Text('Subscribe'),
            ),
          ),
        ),
      );
    }
    if (!widget.canPost) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
        decoration: const BoxDecoration(color: Color(0xFF08090B)),
        child: Row(
          children: [
            _circleButton(Icons.add, () {}, size: 46),
            const SizedBox(width: 6),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: 50,
                  maxHeight: 160,
                ),
                child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF23262C),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: TextField(
                  controller: _postController,
                  minLines: 1,
                  maxLines: 4,
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
            ),
            const SizedBox(width: 6),
            _circleButton(
              _publishing
                  ? Icons.hourglass_top
                  : (_postController.text.trim().isNotEmpty
                      ? Icons.send
                      : Icons.camera_alt_outlined),
              _publishing
                  ? null
                  : (_postController.text.trim().isNotEmpty
                      ? _publishPost
                      : () {}),
              size: 46,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _subscribeToChannel() async {
    try {
      await MatrixChatService.instance.joinGroup(
        widget.subscribeAlias?.trim().isNotEmpty == true
            ? widget.subscribeAlias!.trim()
            : widget.conversationId,
      );
      await ChatService().markConversationAsRead(widget.conversationId);
      await NotificationService.instance.clearConversationNotifications(
        widget.conversationId,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not subscribe: $error')),
      );
    }
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
    if (elapsed.inDays < 365) return '${(elapsed.inDays / 30).floor()}mo';
    return '${(elapsed.inDays / 365).floor()}y';
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
            Icon(icon, color: actionColor, size: 24),
            if (label != null) ...[
              const SizedBox(width: 5),
              Text(label!, style: TextStyle(color: actionColor, fontSize: 14)),
            ],
          ],
        ),
      ),
    );
  }
}
