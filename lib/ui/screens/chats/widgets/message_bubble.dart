import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MessageBubble
//
// Changes vs original:
//   • Accepts optional `isVoiceNote` and `voiceDuration` and `audioUrl` params
//   • When isVoiceNote is true, renders a WhatsApp-style voice note player
//     instead of text — play/pause button, waveform bars, elapsed time
//   • Text bubbles: ZERO changes — same layout, colours, tail, time, ticks
// ─────────────────────────────────────────────────────────────────────────────

class MessageBubble extends StatelessWidget {
  final String content;
  final String time;
  final bool isMine;
  final bool showTail;
  final MessageStatus? status;

  // ── Voice note fields (null = plain text bubble) ───────────────────────────
  final bool isVoiceNote;
  final bool isVideoNote;
  final int? voiceDuration; // total seconds
  final String? audioUrl; // CDN URL from Matrix media upload
  final bool isForwarded;
  final bool isStarred;
  final bool isDeleted;
  final bool isEdited;
  final String? replyPreview;
  final String? replySender;
  final bool animateOnMount;

  static const Color _blue = Color(0xFF4DA3FF);
  static const Color _incoming = Color(0xFF23262C);
  static const Color _readGreen = Color(0xFF4CAF50);

  const MessageBubble({
    super.key,
    required this.content,
    required this.time,
    required this.isMine,
    this.showTail = true,
    this.status,
    // voice note params
    this.isVoiceNote = false,
    this.isVideoNote = false,
    this.voiceDuration,
    this.audioUrl,
    this.isForwarded = false,
    this.isStarred = false,
    this.isDeleted = false,
    this.isEdited = false,
    this.replyPreview,
    this.replySender,
    this.animateOnMount = true,
  });

  static const double _tailW = 8.0;
  static const double _tailH = 10.0;

  @override
  Widget build(BuildContext context) {
    final Color bubbleColor = isMine ? _blue : _incoming;
    final Widget timeWidget = _buildTimeRow();
    final bubble = Container(
      margin: EdgeInsets.only(top: showTail ? 6 : 2, bottom: 2),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMine ? 18 : (showTail ? 2 : 18)),
          bottomRight: Radius.circular(isMine ? (showTail ? 2 : 18) : 18),
        ),
      ),
      // ── Switch between voice player and text content ─────────────
      child:
          isVoiceNote
              ? _VoiceNotePlayer(
                audioUrl: audioUrl ?? '',
                totalSeconds: voiceDuration ?? 0,
                isMine: isMine,
                timeWidget: timeWidget,
              )
              : isVideoNote
              ? _VideoMessageBubble(
                totalSeconds: voiceDuration ?? 0,
                timeWidget: timeWidget,
              )
              : _BubbleContent(
                content: content,
                timeWidget: timeWidget,
                isForwarded: isForwarded,
                isStarred: isStarred,
                isDeleted: isDeleted,
                isEdited: isEdited,
                replyPreview: replyPreview,
                replySender: replySender,
                isMine: isMine,
              ),
    );

    final maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.78;
    final tail =
        showTail
            ? _buildTail(bubbleColor, incoming: !isMine)
            : const SizedBox(width: _tailW, height: _tailH);
    final fixedBubbleSlot = SizedBox(
      width: maxBubbleWidth,
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: bubble,
      ),
    );

    final messageRow = SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children:
              isMine
                  ? [const Spacer(), fixedBubbleSlot, tail]
                  : [tail, fixedBubbleSlot, const Spacer()],
        ),
      ),
    );
    if (!animateOnMount) return messageRow;

    const beginOffset = 24.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 1, end: 0),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: 1 - (value * 0.08),
          child: Transform.translate(
            offset: Offset(beginOffset * value, 0),
            child: child,
          ),
        );
      },
      child: messageRow,
    );
  }

  Widget _buildTail(Color color, {required bool incoming}) {
    return ClipPath(
      clipper: _TailClipper(incoming: incoming),
      child: Container(width: _tailW, height: _tailH, color: color),
    );
  }

  Widget _buildTimeRow() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (isEdited && !isDeleted)
          Text(
            'Edited ',
            style: TextStyle(
              color: Colors.white.withOpacity(isMine ? 0.65 : 0.45),
              fontSize: 11,
              height: 1,
            ),
          ),
        Text(
          time,
          style: TextStyle(
            color: Colors.white.withOpacity(isMine ? 0.65 : 0.45),
            fontSize: 11,
            height: 1,
          ),
        ),
        if (isMine) ...[const SizedBox(width: 3), _buildStatusIcon()],
      ],
    );
  }

  Widget _buildStatusIcon() {
    switch (status) {
      case MessageStatus.sending:
        return Icon(
          Icons.access_time_rounded,
          size: 13,
          color: Colors.white.withOpacity(0.55),
        );
      case MessageStatus.sent:
        return Icon(
          Icons.done,
          size: 14,
          color: Colors.white.withOpacity(0.65),
        );
      case MessageStatus.delivered:
        return Icon(
          Icons.done_all,
          size: 14,
          color: Colors.white.withOpacity(0.65),
        );
      case MessageStatus.read:
        return const Icon(Icons.done_all, size: 14, color: _readGreen);
      case MessageStatus.failed:
        return const Icon(
          Icons.error_outline,
          size: 14,
          color: Colors.redAccent,
        );
      default:
        return Icon(
          Icons.done_all,
          size: 14,
          color: Colors.white.withOpacity(0.65),
        );
    }
  }
}

class _VideoMessageBubble extends StatelessWidget {
  final int totalSeconds;
  final Widget timeWidget;

  const _VideoMessageBubble({
    required this.totalSeconds,
    required this.timeWidget,
  });

  String _fmt(int s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 27,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Video message',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.92),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _fmt(totalSeconds),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.65),
                  fontSize: 12,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: timeWidget,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Voice note player ─────────────────────────────────────────────────────────
//
// Renders a WhatsApp-style row:
//   [play/pause]  [waveform bars]  [elapsed / total]
//
// Uses flutter_sound FlutterSoundPlayer to stream from the CDN URL.

class _VoiceNotePlayer extends StatefulWidget {
  final String audioUrl;
  final int totalSeconds;
  final bool isMine;
  final Widget timeWidget;

  const _VoiceNotePlayer({
    required this.audioUrl,
    required this.totalSeconds,
    required this.isMine,
    required this.timeWidget,
  });

  @override
  State<_VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<_VoiceNotePlayer> {
  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  bool _playerReady = false;
  bool _isPlaying = false;
  int _elapsed = 0; // seconds played so far
  Timer? _timer;
  StreamSubscription? _playerSub;

  @override
  void initState() {
    super.initState();
    _openPlayer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _playerSub?.cancel();
    _player.closePlayer();
    super.dispose();
  }

  Future<void> _openPlayer() async {
    await _player.openPlayer();
    setState(() => _playerReady = true);
  }

  Future<void> _togglePlay() async {
    if (!_playerReady || widget.audioUrl.isEmpty) return;

    if (_isPlaying) {
      await _player.pausePlayer();
      _timer?.cancel();
      setState(() => _isPlaying = false);
    } else {
      if (_player.isPaused) {
        await _player.resumePlayer();
      } else {
        // Reset if we finished previously
        _elapsed = 0;
        await _player.startPlayer(
          fromURI: widget.audioUrl,
          codec: Codec.aacADTS,
          whenFinished: () {
            _timer?.cancel();
            if (mounted)
              setState(() {
                _isPlaying = false;
                _elapsed = 0;
              });
          },
        );
      }
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _elapsed < widget.totalSeconds) {
          setState(() => _elapsed++);
        }
      });
      setState(() => _isPlaying = true);
    }
  }

  String _fmt(int s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final double progress =
        widget.totalSeconds > 0
            ? (_elapsed / widget.totalSeconds).clamp(0.0, 1.0)
            : 0.0;

    return SizedBox(
      width: 220,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // ── Play / pause button ────────────────────────────────────
              GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // ── Waveform + progress ────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _WaveformBars(progress: progress),
                    const SizedBox(height: 4),
                    // elapsed / total
                    Text(
                      '${_fmt(_elapsed)} / ${_fmt(widget.totalSeconds)}',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // ── Time + ticks row (same as text bubble) ─────────────────────
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: widget.timeWidget,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Waveform bars ─────────────────────────────────────────────────────────────
//
// Static decorative bars (like WhatsApp). Progress splits them into
// played (white) vs unplayed (white 30%) segments.

class _WaveformBars extends StatelessWidget {
  final double progress; // 0.0 – 1.0

  const _WaveformBars({required this.progress});

  static const List<double> _heights = [
    6,
    10,
    14,
    8,
    18,
    12,
    20,
    10,
    16,
    8,
    14,
    18,
    6,
    12,
    20,
    10,
    16,
    8,
    14,
    18,
    12,
    6,
    10,
    16,
    8,
  ];

  @override
  Widget build(BuildContext context) {
    final int playedCount = (_heights.length * progress).round();

    return SizedBox(
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_heights.length, (i) {
          final played = i < playedCount;
          return Container(
            width: 3,
            height: _heights[i],
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(played ? 0.9 : 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }
}

// ── Text bubble content (unchanged from original) ─────────────────────────────

class _BubbleContent extends StatelessWidget {
  final String content;
  final Widget timeWidget;
  final bool isForwarded;
  final bool isStarred;
  final bool isDeleted;
  final bool isEdited;
  final String? replyPreview;
  final String? replySender;
  final bool isMine;

  const _BubbleContent({
    required this.content,
    required this.timeWidget,
    required this.isMine,
    this.isForwarded = false,
    this.isStarred = false,
    this.isDeleted = false,
    this.isEdited = false,
    this.replyPreview,
    this.replySender,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isForwarded)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.shortcut_rounded,
                        size: 14,
                        color: Colors.white.withOpacity(0.48),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Forwarded',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.48),
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
              if (replyPreview != null && replyPreview!.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(isMine ? 0.16 : 0.22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      left: BorderSide(
                        color:
                            isMine
                                ? Colors.white.withOpacity(0.8)
                                : const Color(0xFF4DA3FF),
                        width: 3,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (replySender != null && replySender!.isNotEmpty)
                        Text(
                          replySender!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF9BD2FF),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      Text(
                        replyPreview!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.68),
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              Text.rich(
                TextSpan(
                  children: [
                    if (isStarred)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.star_rounded,
                            size: 15,
                            color: Colors.white.withOpacity(0.72),
                          ),
                        ),
                      ),
                    TextSpan(
                      text: isDeleted ? 'This message was deleted' : content,
                      style: TextStyle(
                        color: Colors.white.withOpacity(isDeleted ? 0.65 : 1),
                        fontSize: 15,
                        height: 1.35,
                        fontStyle:
                            isDeleted ? FontStyle.italic : FontStyle.normal,
                      ),
                    ),
                    WidgetSpan(
                      child: Opacity(
                        opacity: 0,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: timeWidget,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(bottom: 0, right: 0, child: timeWidget),
      ],
    );
  }
}

// ── Tail clipper (unchanged from original) ────────────────────────────────────

class _TailClipper extends CustomClipper<Path> {
  final bool incoming;
  const _TailClipper({required this.incoming});

  @override
  Path getClip(Size size) {
    final path = Path();
    if (incoming) {
      path.moveTo(size.width, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
      path.close();
    } else {
      path.moveTo(0, 0);
      path.lineTo(0, size.height);
      path.lineTo(size.width, size.height);
      path.close();
    }
    return path;
  }

  @override
  bool shouldReclip(_TailClipper old) => old.incoming != incoming;
}
