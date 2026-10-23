import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/services/matrix/mute_rooms_service.dart';

class ConversationTile extends StatelessWidget {
  final String name;
  final bool hasMessage;
  final String lastMessage;
  final String? senderName;
  final String time;
  final String? avatarUrl;
  final String? localAvatarPath;
  final String? avatarCacheIdentity;
  final int unreadCount;
  final bool isOnline;
  final bool isDeleted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  // ── Selection mode ────────────────────────────────────────────────────────
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onSelectionToggle;
  final bool channelOnly;
  final int? channelSubscriberCount;
  final bool hasAutoDelete;
  final bool isMuted;
  final String? roomId;

  static const Color _blue = Color(0xFF4DA3FF);

  const ConversationTile({
    super.key,
    required this.name,
    required this.hasMessage,
    required this.lastMessage,
    this.senderName,
    required this.time,
    this.avatarUrl,
    this.localAvatarPath,
    this.avatarCacheIdentity,
    this.unreadCount = 0,
    this.isOnline = false,
    this.isDeleted = false,
    this.onTap,
    this.onLongPress,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onSelectionToggle,
    this.channelOnly = false,
    this.channelSubscriberCount,
    this.hasAutoDelete = false,
    this.isMuted = false,
    this.roomId,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      color: isSelected ? _blue.withValues(alpha: 0.08) : Colors.transparent,
      child: Column(
        children: [
          InkWell(
            onTap: isSelectionMode ? onSelectionToggle : onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  // ── Selection circle ────────────────────────────────────────
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: isSelectionMode ? 28 : 0,
                    height: 60,
                    alignment: Alignment.center,
                    child:
                        isSelectionMode
                            ? _SelectionCircle(isSelected: isSelected)
                            : const SizedBox.shrink(),
                  ),

                  if (isSelectionMode) const SizedBox(width: 6),

                  // ── Avatar ─────────────────────────────────────────────────
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      UserAvatar(
                        size: 60,
                        imageUrl: avatarUrl,
                        localImagePath: localAvatarPath,
                        cacheIdentity: avatarCacheIdentity,
                        name: name,
                        isDeleted: isDeleted,
                      ),

                      if (isOnline && !isSelectionMode)
                        Positioned(
                          bottom: 2,
                          right: 2,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),

                      if (hasAutoDelete && !isSelectionMode)
                        Positioned(
                          bottom: 0,
                          right: -2,
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: SvgPicture.asset(
                              'assets/images/Disappearing messages icon.svg',
                              colorFilter: const ColorFilter.mode(
                                Colors.white,
                                BlendMode.srcIn,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),

                  const SizedBox(width: 12),

                  // ── Name + message ─────────────────────────────────────────
                  Expanded(
                    child:
                        channelOnly
                            ? _ChannelDetails(
                              name: name,
                              subscriberCount: channelSubscriberCount ?? 0,
                            )
                            : hasMessage
                            ? _ConversationDetails(
                              name: name,
                              senderName: senderName,
                              lastMessage: lastMessage,
                              time: time,
                              unreadCount: unreadCount,
                              isSelectionMode: isSelectionMode,
                              isSelected: isSelected,
                              isMuted: isMuted,
                              roomId: roomId,
                            )
                            : SizedBox(
                              height: 60,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                  ),
                ],
              ),
            ),
          ),
          if (channelOnly)
            const Padding(
              padding: EdgeInsets.only(left: 84),
              child: Divider(height: 1, thickness: 1, color: Color(0xFF202228)),
            ),
        ],
      ),
    );
  }
}

class _ChannelDetails extends StatelessWidget {
  final String name;
  final int subscriberCount;

  const _ChannelDetails({required this.name, required this.subscriberCount});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        '$subscriberCount ${subscriberCount == 1 ? 'subscriber' : 'subscribers'}',
        style: const TextStyle(color: Colors.white54, fontSize: 15),
      ),
    ],
  );
}

class _ConversationDetails extends StatelessWidget {
  final String name;
  final String? senderName;
  final String lastMessage;
  final String time;
  final int unreadCount;
  final bool isSelectionMode;
  final bool isSelected;
  final bool isMuted;
  final String? roomId;

  const _ConversationDetails({
    required this.name,
    required this.senderName,
    required this.lastMessage,
    required this.time,
    required this.unreadCount,
    required this.isSelectionMode,
    required this.isSelected,
    required this.isMuted,
    required this.roomId,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  if (isMuted) ...[
                    const SizedBox(width: 6),
                    SvgPicture.asset(
                      'assets/images/Mute new display.svg',
                      width: 18,
                      height: 18,
                    ),
                  ] else if (roomId?.isNotEmpty == true)
                    FutureBuilder<bool>(
                      future: MuteRoomsService.instance.isMuted(roomId!),
                      builder: (context, snapshot) {
                        if (snapshot.data != true) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: SvgPicture.asset(
                            'assets/images/Mute new display.svg',
                            width: 18,
                            height: 18,
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            Text(
              time,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? ConversationTile._blue : Colors.grey[400],
              ),
            ),
          ],
        ),

        const SizedBox(height: 4),

        if (senderName?.trim().isNotEmpty == true) ...[
          Text(
            senderName!.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, color: Colors.white),
          ),
          const SizedBox(height: 2),
        ],

        Row(
          children: [
            Expanded(
              child: Text(
                lastMessage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: Colors.grey[500]),
              ),
            ),
            if (unreadCount > 0 && !isSelectionMode)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: ConversationTile._blue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  unreadCount > 99 ? '99+' : unreadCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),

        const SizedBox(height: 14),

        Divider(
          color: Colors.grey.withValues(alpha: 0.3),
          thickness: 0.5,
          height: 0,
        ),
      ],
    );
  }
}

// ── Selection circle ──────────────────────────────────────────────────────────

class _SelectionCircle extends StatelessWidget {
  final bool isSelected;
  static const Color _blue = Color(0xFF4DA3FF);

  const _SelectionCircle({required this.isSelected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected ? _blue : Colors.transparent,
        border: Border.all(
          color: isSelected ? _blue : Colors.grey.withValues(alpha: 0.55),
          width: 1.8,
        ),
      ),
      child:
          isSelected
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : null,
    );
  }
}
