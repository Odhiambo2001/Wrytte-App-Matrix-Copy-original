import 'package:flutter/material.dart';

// ── Data model ────────────────────────────────────────────────────────────────

class ShopItemData {
  final String authorName;
  final String authorAvatarUrl;
  final String timeAgo;
  final String? badgeLabel; // e.g. "Sale", "Rent", "Exchange"
  final Color? badgeColor;
  final String title;
  final String price;
  final String? meta; // e.g. "2018" or "5 rooms"
  final String? imageUrl;
  final int likes;
  final int comments;
  final int reposts;
  final bool isLiked;
  final bool isSaved;
  final String category; // matches _kCategories keys

  const ShopItemData({
    required this.authorName,
    this.authorAvatarUrl = '',
    required this.timeAgo,
    this.badgeLabel,
    this.badgeColor,
    required this.title,
    required this.price,
    this.meta,
    this.imageUrl,
    required this.likes,
    required this.comments,
    required this.reposts,
    this.isLiked = false,
    this.isSaved = false,
    required this.category,
  });
}

// ── Card widget ───────────────────────────────────────────────────────────────

class ShopItemCard extends StatefulWidget {
  final ShopItemData item;

  const ShopItemCard({super.key, required this.item});

  @override
  State<ShopItemCard> createState() => _ShopItemCardState();
}

class _ShopItemCardState extends State<ShopItemCard> {
  late bool _liked;
  late bool _saved;
  late int _likes;

  @override
  void initState() {
    super.initState();
    _liked = widget.item.isLiked;
    _saved = widget.item.isSaved;
    _likes = widget.item.likes;
  }

  String _formatCount(int n) {
    if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k';
    }
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF13151A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF23262C), width: 1.0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Author row ────────────────────────────────────────────────
            Row(
              children: [
                // Avatar
                CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFF23262C),
                  backgroundImage:
                      item.authorAvatarUrl.isNotEmpty
                          ? NetworkImage(item.authorAvatarUrl)
                          : null,
                  child:
                      item.authorAvatarUrl.isEmpty
                          ? Text(
                            item.authorName[0].toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                          : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.authorName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        item.timeAgo,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // More button
                Icon(
                  Icons.more_horiz,
                  color: Colors.white.withOpacity(0.4),
                  size: 20,
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ── Content row: text left, image right ───────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: badge + title + price/meta
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Badge
                      if (item.badgeLabel != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: item.badgeColor ?? const Color(0xFF4DA3FF),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            item.badgeLabel!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      // Title
                      Text(
                        item.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      // Price + meta
                      Row(
                        children: [
                          Text(
                            item.price,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (item.meta != null) ...[
                            Text(
                              '  •  ',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              item.meta!,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                // Right: thumbnail
                if (item.imageUrl != null || true) ...[
                  const SizedBox(width: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child:
                        item.imageUrl != null && item.imageUrl!.isNotEmpty
                            ? Image.network(
                              item.imageUrl!,
                              width: 110,
                              height: 110,
                              fit: BoxFit.cover,
                            )
                            : Container(
                              width: 110,
                              height: 110,
                              decoration: BoxDecoration(
                                color: const Color(0xFF23262C),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                _categoryIcon(item.category),
                                color: Colors.white.withOpacity(0.2),
                                size: 36,
                              ),
                            ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 12),

            // ── Action bar ────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF23262C),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF23262C), width: 1.0),
              ),
              child: Row(
                children: [
                  // Like
                  GestureDetector(
                    onTap:
                        () => setState(() {
                          _liked = !_liked;
                          _likes += _liked ? 1 : -1;
                        }),
                    child: Row(
                      children: [
                        Icon(
                          _liked ? Icons.favorite : Icons.favorite_border,
                          color:
                              _liked ? const Color(0xFFFF4D6A) : Colors.white54,
                          size: 18,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatCount(_likes),
                          style: TextStyle(
                            color:
                                _liked
                                    ? const Color(0xFFFF4D6A)
                                    : Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Comments
                  Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        color: Colors.white54,
                        size: 17,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatCount(item.comments),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  // Reposts
                  Row(
                    children: [
                      Icon(
                        Icons.repeat_rounded,
                        color: Colors.white54,
                        size: 19,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatCount(item.reposts),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  // Save
                  GestureDetector(
                    onTap: () => setState(() => _saved = !_saved),
                    child: Icon(
                      _saved ? Icons.bookmark : Icons.bookmark_border,
                      color: _saved ? const Color(0xFF4DA3FF) : Colors.white54,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Share
                  Icon(Icons.reply_rounded, color: Colors.white54, size: 19),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _categoryIcon(String cat) {
    switch (cat) {
      case 'Vehicles':
        return Icons.directions_car;
      case 'Real estate':
        return Icons.home;
      case 'Electronics':
        return Icons.devices;
      case 'Service':
        return Icons.build;
      default:
        return Icons.storefront;
    }
  }
}
