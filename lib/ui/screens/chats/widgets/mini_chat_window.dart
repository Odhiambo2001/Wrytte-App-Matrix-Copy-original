import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/ui/screens/chats/widgets/message_bubble.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';

class MiniChatPreview extends StatefulWidget {
  final String conversationId;
  final String name;
  final String? avatarUrl;
  final String currentUserId;
  final String receiverId;

  const MiniChatPreview({
    super.key,
    required this.conversationId,
    required this.name,
    required this.currentUserId,
    required this.receiverId,
    this.avatarUrl,
  });

  @override
  State<MiniChatPreview> createState() => _MiniChatPreviewState();
}

class _MiniChatPreviewState extends State<MiniChatPreview> {
  final ChatService _chat = ChatService();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<ChatMessage>? _messageSub;

  List<ChatMessage> _messages = [];

  bool _isPinned = false;
  bool _isMuted = false;
  bool _isArchived = false;

  static const double _headerHeight = 38;
  static const Color _white = Colors.white;
  static const Color _red = Color(0xFFFF3B30);

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() async {
    List<ChatMessage> messages;
    try {
      await _chat.connect();
      messages = await _chat.fetchMessageHistory(
        conversationID: widget.conversationId,
        count: 30,
      );
    } catch (_) {
      messages = await ChatLocalDb.instance.loadMessages(widget.conversationId);
    }
    if (mounted) {
      setState(() => _messages = messages);
      _scrollToBottom();
    }
    _messageSub = _chat.messageStream.listen((message) {
      if (!mounted) return;
      if (message.conversationId != widget.conversationId) return;
      if (_messages.any((m) => m.id == message.id)) return;
      setState(() => _messages.add(message));
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _navigateToChatScreen() {
    Navigator.pop(context);
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder:
            (_, __, ___) => ChatScreen(
              conversationId: widget.conversationId,
              receiverId: widget.receiverId,
              currentUserId: widget.currentUserId,
              title: widget.name,
              avatarUrl: widget.avatarUrl,
            ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $period';
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenH = mq.size.height;
    final screenW = mq.size.width;
    final topPad = mq.padding.top;
    final bottomPad = mq.padding.bottom;

    // ── Responsive sizing ─────────────────────────────────────────────────
    // Safe area we can actually use
    final usableH = screenH - topPad - bottomPad;

    // Window sits 12 px below the status bar
    const topOffset = 12.0;
    const gap = 10.0; // gap between window bottom and dialog top

    // Window width: 92 % of screen, max 360
    final windowW = (screenW * 0.92).clamp(0.0, 360.0);

    // Window height: 48 % of usable height, clamped between 260 and 400
    final windowH = (usableH * 0.48).clamp(260.0, 400.0);

    // Dialog width: half of window width
    final dialogW = windowW * 0.5;

    // Dialog max height: whatever is left minus top-offset, window, gap,
    // a small bottom margin (16), clamped so it never grows beyond 320
    final dialogMaxH = (usableH - topOffset - windowH - gap - 16).clamp(
      0.0,
      320.0,
    );

    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            // ── Blurred backdrop ────────────────────────────────────────
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Container(color: Colors.black.withOpacity(0.40)),
              ),
            ),

            // ── Scrollable column: window + dialog, centred horizontally ─
            Positioned(
              top: topPad + topOffset,
              left: 0,
              right: 0,
              // height = usable area so it never goes into bottom padding
              height: usableH - topOffset,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Chat window ──────────────────────────────────────
                    GestureDetector(
                      onTap: _navigateToChatScreen,
                      child: _chatWindow(windowW, windowH),
                    ),

                    const SizedBox(height: gap),

                    // ── Action dialog (right-aligned, half width) ─────────
                    GestureDetector(
                      onTap: () {}, // absorb so backdrop doesn't fire
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _actionsDialog(dialogW, dialogMaxH),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Chat window ───────────────────────────────────────────────────────────

  Widget _chatWindow(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF08090B),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: _header(width),
          ),
          Expanded(child: _messagesList()),
        ],
      ),
    );
  }

  // ── Header pill ───────────────────────────────────────────────────────────

  Widget _header(double windowWidth) {
    // Pill occupies window width minus its own horizontal padding
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 70),
      child: SizedBox(
        height: _headerHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Glass pill
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF23262C).withOpacity(0.30),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFF23262C)),
                    ),
                  ),
                ),
              ),
            ),

            // Avatar bleeding out
            Positioned(
              left: -2,
              top: -2,
              bottom: -2,
              child: UserAvatar(
                size: _headerHeight + 12,
                imageUrl: widget.avatarUrl,
                name: widget.name,
              ),
            ),

            // Name
            Positioned(
              left: _headerHeight + 16,
              right: 12,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Messages list ─────────────────────────────────────────────────────────

  Widget _messagesList() {
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet',
          style: TextStyle(color: Colors.white.withOpacity(0.35)),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      physics: const BouncingScrollPhysics(),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        final isMine = msg.senderId == widget.currentUserId;
        final prev = index > 0 ? _messages[index - 1] : null;
        final showTail =
            prev == null || (prev.senderId == widget.currentUserId) != isMine;

        return MessageBubble(
          content: msg.content,
          time: _formatTime(msg.timestamp),
          isMine: isMine,
          showTail: showTail,
          status: isMine ? msg.status : null,
        );
      },
    );
  }

  // ── Action dialog ─────────────────────────────────────────────────────────

  Widget _actionsDialog(double dialogWidth, double maxHeight) {
    final items = [
      _ActionData(
        icon: _isPinned ? Icons.push_pin : Icons.push_pin_outlined,
        label: _isPinned ? 'Unpin' : 'Pin',
        onTap: () => setState(() => _isPinned = !_isPinned),
      ),
      _ActionData(
        icon: Icons.mark_chat_read_outlined,
        label: 'Mark as read',
        onTap: () {},
      ),
      _ActionData(
        icon: _isMuted ? Icons.volume_up_outlined : Icons.volume_off_outlined,
        label: _isMuted ? 'Unmute' : 'Mute',
        onTap: () => setState(() => _isMuted = !_isMuted),
      ),
      _ActionData(
        icon: _isArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
        label: _isArchived ? 'Unarchive' : 'Archive',
        onTap: () => setState(() => _isArchived = !_isArchived),
      ),
      _ActionData(
        icon: Icons.delete_outline,
        label: 'Delete',
        isDestructive: true,
        onTap: () {},
      ),
      _ActionData(icon: Icons.more_vert, label: 'More', onTap: () {}),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          width: dialogWidth,
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withOpacity(0.30),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF23262C), width: 1),
          ),
          // Scrollable so no item is ever cut off on tiny screens
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(items.length, (i) {
                final item = items[i];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _actionItem(
                      icon: item.icon,
                      label: item.label,
                      onTap: item.onTap,
                      isDestructive: item.isDestructive,
                    ),
                    if (i < items.length - 1)
                      Divider(
                        height: 0,
                        thickness: 0.5,
                        color: Colors.white.withOpacity(0.08),
                        indent: 16,
                        endIndent: 16,
                      ),
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final color = isDestructive ? _red : _white;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Simple data class for action items ────────────────────────────────────────

class _ActionData {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _ActionData({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });
}
