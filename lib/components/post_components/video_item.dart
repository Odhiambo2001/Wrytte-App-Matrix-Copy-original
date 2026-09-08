import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';

class VideoData {
  final String authorName;
  final String authorAvatarUrl;
  final String caption;
  final String? thumbnailUrl;
  final int comments;
  final int likes;
  final int reposts;
  final bool isSaved;
  final bool isLiked;

  const VideoData({
    required this.authorName,
    required this.authorAvatarUrl,
    required this.caption,
    this.thumbnailUrl,
    this.comments = 0,
    this.likes = 0,
    this.reposts = 0,
    this.isSaved = false,
    this.isLiked = false,
  });
}

class VideoItem extends StatefulWidget {
  final VideoData video;

  const VideoItem({super.key, required this.video});

  @override
  State<VideoItem> createState() => _VideoItemState();
}

class _VideoItemState extends State<VideoItem> {
  late bool _isLiked;
  late bool _isSaved;
  late int _likes;

  @override
  void initState() {
    super.initState();
    _isLiked = widget.video.isLiked;
    _isSaved = widget.video.isSaved;
    _likes = widget.video.likes;
  }

  String _formatCount(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }

  @override
  Widget build(BuildContext context) {
    // ✅ No fixed height here — VideoItem fills whatever its parent gives it.
    // The parent (PostScreen) constrains the PageView to stop above the nav bar.
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Full background ───────────────────────────────────────────────
        widget.video.thumbnailUrl != null
            ? Image.asset(
              widget.video.thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder:
                  (_, __, ___) => Container(
                    color: const Color(0xFF0D0F12),
                    child: const Center(
                      child: Icon(
                        Icons.play_circle_outline,
                        color: Colors.white24,
                        size: 64,
                      ),
                    ),
                  ),
            )
            : Container(
              color: const Color(0xFF0D0F12),
              child: const Center(
                child: Icon(
                  Icons.play_circle_outline,
                  color: Colors.white24,
                  size: 64,
                ),
              ),
            ),

        // ── Bottom gradient scrim ─────────────────────────────────────────
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 300,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.9),
                ],
              ),
            ),
          ),
        ),

        // ── Author + caption + actions pinned to bottom ───────────────────
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 48,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          UserAvatar(
                            size: 48,
                            imageUrl: widget.video.authorAvatarUrl,
                            name: widget.video.authorName,
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
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.video.authorName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.video.caption,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: 13.5,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Action pills
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _PillAction(
                        icon: Icons.chat_bubble_outline,
                        label: _formatCount(widget.video.comments),
                        onTap: () {},
                      ),
                      const SizedBox(width: 8),
                      _PillAction(
                        icon: _isLiked ? Icons.favorite : Icons.favorite_border,
                        label: _formatCount(_likes),
                        color:
                            _isLiked ? const Color(0xFFFF453A) : Colors.white,
                        onTap: () {
                          setState(() {
                            _isLiked = !_isLiked;
                            _likes += _isLiked ? 1 : -1;
                          });
                        },
                      ),
                      const SizedBox(width: 8),
                      _PillAction(
                        icon: Icons.repeat_rounded,
                        label: _formatCount(widget.video.reposts),
                        onTap: () {},
                      ),
                      const SizedBox(width: 8),
                      _GroupedPill(
                        children: [
                          _PillIconButton(
                            icon: Icons.reply_outlined,
                            onTap: () {},
                          ),
                          _PillIconButton(
                            icon:
                                _isSaved
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                            color:
                                _isSaved
                                    ? const Color(0xFF4DA3FF)
                                    : Colors.white,
                            onTap: () => setState(() => _isSaved = !_isSaved),
                          ),
                          _PillIconButton(icon: Icons.more_horiz, onTap: () {}),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PillAction extends StatelessWidget {
  final IconData icon;
  final String? label;
  final Color color;
  final VoidCallback onTap;

  const _PillAction({
    required this.icon,
    this.label,
    this.color = Colors.white,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF0F1013).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            if (label != null) ...[
              const SizedBox(width: 5),
              Text(
                label!,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GroupedPill extends StatelessWidget {
  final List<Widget> children;
  const _GroupedPill({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1013).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _PillIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _PillIconButton({
    required this.icon,
    this.color = Colors.white,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Icon(icon, color: color, size: 18),
      ),
    );
  }
}
