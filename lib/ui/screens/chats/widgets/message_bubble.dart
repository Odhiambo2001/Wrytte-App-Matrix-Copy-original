import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/attachment_local_store.dart';
import 'package:wrytte/ui/widgets/full_screen_image_viewer.dart';
import 'package:wrytte/ui/widgets/full_screen_video_viewer.dart';
import 'package:wrytte/ui/widgets/wrytte_file_card.dart';
import 'package:wrytte/ui/widgets/wrytte_link_preview.dart';
import 'package:wrytte/ui/widgets/wrytte_persistent_image.dart';
import 'package:wrytte/ui/widgets/wrytte_video_thumbnail.dart';

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
  final String? senderName;
  final bool showAdminLabel;
  final bool showTail;
  final MessageStatus? status;

  // ── Voice note fields (null = plain text bubble) ───────────────────────────
  final bool isVoiceNote;
  final bool isVideoNote;
  final int? voiceDuration; // total seconds
  final String? audioUrl; // CDN URL from Matrix media upload
  final String? attachmentType;
  final String? attachmentUrl;
  final bool isForwarded;
  final bool isStarred;
  final bool isPinned;
  final bool isDeleted;
  final bool isEdited;
  final String? replyPreview;
  final String? replySender;
  final bool animateOnMount;
  final double? maxWidth;

  static const Color _blue = Color(0xFF4DA3FF);
  static const Color _incoming = Color(0xFF23262C);
  static const Color _readGreen = Color(0xFF4CAF50);

  const MessageBubble({
    super.key,
    required this.content,
    required this.time,
    required this.isMine,
    this.senderName,
    this.showAdminLabel = false,
    this.showTail = true,
    this.status,
    // voice note params
    this.isVoiceNote = false,
    this.isVideoNote = false,
    this.voiceDuration,
    this.audioUrl,
    this.attachmentType,
    this.attachmentUrl,
    this.isForwarded = false,
    this.isStarred = false,
    this.isPinned = false,
    this.isDeleted = false,
    this.isEdited = false,
    this.replyPreview,
    this.replySender,
    this.animateOnMount = true,
    this.maxWidth,
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
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!isMine &&
                (senderName?.trim().isNotEmpty == true || showAdminLabel))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    if (senderName?.trim().isNotEmpty == true)
                      Text(
                        senderName!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFFFC861),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    if (showAdminLabel) ...[
                      const SizedBox(width: 60),
                      const Text(
                        'Admin',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (isVoiceNote)
              _VoiceNotePlayer(
                audioUrl: audioUrl ?? '',
                totalSeconds: voiceDuration ?? 0,
                isMine: isMine,
                timeWidget: timeWidget,
              )
            else if (attachmentType == 'image')
              _ImageMessageBubble(
                imageUrl: attachmentUrl ?? '',
                timeWidget: timeWidget,
                isForwarded: isForwarded,
              )
            else if (attachmentType == 'file')
              WrytteFileCard(
                fileName: content.trim().isEmpty ? 'File' : content,
                source: attachmentUrl ?? '',
                trailing: timeWidget,
                isForwarded: isForwarded,
              )
            else if (isVideoNote)
              _VideoMessageBubble(
                videoUrl: attachmentUrl ?? '',
                totalSeconds: voiceDuration ?? 0,
                timeWidget: timeWidget,
                isForwarded: isForwarded,
              )
            else
              _BubbleContent(
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
          ],
        ),
      ),
    );

    final maxBubbleWidth = maxWidth ?? MediaQuery.sizeOf(context).width * 0.78;
    final tail =
        showTail
            ? _buildTail(bubbleColor, incoming: !isMine)
            : const SizedBox(width: _tailW, height: _tailH);
    final constrainedBubble = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxBubbleWidth),
      child: bubble,
    );

    final messageRow = SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children:
              isMine
                  ? [const Spacer(), constrainedBubble, tail]
                  : [tail, constrainedBubble, const Spacer()],
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
        if (isPinned) ...[
          Icon(
            Icons.push_pin,
            size: 13,
            color: Colors.white.withOpacity(isMine ? 0.72 : 0.55),
          ),
          const SizedBox(width: 3),
        ],
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
  final String videoUrl;
  final int totalSeconds;
  final Widget timeWidget;
  final bool isForwarded;

  const _VideoMessageBubble({
    required this.videoUrl,
    required this.totalSeconds,
    required this.timeWidget,
    this.isForwarded = false,
  });

  String _fmt(int s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 230,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isForwarded) const _ForwardedLabel(),
          GestureDetector(
            onTap: () => FullScreenVideoViewer.open(context, videoUrl),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  WrytteVideoThumbnail(source: videoUrl),
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.42),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 42,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (totalSeconds > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      _fmt(totalSeconds),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.65),
                        fontSize: 12,
                      ),
                    ),
                  ),
                timeWidget,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageMessageBubble extends StatefulWidget {
  final String imageUrl;
  final Widget timeWidget;
  final bool isForwarded;

  const _ImageMessageBubble({
    required this.imageUrl,
    required this.timeWidget,
    required this.isForwarded,
  });

  @override
  State<_ImageMessageBubble> createState() => _ImageMessageBubbleState();
}

class _ImageMessageBubbleState extends State<_ImageMessageBubble> {
  @override
  Widget build(BuildContext context) {
    final image = _attachmentImage(widget.imageUrl);
    return SizedBox(
      width: 230,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.isForwarded) const _ForwardedLabel(),
          GestureDetector(
            onTap: () => FullScreenImageViewer.open(context, widget.imageUrl),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Container(
                  color: Colors.black.withOpacity(0.18),
                  child: image,
                ),
              ),
            ),
          ),
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

  Widget _attachmentImage(String url) {
    return WryttePersistentImage(
      source: url,
      fit: BoxFit.cover,
      placeholder: const _AttachmentPlaceholder(
        icon: Icons.image_outlined,
        label: 'Photo',
      ),
      errorWidget: const _AttachmentPlaceholder(
        icon: Icons.broken_image_outlined,
        label: 'Photo',
      ),
    );
  }
}

class _FileMessageBubble extends StatefulWidget {
  final String fileName;
  final String fileUrl;
  final Widget timeWidget;
  final bool isForwarded;

  const _FileMessageBubble({
    required this.fileName,
    required this.fileUrl,
    required this.timeWidget,
    required this.isForwarded,
  });

  @override
  State<_FileMessageBubble> createState() => _FileMessageBubbleState();
}

class _FileMessageBubbleState extends State<_FileMessageBubble> {
  bool _opening = false;

  Future<void> _downloadAndOpen() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final source = widget.fileUrl.trim();
      if (source.isEmpty) throw StateError('File URL is unavailable');

      File sourceFile;
      if (source.startsWith('http')) {
        final cache = DefaultCacheManager();
        final cached = await cache.getFileFromCache(source);
        sourceFile = cached?.file ?? await cache.getSingleFile(source);
      } else {
        sourceFile = File(source);
      }
      if (!await sourceFile.exists()) {
        throw const FileSystemException('Downloaded file is unavailable');
      }

      final documents = await getApplicationDocumentsDirectory();
      final downloads = Directory('${documents.path}/Wrytte Downloads');
      await downloads.create(recursive: true);
      final safeName = _safeFileName(widget.fileName, sourceFile.path);
      final localFile = File('${downloads.path}/$safeName');
      if (!await localFile.exists() || await localFile.length() == 0) {
        await sourceFile.copy(localFile.path);
      }

      final result = await OpenFilex.open(localFile.path);
      if (result.type != ResultType.done) {
        throw StateError(result.message);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open file: $error'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String _safeFileName(String displayName, String sourcePath) {
    var name = displayName.trim();
    if (name.isEmpty || name.toLowerCase() == 'file') {
      name = p.basename(sourcePath);
    }
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return name.isEmpty ? 'Wrytte file' : name;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _downloadAndOpen,
      child: SizedBox(
        width: 230,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.isForwarded) const _ForwardedLabel(),
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child:
                      _opening
                          ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(
                            Icons.insert_drive_file_outlined,
                            color: Colors.white,
                          ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.92),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: widget.timeWidget,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentPlaceholder extends StatelessWidget {
  final IconData icon;
  final String label;

  const _AttachmentPlaceholder({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 34),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _ForwardedLabel extends StatelessWidget {
  const _ForwardedLabel();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.shortcut_rounded,
            color: Colors.white.withOpacity(0.62),
            size: 15,
          ),
          const SizedBox(width: 4),
          Text(
            'Forwarded',
            style: TextStyle(
              color: Colors.white.withOpacity(0.62),
              fontSize: 13,
              fontStyle: FontStyle.italic,
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
        final copy = await AttachmentLocalStore.instance.ensureComplete(
          source: widget.audioUrl,
          fileName: 'voice_message.aac',
        );
        await _player.startPlayer(
          fromURI: copy.file.path,
          codec: Codec.aacADTS,
          whenFinished: () {
            _timer?.cancel();
            if (mounted) {
              setState(() {
                _isPlaying = false;
                _elapsed = 0;
              });
            }
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
    final link = isDeleted ? null : firstLinkInText(content);
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
              if (link != null) ...[
                WrytteLinkPreview(url: link),
                const SizedBox(height: 6),
              ],
              _LinkedMessageText(
                text:
                    isDeleted
                        ? (content.trim().isEmpty
                            ? 'This message was deleted'
                            : content.trim())
                        : linkDisplayText(content),
                isDeleted: isDeleted,
                isStarred: isStarred,
                trailingWidget: timeWidget,
              ),
            ],
          ),
        ),
        Positioned(bottom: 0, right: 0, child: timeWidget),
      ],
    );
  }
}

class _LinkedMessageText extends StatefulWidget {
  final String text;
  final bool isDeleted;
  final bool isStarred;
  final Widget trailingWidget;

  const _LinkedMessageText({
    required this.text,
    required this.isDeleted,
    required this.isStarred,
    required this.trailingWidget,
  });

  @override
  State<_LinkedMessageText> createState() => _LinkedMessageTextState();
}

class _LinkedMessageTextState extends State<_LinkedMessageText> {
  final List<TapGestureRecognizer> _recognizers = [];

  static final RegExp _urlPattern = RegExp(
    r'((?:https?:\/\/|www\.)[^\s]+|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:\/[^\s]*)?)',
  );

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();

    final baseStyle = TextStyle(
      color: Colors.white.withOpacity(widget.isDeleted ? 0.65 : 1),
      fontSize: 15,
      height: 1.35,
      fontStyle: widget.isDeleted ? FontStyle.italic : FontStyle.normal,
    );

    final spans = <InlineSpan>[
      if (widget.isStarred)
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
    ];

    if (widget.isDeleted) {
      spans.add(TextSpan(text: widget.text, style: baseStyle));
    } else {
      var cursor = 0;
      for (final match in _urlPattern.allMatches(widget.text)) {
        if (match.start > cursor) {
          spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
        }
        final raw = match.group(0) ?? '';
        final clean = _trimUrlPunctuation(raw);
        if (_looksLikeAttachmentFileName(clean)) {
          spans.add(TextSpan(text: raw));
          cursor = match.end;
          continue;
        }
        final trailing = raw.substring(clean.length);
        final recognizer =
            TapGestureRecognizer()..onTap = () => _openLink(clean);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: clean,
            style: baseStyle.copyWith(
              color: const Color(0xFFB9DDFF),
              decoration: TextDecoration.underline,
              decorationColor: const Color(0xFFB9DDFF),
            ),
            recognizer: recognizer,
          ),
        );
        if (trailing.isNotEmpty) spans.add(TextSpan(text: trailing));
        cursor = match.end;
      }
      if (cursor < widget.text.length) {
        spans.add(TextSpan(text: widget.text.substring(cursor)));
      }
    }

    spans.add(
      WidgetSpan(
        child: Opacity(
          opacity: 0,
          child: Padding(
            padding: const EdgeInsets.only(left: 6),
            child: widget.trailingWidget,
          ),
        ),
      ),
    );

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }

  String _trimUrlPunctuation(String value) {
    return value.replaceFirst(RegExp(r'[),.;:!?]+$'), '');
  }

  bool _looksLikeAttachmentFileName(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return false;
    }
    return RegExp(
      r'\.(png|jpe?g|gif|webp|bmp|heic|heif|mp4|mov|m4v|webm|mkv|3gp|pdf|docx?|pptx?|xlsx?|txt|csv|zip|rar|7z|apk)$',
    ).hasMatch(trimmed);
  }

  Future<void> _openLink(String value) async {
    final url =
        value.startsWith('http://') || value.startsWith('https://')
            ? value
            : 'https://$value';
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
