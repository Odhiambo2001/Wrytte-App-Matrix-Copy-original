import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';

class PostData {
  final String authorName;
  final String authorAvatarUrl;
  final String timeAgo;
  final String text;
  final String? mediaUrl;
  final bool isVideo;
  final String? videoDuration;
  final int comments;
  final int likes;
  final int reposts;
  final bool isSaved;
  final bool isLiked;

  const PostData({
    required this.authorName,
    required this.authorAvatarUrl,
    required this.timeAgo,
    required this.text,
    this.mediaUrl,
    this.isVideo = false,
    this.videoDuration,
    this.comments = 0,
    this.likes = 0,
    this.reposts = 0,
    this.isSaved = false,
    this.isLiked = false,
  });
}

class PostItem extends StatefulWidget {
  final PostData post;

  const PostItem({super.key, required this.post});

  @override
  State<PostItem> createState() => _PostItemState();
}

class _PostItemState extends State<PostItem> {
  late bool _isLiked;
  late bool _isSaved;
  late int _likes;

  // Layout constants
  static const double _outerPad = 12.0;
  static const double _avatarDiameter = 48.0;
  static const double _avatarTextGap = 10.0;
  // Left edge of all content (text, media, actions)
  static const double _contentLeft =
      _outerPad + _avatarDiameter + _avatarTextGap;
  // Right padding for media and actions — generous to match the image
  static const double _mediaRightPad = 56.0;

  @override
  void initState() {
    super.initState();
    _isLiked = widget.post.isLiked;
    _isSaved = widget.post.isSaved;
    _likes = widget.post.likes;
  }

  String _formatCount(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header: avatar + name + text ─────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(_outerPad, 12, _outerPad, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar with centered follow badge
              SizedBox(
                width: _avatarDiameter,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    UserAvatar(
                      size: _avatarDiameter,
                      imageUrl: widget.post.authorAvatarUrl,
                      name: widget.post.authorName,
                    ),
                    Positioned(
                      bottom: -10,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: const BoxDecoration(
                            color: Color(0xFF4DA3FF),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.add,
                            color: Colors.white,
                            size: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: _avatarTextGap),

              // Name + time + text — right edge is the full screen width
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          widget.post.authorName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          widget.post.timeAgo,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.more_horiz,
                          color: Colors.grey,
                          size: 20,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.post.text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // ── Media — left aligns with text, large right padding ────────────
        if (widget.post.mediaUrl != null || widget.post.isVideo)
          Padding(
            padding: EdgeInsets.only(
              left: _contentLeft,
              right: _mediaRightPad,
              top: 10,
            ),
            child: _buildMedia(),
          ),

        // ── Action bar — same left/right as media ─────────────────────────
        Padding(
          padding: EdgeInsets.only(
            left: _contentLeft,
            right: _mediaRightPad,
            top: 10,
            bottom: 10,
          ),
          child: _buildActionBar(),
        ),

        Divider(height: 1, color: Colors.white.withValues(alpha: 0.07)),
      ],
    );
  }

  Widget _buildMedia() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;
        // Video portrait, image landscape — narrower width = shorter height
        final double aspectRatio = widget.post.isVideo ? 9 / 14 : 4 / 3;
        final double h = w / aspectRatio;

        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  color: const Color(0xFF1A1D22),
                  child:
                      widget.post.mediaUrl != null
                          ? Image.network(
                            widget.post.mediaUrl!,
                            fit: BoxFit.cover,
                            errorBuilder:
                                (_, __, ___) => const Center(
                                  child: Icon(
                                    Icons.broken_image,
                                    color: Colors.white24,
                                    size: 36,
                                  ),
                                ),
                          )
                          : const Center(
                            child: Icon(
                              Icons.image,
                              color: Colors.white12,
                              size: 44,
                            ),
                          ),
                ),

                if (widget.post.isVideo) ...[
                  Positioned(
                    bottom: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        widget.post.videoDuration ?? '0:00',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 10,
                    right: 10,
                    child: Icon(
                      Icons.volume_off_outlined,
                      color: Colors.white.withValues(alpha: 0.8),
                      size: 18,
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text(
                        'CC',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionBar() {
    return Row(
      children: [
        _ActionBtn(
          icon: Icons.chat_bubble_outline,
          label: _formatCount(widget.post.comments),
          color: Colors.grey,
          onTap: () {},
        ),
        const SizedBox(width: 14),
        _ActionBtn(
          icon: _isLiked ? Icons.favorite : Icons.favorite_border,
          label: _formatCount(_likes),
          color: _isLiked ? const Color(0xFFFF453A) : Colors.grey,
          onTap: () {
            setState(() {
              _isLiked = !_isLiked;
              _likes += _isLiked ? 1 : -1;
            });
          },
        ),
        const SizedBox(width: 14),
        _ActionBtn(
          icon: Icons.repeat_rounded,
          label: _formatCount(widget.post.reposts),
          color: Colors.grey,
          onTap: () {},
        ),
        const Spacer(),
        GestureDetector(
          onTap: () {},
          child: const Icon(Icons.reply_outlined, color: Colors.grey, size: 20),
        ),
        const SizedBox(width: 14),
        GestureDetector(
          onTap: () => setState(() => _isSaved = !_isSaved),
          child: Icon(
            _isSaved ? Icons.bookmark : Icons.bookmark_border,
            color: _isSaved ? const Color(0xFF4DA3FF) : Colors.grey,
            size: 20,
          ),
        ),
      ],
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 13)),
        ],
      ),
    );
  }
}
