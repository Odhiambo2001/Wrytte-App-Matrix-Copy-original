import 'dart:async';

import 'dart:math' as math;

import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:video_player/video_player.dart';

import 'package:visibility_detector/visibility_detector.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';

import 'package:wrytte/ui/chat/view_models/chat_video_playback_view_model.dart';

import 'package:wrytte/ui/chat/widgets/message_actions/message_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_swipe_action_target.dart';

import 'package:wrytte/ui/chat/widgets/message_bubble_surface.dart';

import 'package:wrytte/ui/chat/widgets/message_metadata.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';

import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

import 'package:wrytte/ui/media/video/wrytte_video_session.dart';

import 'package:wrytte/ui/media/video/wrytte_video_surface.dart';

import 'package:wrytte/ui/media/views/full_screen_video_view.dart';

// =============================================================================

// VIDEO MESSAGE BUBBLE

// =============================================================================

class VideoMessageBubble extends StatelessWidget {

  const VideoMessageBubble({

    super.key,

    required this.message,

    required this.playback,

    this.showTail = true,

    this.actionConfig,

    this.onBeforePlay,

  });

  final ChatMessagePresentation message;

  final ChatVideoPlaybackViewModel playback;

  final bool showTail;

  final MessageActionConfig? actionConfig;

  final Future<void> Function()? onBeforePlay;

  // ===========================================================================

  // Media geometry

  //

  // Same sizing philosophy as ImageMessageBubble.

  // ===========================================================================

  static const double _bubbleRadius = 18.0;

  static const double _outlineWidth = 1.8;

  static const double _minimumMediaWidth = 148.0;

  static const double _maximumBubbleWidth = 420.0;

  static const double _captionWidthFactor = 0.80;

  static const double _landscapeScreenInset = 64.0;

  static const double _portraitWidthFactor = 0.70;

  static const double _maximumMediaHeight = 420.0;

  static const double _maximumMediaHeightFactor = 0.44;

  static const double _minimumAspectRatio = 0.45;

  static const double _maximumAspectRatio = 2.60;

  // ===========================================================================

  // Caption

  // ===========================================================================

  static const double _captionHorizontalPadding = 12.0;

  static const double _captionMetadataGap = 8.0;

  static const double _captionMinimumMetadataGap = 6.0;

  static const TextStyle _captionStyle = TextStyle(

    fontFamily: WrytteTypography.primaryFontFamily,

    color: WrytteColors.textPrimary,

    fontSize: 16,

    fontWeight: FontWeight.w400,

    height: 1.28,

  );

  // ===========================================================================

  // Media overlays

  // ===========================================================================

  static const double _timeBadgeSideInset = 5.0;

  static const double _timeBadgeBottomInset = 4.0;

  static const double _durationBadgeSideInset = 7.0;

  static const double _durationBadgeTopInset = 7.0;

  static const double _outgoingOverlayShift = 4.0;

  // ===========================================================================

  // Message

  // ===========================================================================

  bool get _isMine => message.isMine;

  String get _source => message.assetPath?.trim() ?? '';

  Color get _bubbleColor =>

      _isMine ? WrytteColors.primary : WrytteColors.surfaceRaised;

  Color get _outlineColor => _bubbleColor;

  // ===========================================================================

  // Caption normalization

  // ===========================================================================

  String? get _caption {

    final raw = message.text?.trim() ?? '';

    if (raw.isEmpty) {

      return null;

    }

    final normalized = raw.toLowerCase();

    if (const <String>{

      'video',

      'attachment',

      'video message',

    }.contains(normalized)) {

      return null;

    }

    if (RegExp(

      r'^[^/\\\\\\\\]+\\\.(?:mp4|mov|m4v|webm|mkv|avi|3gp)$',

      caseSensitive: false,

    ).hasMatch(raw)) {

      return null;

    }

    return raw;

  }

  bool get _hasCaption => _caption != null;

  // ===========================================================================

  // Playback state

  // ===========================================================================

  VideoPlayerController? get _controller {

    return playback.controllerFor(message.id);

  }

  WrytteVideoPhase get _phase {

    return playback.phaseFor(message.id);

  }

  Future<void> _toggleMute() {

    return playback.toggleMute(message.id);

  }

  // ===========================================================================

  // Stable aspect ratio

  //

  // IMPORTANT:

  //

  // We intentionally do NOT resize the bubble from the decoded controller.

  //

  // The dimensions stored with the message determine the layout before AND

  // after Play.

  // ===========================================================================

  double get _presentationAspectRatio {

    final width = message.mediaWidth;

    final height = message.mediaHeight;

    if (width != null && width > 0 && height != null && height > 0) {

      return width / height;

    }

    return 4 / 3;

  }

  // ===========================================================================

  // BUILD

  // ===========================================================================

  @override

  Widget build(BuildContext context) {

    return VisibilityDetector(

      key: ValueKey<String>('wrytte-video-${message.id}'),

      onVisibilityChanged: (info) {

        unawaited(

          playback.setVisibility(

            messageId: message.id,

            visibleFraction: info.visibleFraction,

          ),

        );

      },

      child: AnimatedBuilder(

        animation: playback,

        builder: (context, child) {

          return _buildBubble(context);

        },

      ),

    );

  }

  // ===========================================================================

  // BUBBLE

  // ===========================================================================

  Widget _buildBubble(BuildContext context) {

    return LayoutBuilder(

      builder: (context, constraints) {

        final screenSize = MediaQuery.sizeOf(context);

        final double tailExtent = showTail

            ? MessageBubbleSurface.tailExtent

            : 0.0;

        final double availableBodyWidth = constraints.hasBoundedWidth

            ? math.max(0.0, constraints.maxWidth - tailExtent).toDouble()

            : screenSize.width;

        final double aspect = _presentationAspectRatio

            .clamp(_minimumAspectRatio, _maximumAspectRatio)

            .toDouble();

        // =====================================================================

        // Height limit

        // =====================================================================

        final double maximumMediaHeight = math

            .min(

              screenSize.height * _maximumMediaHeightFactor,

              _maximumMediaHeight,

            )

            .toDouble();

        // =====================================================================

        // Width

        //

        // Same responsive rules as image bubbles.

        // =====================================================================

        final double preferredMaximumWidth = aspect >= 1.0

            ? math

                  .min(

                    screenSize.width - _landscapeScreenInset,

                    _maximumBubbleWidth,

                  )

                  .toDouble()

            : math

                  .min(screenSize.width * _portraitWidthFactor, 340.0)

                  .toDouble();

        double videoWidth = math

            .min(availableBodyWidth, preferredMaximumWidth)

            .toDouble();

        double videoHeight = videoWidth / aspect;

        // =====================================================================

        // Height clamp

        // =====================================================================

        if (videoHeight > maximumMediaHeight) {

          videoHeight = maximumMediaHeight;

          videoWidth = videoHeight * aspect;

        }

        // =====================================================================

        // Minimum width

        // =====================================================================

        if (videoWidth < _minimumMediaWidth) {

          videoWidth = math

              .min(_minimumMediaWidth, availableBodyWidth)

              .toDouble();

          videoHeight = math

              .min(maximumMediaHeight, videoWidth / aspect)

              .toDouble();

        }

        // =====================================================================

        // Caption can widen the bubble.

        //

        // The actual video NEVER stretches.

        // =====================================================================

        final double maximumCaptionWidth = math

            .min(

              availableBodyWidth,

              math.min(

                _maximumBubbleWidth,

                screenSize.width * _captionWidthFactor,

              ),

            )

            .toDouble();

        final metadataWidth = _measureMetadataWidth(context);

        final double captionRequiredWidth = _hasCaption

            ? _measureCaptionWidth(

                context,

                caption: _caption!,

                metadataWidth: metadataWidth,

                maximumWidth: maximumCaptionWidth,

              )

            : 0.0;

        final double bodyWidth = _hasCaption

            ? math.max(videoWidth, captionRequiredWidth).toDouble()

            : videoWidth;

        final double surfaceWidth = bodyWidth + tailExtent;

        final Widget bubble = AnimatedSize(

          duration: const Duration(milliseconds: 220),

          curve: Curves.easeOutCubic,

          alignment: _isMine ? Alignment.bottomRight : Alignment.bottomLeft,

          child: SizedBox(

            width: surfaceWidth,

            child: _VideoMediaFrame(

              isMine: _isMine,

              showTail: showTail,

              radius: _bubbleRadius,

              outlineColor: _outlineColor,

              outlineWidth: _outlineWidth,

              child: ColoredBox(

                color: _bubbleColor,

                child: Column(

                  mainAxisSize: MainAxisSize.min,

                  crossAxisAlignment: CrossAxisAlignment.stretch,

                  children: [

                    // =========================================================

                    // VIDEO

                    // =========================================================

                    _buildVideoArea(

                      surfaceWidth: surfaceWidth,

                      bodyWidth: bodyWidth,

                      videoWidth: videoWidth,

                      videoHeight: videoHeight,

                      tailExtent: tailExtent,

                    ),

                    // =========================================================

                    // CAPTION

                    // =========================================================

                    if (_hasCaption)

                      _VideoTextCaption(

                        text: _caption!,

                        message: message,

                        isMine: _isMine,

                        showTail: showTail,

                        tailExtent: tailExtent,

                      ),

                  ],

                ),

              ),

            ),

          ),

        );

        // =====================================================================

        // Grouped-message alignment

        // =====================================================================

        final groupedInset = showTail

            ? EdgeInsets.zero

            : EdgeInsetsDirectional.only(

                start: _isMine ? 0 : MessageBubbleSurface.tailExtent,

                end: _isMine ? MessageBubbleSurface.tailExtent : 0,

              );

        final Widget content = Padding(

          padding: groupedInset,

          child: Padding(

            padding: const EdgeInsets.symmetric(vertical: 1),

            child: bubble,

          ),

        );

        final config = actionConfig;

        return Align(

          alignment: _isMine

              ? AlignmentDirectional.centerEnd

              : AlignmentDirectional.centerStart,

          child: config == null || !config.hasContent

              ? content

              : MessageActionTarget(
                  config: config,
                  child: MessageSwipeActionTarget(
                    config: config,
                    child: content,
                  ),
                ),

        );

      },

    );

  }

  // ===========================================================================

  // VIDEO AREA

  // ===========================================================================

  Widget _buildVideoArea({

    required double surfaceWidth,

    required double bodyWidth,

    required double videoWidth,

    required double videoHeight,

    required double tailExtent,

  }) {

    final controller = _controller;

    final phase = _phase;

    final bool initialized =

        controller != null && controller.value.isInitialized;

    final bool playing = phase == WrytteVideoPhase.playing;

    final bool loading = phase == WrytteVideoPhase.initializing;

    final bool hasSideSpace = (bodyWidth - videoWidth).abs() > 0.5;

    return SizedBox(

      width: surfaceWidth,

      height: videoHeight,

      child: _VideoOpenTarget(

        key: ValueKey<String>('video-open-${message.id}'),

        message: message,

        messageId: message.id,

        source: _source,

        playback: playback,

        beforePlay: onBeforePlay,

        actionConfig: actionConfig,

        borderRadius: BorderRadius.circular(_bubbleRadius),

        child: Stack(

          fit: StackFit.expand,

          children: [

            // ===============================================================

            // BACKGROUND

            // ===============================================================

            const ColoredBox(color: Colors.black),

            // ===============================================================

            // CAPTION MADE BUBBLE WIDER:

            //

            // Use the SAME STATIC thumbnail behind the video and blur it.

            //

            // This gives us the same media treatment as the image bubble

            // without rendering two live video surfaces.

            // ===============================================================

            if (hasSideSpace) _VideoBlurredPoster(message: message),

            // ===============================================================

            // FOREGROUND MEDIA

            // ===============================================================

            if (!_hasCaption)

              Positioned.fill(

                child: initialized

                    ? WrytteVideoSurface(

                        controller: controller,

                        fit: BoxFit.cover,

                      )

                    : _VideoPoster(message: message),

              )

            else

              PositionedDirectional(

                start: !_isMine && showTail ? tailExtent : 0,

                end: _isMine && showTail ? tailExtent : 0,

                top: 0,

                bottom: 0,

                child: Align(

                  alignment: Alignment.center,

                  child: SizedBox(

                    width: videoWidth,

                    height: videoHeight,

                    child: initialized

                        ? WrytteVideoSurface(

                            controller: controller,

                            fit: BoxFit.cover,

                          )

                        : _VideoPoster(message: message),

                  ),

                ),

              ),

            // ===============================================================

            // OLD WRYTTE PLAY BUTTON

            // ===============================================================

            if (!playing) Center(child: _VideoPlayOverlay(loading: loading)),

            // ===============================================================

            // DURATION + MUTE

            //

            // Whole pill is clickable.

            // ===============================================================

            if (initialized)

              PositionedDirectional(

                start: !_isMine && showTail

                    ? tailExtent + _durationBadgeSideInset

                    : _durationBadgeSideInset,

                top: _durationBadgeTopInset,

                child: _InlineVideoDurationBadge(

                  controller: controller,

                  fallbackDurationSeconds: message.videoDurationSeconds,

                  muted: playback.muted,

                  // IMPORTANT:

                  //

                  // Entire duration/sound pill calls this.

                  onToggleMute: () {

                    unawaited(_toggleMute());

                  },

                ),

              ),

            // ===============================================================

            // TIME + TICKS

            // ===============================================================

            if (!_hasCaption)

              PositionedDirectional(

                end: _isMine && showTail

                    ? tailExtent + _timeBadgeSideInset

                    : _timeBadgeSideInset,

                bottom: _timeBadgeBottomInset,

                child: Transform.translate(

                  offset: Offset(_isMine ? _outgoingOverlayShift : 0, 0),

                  child: _VideoMediaTimeBadge(

                    compensateStatusOffset: message.isMine,

                    child: MessageMetadata(message: message, onMedia: true),

                  ),

                ),

              ),

          ],

        ),

      ),

    );

  }

  // ===========================================================================

  // CAPTION WIDTH

  // ===========================================================================

  double _measureCaptionWidth(

    BuildContext context, {

    required String caption,

    required double metadataWidth,

    required double maximumWidth,

  }) {

    final maximumContentWidth = math.max(

      0.0,

      maximumWidth - (_captionHorizontalPadding * 2),

    );

    final layout = _MediaTextLayoutResolver.resolve(

      context: context,

      text: caption,

      style: _captionStyle,

      maximumWidth: maximumContentWidth,

      metadataWidth: metadataWidth,

      preferredMetadataGap: _captionMetadataGap,

      minimumMetadataGap: _captionMinimumMetadataGap,

    );

    return (layout.width + (_captionHorizontalPadding * 2))

        .clamp(0.0, maximumWidth)

        .toDouble();

  }

  double _measureMetadataWidth(BuildContext context) {

    return MessageMetadata.measure(context, message).width;

  }

}

// =============================================================================

// VIDEO POSTER

//

// Priority:

//

// 1. local/gallery thumbnail bytes

// 2. remote thumbnail URL

// 3. dark fallback

// =============================================================================

/// Keeps the first tap lightweight (inline playback), then hands a subsequent

/// tap to the reusable full-screen viewer without losing the visual origin.

class _VideoOpenTarget extends StatefulWidget {

  const _VideoOpenTarget({

    super.key,

    required this.message,

    required this.messageId,

    required this.source,

    required this.playback,

    required this.borderRadius,

    required this.child,

    this.beforePlay,

    this.actionConfig,

  });

  final ChatMessagePresentation message;

  final String messageId;

  final String source;

  final ChatVideoPlaybackViewModel playback;

  final BorderRadius borderRadius;

  final Widget child;

  final Future<void> Function()? beforePlay;

  final MessageActionConfig? actionConfig;

  @override

  State<_VideoOpenTarget> createState() => _VideoOpenTargetState();

}

class _VideoOpenTargetState extends State<_VideoOpenTarget> {

  final GlobalKey _surfaceKey = GlobalKey(debugLabel: 'chat-video-surface');

  bool _inlinePlaybackStarted = false;

  bool _openingViewer = false;

  Future<void> _handleTap() async {

    if (_openingViewer || widget.source.trim().isEmpty) return;

    if (!_inlinePlaybackStarted) {

      _inlinePlaybackStarted = true;

      await widget.playback.toggle(

        messageId: widget.messageId,

        source: widget.source,

        beforePlay: widget.beforePlay,

      );

      return;

    }

    _openingViewer = true;

    try {

      await widget.playback.pauseIfActive(widget.messageId);

      if (!mounted) return;

      final origin = ExpandingSurfaceOrigin.fromKey(

        _surfaceKey,

        borderRadius: widget.borderRadius,

      );

      await showWrytteVideoViewer(

        context,

        source: widget.source,

        origin: origin,

        title: widget.message.isMine

            ? 'You'

            : (widget.message.senderName?.trim().isNotEmpty == true

                  ? widget.message.senderName!.trim()

                  : 'Wrytte Team'),

        subtitle: widget.message.timeLabel,

        caption: widget.message.text,

        onShare: _actionCallback(const MessageAction.forward()),

        onDownload: _actionCallback(const MessageAction.save()),

        onEdit: widget.message.isMine

            ? _actionCallback(const MessageAction.editMedia())

            : null,

        onReply: _dismissThenAction(const MessageAction.reply()),

        onShowInChat: () =>

            Navigator.of(context, rootNavigator: true).maybePop(),

        onDelete: _actionCallback(const MessageAction.delete()),

      );

    } finally {

      _openingViewer = false;

    }

  }

  VoidCallback? _actionCallback(MessageAction action) {

    final handler = widget.actionConfig?.onActionSelected;

    if (handler == null) return null;

    return () => unawaited(Future<void>.sync(() => handler(action)));

  }

  VoidCallback? _dismissThenAction(MessageAction action) {

    final handler = widget.actionConfig?.onActionSelected;

    if (handler == null) return null;

    return () {

      Navigator.of(context, rootNavigator: true).maybePop();

      unawaited(Future<void>.sync(() => handler(action)));

    };

  }

  @override

  Widget build(BuildContext context) {

    return GestureDetector(

      key: _surfaceKey,

      behavior: HitTestBehavior.opaque,

      onTap: () => unawaited(_handleTap()),

      child: widget.child,

    );

  }

}

class _VideoPoster extends StatelessWidget {

  const _VideoPoster({required this.message});

  final ChatMessagePresentation message;

  @override

  Widget build(BuildContext context) {

    final bytes = message.videoThumbnailBytes;

    final url = message.videoThumbnailUrl?.trim();

    // =========================================================================

    // MEMORY THUMBNAIL

    // =========================================================================

    if (bytes != null && bytes.isNotEmpty) {

      return SizedBox.expand(

        child: Image.memory(

          bytes,

          fit: BoxFit.cover,

          alignment: Alignment.center,

          gaplessPlayback: true,

          filterQuality: FilterQuality.medium,

        ),

      );

    }

    // =========================================================================

    // NETWORK THUMBNAIL

    // =========================================================================

    if (url != null && url.isNotEmpty) {

      return SizedBox.expand(

        child: Image.network(

          url,

          fit: BoxFit.cover,

          alignment: Alignment.center,

          gaplessPlayback: true,

          filterQuality: FilterQuality.medium,

          loadingBuilder: (context, child, loadingProgress) {

            if (loadingProgress == null) {

              return child;

            }

            return const _VideoPosterFallback();

          },

          errorBuilder: (context, error, stackTrace) {

            return const _VideoPosterFallback();

          },

        ),

      );

    }

    return const _VideoPosterFallback();

  }

}

// =============================================================================

// BLURRED VIDEO POSTER

//

// Static thumbnail only.

//

// No second VideoPlayer.

// =============================================================================

class _VideoBlurredPoster extends StatelessWidget {

  const _VideoBlurredPoster({required this.message});

  final ChatMessagePresentation message;

  bool get _hasPoster {

    final bytes = message.videoThumbnailBytes;

    final url = message.videoThumbnailUrl?.trim();

    return (bytes != null && bytes.isNotEmpty) ||

        (url != null && url.isNotEmpty);

  }

  @override

  Widget build(BuildContext context) {

    if (!_hasPoster) {

      return const _VideoSideFallback();

    }

    return ClipRect(

      child: ImageFiltered(

        imageFilter: ui.ImageFilter.blur(

          sigmaX: 18,

          sigmaY: 18,

          tileMode: TileMode.clamp,

        ),

        child: Transform.scale(

          scale: 1.16,

          child: _VideoPoster(message: message),

        ),

      ),

    );

  }

}

// =============================================================================

// FALLBACK POSTER

// =============================================================================

class _VideoPosterFallback extends StatelessWidget {

  const _VideoPosterFallback();

  @override

  Widget build(BuildContext context) {

    return const DecoratedBox(

      decoration: BoxDecoration(

        color: Color(0xFF101216),

        gradient: LinearGradient(

          begin: Alignment.topLeft,

          end: Alignment.bottomRight,

          colors: [Color(0xFF171A20), Color(0xFF090A0D)],

        ),

      ),

    );

  }

}

// =============================================================================

// SIDE FALLBACK

// =============================================================================

class _VideoSideFallback extends StatelessWidget {

  const _VideoSideFallback();

  @override

  Widget build(BuildContext context) {

    return const DecoratedBox(

      decoration: BoxDecoration(

        gradient: LinearGradient(

          begin: Alignment.centerLeft,

          end: Alignment.centerRight,

          colors: [

            Color(0xFF17191F),

            Colors.black,

            Colors.black,

            Color(0xFF17191F),

          ],

          stops: [0, .28, .72, 1],

        ),

      ),

    );

  }

}

// =============================================================================

// OLD WRYTTE PLAY CONTROL

//

// 48 × 48

// Play SVG = 26

// =============================================================================

class _VideoPlayOverlay extends StatelessWidget {

  const _VideoPlayOverlay({required this.loading});

  final bool loading;

  @override

  Widget build(BuildContext context) {

    return AnimatedScale(

      scale: loading ? 0.94 : 1,

      duration: const Duration(milliseconds: 160),

      curve: Curves.easeOutCubic,

      child: Container(

        width: 48,

        height: 48,

        alignment: Alignment.center,

        decoration: BoxDecoration(

          color: const Color(0xFF17191F).withValues(alpha: 0.84),

          shape: BoxShape.circle,

        ),

        child: AnimatedOpacity(

          duration: const Duration(milliseconds: 140),

          opacity: loading ? 0.46 : 1,

          child: WrytteSvgIcon(

            asset: 'assets/svg/Play icon .svg',

            size: 26,

            color: WrytteColors.textPrimary,

          ),

        ),

      ),

    );

  }

}

// =============================================================================

// DURATION + MUTE PILL

//

// The ENTIRE pill is clickable.

//

// Tap 0:03        → mute/unmute

// Tap sound icon  → mute/unmute

//

// Padding was intentionally reduced vertically so the pill is slimmer.

// =============================================================================

class _InlineVideoDurationBadge extends StatelessWidget {

  const _InlineVideoDurationBadge({

    required this.controller,

    required this.fallbackDurationSeconds,

    required this.muted,

    required this.onToggleMute,

  });

  final VideoPlayerController controller;

  final int? fallbackDurationSeconds;

  final bool muted;

  final VoidCallback onToggleMute;

  String _format(Duration duration) {

    final totalSeconds = math.max(0, duration.inSeconds);

    final hours = totalSeconds ~/ 3600;

    final minutes = (totalSeconds % 3600) ~/ 60;

    final seconds = totalSeconds % 60;

    if (hours > 0) {

      return '$hours:'

          '${minutes.toString().padLeft(2, '0')}:'

          '${seconds.toString().padLeft(2, '0')}';

    }

    return '$minutes:'

        '${seconds.toString().padLeft(2, '0')}';

  }

  @override

  Widget build(BuildContext context) {

    return ValueListenableBuilder<VideoPlayerValue>(

      valueListenable: controller,

      builder: (context, value, child) {

        final Duration duration = value.duration > Duration.zero

            ? value.duration

            : Duration(seconds: fallbackDurationSeconds ?? 0);

        final Duration rawPosition = value.position;

        final Duration position =

            duration > Duration.zero && rawPosition > duration

            ? duration

            : rawPosition;

        return Semantics(

          button: true,

          label: muted ? 'Unmute video' : 'Mute video',

          child: GestureDetector(

            behavior: HitTestBehavior.opaque,

            // ===============================================================

            // IMPORTANT:

            //

            // Entire pill toggles sound.

            // ===============================================================

            onTap: onToggleMute,

            child: DecoratedBox(

              decoration: BoxDecoration(

                color: WrytteColors.surface.withValues(alpha: 0.72),

                // Fully rounded pill.

                borderRadius: BorderRadius.circular(999),

              ),

              child: Padding(

                padding: const EdgeInsets.symmetric(

                  horizontal: 8,

                  // Smaller than the old 5px.

                  //

                  // This removes the excessive height visible in your

                  // screenshot.

                  vertical: 2,

                ),

                child: Row(

                  mainAxisSize: MainAxisSize.min,

                  crossAxisAlignment: CrossAxisAlignment.center,

                  children: [

                    // =========================================================

                    // ELAPSED TIME

                    // =========================================================

                    Text(

                      _format(position),

                      style: const TextStyle(

                        color: WrytteColors.textPrimary,

                        fontFamily: WrytteTypography.primaryFontFamily,

                        fontSize: 12,

                        fontWeight: FontWeight.w500,

                        height: 1,

                      ),

                    ),

                    const SizedBox(width: 2),

                    // =========================================================

                    // SOUND ICON

                    //

                    // Actual icon remains the old 13px size.

                    // =========================================================

                    SizedBox.square(

                      dimension: 20,

                      child: Center(

                        child: WrytteSvgIcon(

                          asset: muted

                              ? 'assets/svg/Nosound icon.svg'

                              : 'assets/svg/Sound icon.svg',

                          size: 13,

                          color: WrytteColors.textPrimary,

                        ),

                      ),

                    ),

                  ],

                ),

              ),

            ),

          ),

        );

      },

    );

  }

}

// =============================================================================

// CAPTION

// =============================================================================

class _VideoTextCaption extends StatelessWidget {

  const _VideoTextCaption({

    required this.text,

    required this.message,

    required this.isMine,

    required this.showTail,

    required this.tailExtent,

  });

  final String text;

  final ChatMessagePresentation message;

  final bool isMine;

  final bool showTail;

  final double tailExtent;

  static const double _horizontalPadding = 12;

  static const double _topPadding = 7;

  static const double _bottomPadding = 6;

  static const double _preferredMetadataGap = 8;

  static const double _minimumMetadataGap = 6;

  @override

  Widget build(BuildContext context) {

    final startPadding =

        _horizontalPadding + (!isMine && showTail ? tailExtent : 0);

    final endPadding =

        _horizontalPadding + (isMine && showTail ? tailExtent : 0);

    return LayoutBuilder(

      builder: (context, constraints) {

        final maximumContentWidth = math.max(

          0.0,

          constraints.maxWidth - startPadding - endPadding,

        );

        final metadataWidth = MessageMetadata.measure(context, message).width;

        final layout = _MediaTextLayoutResolver.resolve(

          context: context,

          text: text,

          style: VideoMessageBubble._captionStyle,

          maximumWidth: maximumContentWidth,

          metadataWidth: metadataWidth,

          preferredMetadataGap: _preferredMetadataGap,

          minimumMetadataGap: _minimumMetadataGap,

        );

        return Padding(

          padding: EdgeInsetsDirectional.fromSTEB(

            startPadding,

            _topPadding,

            endPadding,

            _bottomPadding,

          ),

          child: _MediaMeasuredTextBody(

            text: text,

            message: message,

            style: VideoMessageBubble._captionStyle,

            layout: layout,

          ),

        );

      },

    );

  }

}

class _MediaMeasuredTextBody extends StatelessWidget {

  const _MediaMeasuredTextBody({

    required this.text,

    required this.message,

    required this.style,

    required this.layout,

  });

  final String text;

  final ChatMessagePresentation message;

  final TextStyle style;

  final _MediaTextLayout layout;

  @override

  Widget build(BuildContext context) {

    final direction = Directionality.of(context);

    final scaler = MediaQuery.textScalerOf(context);

    final locale = Localizations.maybeLocaleOf(context);

    final bodySpan = TextSpan(text: text, style: style);

    if (!layout.metadataIsInline) {

      return Column(

        mainAxisSize: MainAxisSize.min,

        crossAxisAlignment: CrossAxisAlignment.stretch,

        children: [

          Text.rich(

            bodySpan,

            textDirection: direction,

            textScaler: scaler,

            locale: locale,

            textAlign: TextAlign.start,

          ),

          const SizedBox(height: 3),

          Align(

            alignment: Alignment.centerRight,

            child: _rightAlignedMetadata(),

          ),

        ],

      );

    }

    if (layout.bodyIsSingleLine) {

      return Row(

        crossAxisAlignment: CrossAxisAlignment.end,

        children: [

          Expanded(

            child: Text.rich(

              bodySpan,

              maxLines: 1,

              softWrap: false,

              overflow: TextOverflow.clip,

              textDirection: direction,

              textScaler: scaler,

              locale: locale,

              textAlign: TextAlign.start,

            ),

          ),

          SizedBox(width: layout.metadataGap),

          _rightAlignedMetadata(),

        ],

      );

    }

    return Stack(

      fit: StackFit.passthrough,

      clipBehavior: Clip.none,

      children: [

        Text.rich(

          TextSpan(

            style: style,

            children: [

              TextSpan(text: text),

              WidgetSpan(

                alignment: PlaceholderAlignment.bottom,

                child: SizedBox(width: layout.metadataReservation, height: 17),

              ),

            ],

          ),

          textDirection: direction,

          textScaler: scaler,

          locale: locale,

          textAlign: TextAlign.start,

        ),

        Positioned(right: 0, bottom: 0, child: _rightAlignedMetadata()),

      ],

    );

  }

  Widget _rightAlignedMetadata() {

    return Transform.translate(

      offset: Offset(message.isMine ? 5 : 0, 0),

      child: MessageMetadata(message: message),

    );

  }

}

class _MediaTextLayout {

  const _MediaTextLayout({

    required this.width,

    required this.metadataIsInline,

    required this.metadataReservation,

    required this.metadataGap,

    required this.bodyIsSingleLine,

  });

  final double width;

  final bool metadataIsInline;

  final double metadataReservation;

  final double metadataGap;

  final bool bodyIsSingleLine;

}

class _MediaTextLayoutResolver {

  static const double _tolerance = .05;

  static _MediaTextLayout resolve({

    required BuildContext context,

    required String text,

    required TextStyle style,

    required double maximumWidth,

    required double metadataWidth,

    required double preferredMetadataGap,

    required double minimumMetadataGap,

  }) {

    final direction = Directionality.of(context);

    final scaler = MediaQuery.textScalerOf(context);

    final locale = Localizations.maybeLocaleOf(context);

    if (maximumWidth <= 0) {

      return const _MediaTextLayout(

        width: 0,

        metadataIsInline: false,

        metadataReservation: 0,

        metadataGap: 0,

        bodyIsSingleLine: false,

      );

    }

    final painter = TextPainter(

      text: TextSpan(text: text, style: style),

      textDirection: direction,

      textScaler: scaler,

      locale: locale,

      textWidthBasis: TextWidthBasis.longestLine,

    )..layout(maxWidth: maximumWidth);

    final lines = painter.computeLineMetrics();

    final widestLine = lines.fold<double>(

      0,

      (widest, line) => math.max(widest, line.width),

    );

    final finalLine = lines.isEmpty ? 0.0 : lines.last.width;

    final lineCount = lines.length;

    final hasForcedTrailingLine = text.endsWith('\\\n');

    var inline = false;

    var gap = preferredMetadataGap;

    if (!hasForcedTrailingLine && lines.isNotEmpty) {

      inline = finalLine + gap + metadataWidth <= maximumWidth + _tolerance;

      if (!inline &&

          finalLine + minimumMetadataGap + metadataWidth <=

              maximumWidth + _tolerance) {

        gap = minimumMetadataGap;

        inline = true;

      }

    }

    final inlineWidthSlack = lineCount == 1 ? 2.0 : 0.0;

    var desiredWidth = inline

        ? math.max(

            widestLine,

            finalLine + gap + metadataWidth + inlineWidthSlack,

          )

        : math.max(widestLine, metadataWidth);

    desiredWidth = desiredWidth.clamp(0.0, maximumWidth).toDouble();

    painter.layout(maxWidth: desiredWidth);

    final narrowedLines = painter.computeLineMetrics();

    final narrowedFinal = narrowedLines.isEmpty

        ? 0.0

        : narrowedLines.last.width;

    final preservesLayout = narrowedLines.length == lineCount;

    final inlineStillFits =

        !inline ||

        narrowedFinal + gap + metadataWidth <= desiredWidth + _tolerance;

    if (!preservesLayout || !inlineStillFits) {

      desiredWidth = maximumWidth;

    }

    painter.dispose();

    return _MediaTextLayout(

      width: desiredWidth,

      metadataIsInline: inline,

      metadataReservation: inline ? gap + metadataWidth : 0,

      metadataGap: inline ? gap : 0,

      bodyIsSingleLine: lineCount == 1,

    );

  }

}

// =============================================================================

// MEDIA TIME BADGE

// =============================================================================

class _VideoMediaTimeBadge extends StatelessWidget {

  const _VideoMediaTimeBadge({

    required this.child,

    this.compensateStatusOffset = false,

  });

  final Widget child;

  /// The shared delivery checkmark paints slightly lower than its layout box.

/// This optical correction changes only the child's position; it does not

/// change the metadata size or the overlay's geometry.

  final bool compensateStatusOffset;

  static const double _height = 22;

  static const double _horizontalPadding = 6;

  @override

  Widget build(BuildContext context) {

    return SizedBox(

      height: _height,

      child: DecoratedBox(

        decoration: BoxDecoration(

          // Keep the original media-overlay look: simple translucent black,

          // no outline and no border.

          color: Colors.black.withValues(alpha: 0.44),

          borderRadius: BorderRadius.circular(20),

        ),

        child: Padding(

          padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),

          child: Center(

            child: Transform.translate(

              offset: Offset(0, compensateStatusOffset ? -1 : 0),

              child: child,

            ),

          ),

        ),

      ),

    );

  }

}

// =============================================================================

// TIME + TICKS

class _VideoMediaFrame extends StatelessWidget {

  const _VideoMediaFrame({

    required this.isMine,

    required this.showTail,

    required this.radius,

    required this.outlineColor,

    required this.outlineWidth,

    required this.child,

  });

  final bool isMine;

  final bool showTail;

  final double radius;

  final Color outlineColor;

  final double outlineWidth;

  final Widget child;

  @override

  Widget build(BuildContext context) {

    return CustomPaint(

      foregroundPainter: _VideoBubbleOutlinePainter(

        isMine: isMine,

        showTail: showTail,

        radius: radius,

        color: outlineColor,

        strokeWidth: outlineWidth,

      ),

      child: ClipPath(

        clipBehavior: Clip.antiAlias,

        clipper: _VideoBubbleClipper(

          isMine: isMine,

          showTail: showTail,

          radius: radius,

        ),

        child: child,

      ),

    );

  }

}

// =============================================================================

// CLIPPER

// =============================================================================

class _VideoBubbleClipper extends CustomClipper<Path> {

  const _VideoBubbleClipper({

    required this.isMine,

    required this.showTail,

    required this.radius,

  });

  final bool isMine;

  final bool showTail;

  final double radius;

  @override

  Path getClip(Size size) {

    return _VideoBubblePath.create(

      size: size,

      tailOnRight: isMine,

      showTail: showTail,

      strokeInset: 0,

      radius: radius,

    );

  }

  @override

  bool shouldReclip(covariant _VideoBubbleClipper oldClipper) {

    return oldClipper.isMine != isMine ||

        oldClipper.showTail != showTail ||

        oldClipper.radius != radius;

  }

}

// =============================================================================

// OUTLINE

// =============================================================================

class _VideoBubbleOutlinePainter extends CustomPainter {

  const _VideoBubbleOutlinePainter({

    required this.isMine,

    required this.showTail,

    required this.radius,

    required this.color,

    required this.strokeWidth,

  });

  final bool isMine;

  final bool showTail;

  final double radius;

  final Color color;

  final double strokeWidth;

  @override

  void paint(Canvas canvas, Size size) {

    if (size.isEmpty || strokeWidth <= 0) {

      return;

    }

    final path = _VideoBubblePath.create(

      size: size,

      tailOnRight: isMine,

      showTail: showTail,

      strokeInset: strokeWidth / 2,

      radius: radius,

    );

    canvas.drawPath(

      path,

      Paint()

        ..isAntiAlias = true

        ..style = PaintingStyle.stroke

        ..strokeWidth = strokeWidth

        ..strokeCap = StrokeCap.round

        ..strokeJoin = StrokeJoin.round

        ..color = color,

    );

  }

  @override

  bool shouldRepaint(covariant _VideoBubbleOutlinePainter oldDelegate) {

    return oldDelegate.isMine != isMine ||

        oldDelegate.showTail != showTail ||

        oldDelegate.radius != radius ||

        oldDelegate.color != color ||

        oldDelegate.strokeWidth != strokeWidth;

  }

}

// =============================================================================

// BUBBLE + TAIL PATH

// =============================================================================

class _VideoBubblePath {

  _VideoBubblePath._();

  static const double _templateDiameter = 33;

  static const double _bottomEllipseLeftInset = 10.5;

  static const double _bottomEllipseWidth = 30;

  static const double _bottomEllipseHeight = 17;

  static const double _innerEllipseWidth = 22;

  static const double _innerEllipseHeight = 20;

  static const double _bridgeWidth = 18;

  static const double _bridgeTopInset = 17;

  static const double _bridgeBottomInset = 8;

  static Path create({

    required Size size,

    required bool tailOnRight,

    required bool showTail,

    required double strokeInset,

    required double radius,

  }) {

    if (size.isEmpty) {

      return Path();

    }

    // =========================================================================

    // No tail

    // =========================================================================

    if (!showTail) {

      return _roundedBody(

        Rect.fromLTRB(

          strokeInset,

          strokeInset,

          size.width - strokeInset,

          size.height - strokeInset,

        ),

        radius,

      );

    }

    // =========================================================================

    // Build right-side tail

    // =========================================================================

    final outgoing = _createRightTailBubble(

      size: size,

      strokeInset: strokeInset,

      radius: radius,

    );

    if (tailOnRight) {

      return outgoing;

    }

    // =========================================================================

    // Mirror for incoming

    // =========================================================================

    return outgoing.transform(

      Float64List.fromList(<double>[

        -1,

        0,

        0,

        0,

        0,

        1,

        0,

        0,

        0,

        0,

        1,

        0,

        size.width,

        0,

        0,

        1,

      ]),

    );

  }

  // ===========================================================================

  // RIGHT TAIL

  // ===========================================================================

  static Path _createRightTailBubble({

    required Size size,

    required double strokeInset,

    required double radius,

  }) {

    final double availableWidth = math

        .max(0, size.width - (strokeInset * 2))

        .toDouble();

    final double availableHeight = math

        .max(0, size.height - (strokeInset * 2))

        .toDouble();

    if (availableWidth <= 0 || availableHeight <= 0) {

      return Path();

    }

    final double tailScale = math

        .min(1, availableHeight / _templateDiameter)

        .toDouble();

    final double reservedTail = math

        .min(MessageBubbleSurface.tailExtent, math.max(0, availableWidth - 1))

        .toDouble();

    final Rect bodyRect = Rect.fromLTRB(

      strokeInset,

      strokeInset,

      size.width - strokeInset - reservedTail,

      size.height - strokeInset,

    );

    if (bodyRect.width <= 0 || bodyRect.height <= 0) {

      return Path();

    }

    final Path body = _roundedBody(bodyRect, radius);

    final double bodyRight = bodyRect.right;

    final double bottom = bodyRect.bottom;

    // =========================================================================

    // Bottom lobe

    // =========================================================================

    final Rect bottomEllipse = Rect.fromLTWH(

      bodyRight - (_bottomEllipseLeftInset * tailScale),

      bottom - (_bottomEllipseHeight * tailScale),

      _bottomEllipseWidth * tailScale,

      _bottomEllipseHeight * tailScale,

    );

    final Path lowerLobe = Path()

      ..moveTo(bottomEllipse.left, bottomEllipse.center.dy)

      ..quadraticBezierTo(

        bottomEllipse.left,

        bottomEllipse.bottom,

        bottomEllipse.center.dx,

        bottomEllipse.bottom,

      )

      ..quadraticBezierTo(

        bottomEllipse.right,

        bottomEllipse.bottom,

        bottomEllipse.right,

        bottomEllipse.center.dy,

      )

      ..close();

    // =========================================================================

    // Bridge

    // =========================================================================

    final Path bridge = Path()

      ..addRect(

        Rect.fromLTRB(

          bodyRight - (_bridgeWidth * tailScale),

          bottom - (_bridgeTopInset * tailScale),

          bodyRight,

          bottom - (_bridgeBottomInset * tailScale),

        ),

      );

    Path combined = Path.combine(PathOperation.union, body, lowerLobe);

    combined = Path.combine(PathOperation.union, combined, bridge);

    // =========================================================================

    // Inner notch

    // =========================================================================

    final Path innerCutout = Path()

      ..addOval(

        Rect.fromLTWH(

          bodyRight,

          bottom - (19 * tailScale),

          _innerEllipseWidth * tailScale,

          _innerEllipseHeight * tailScale,

        ),

      );

    return Path.combine(PathOperation.difference, combined, innerCutout);

  }

  // ===========================================================================

  // ROUNDED BODY

  // ===========================================================================

  static Path _roundedBody(Rect rect, double requestedRadius) {

    if (rect.width <= 0 || rect.height <= 0) {

      return Path();

    }

    final double resolvedRadius = math

        .min(requestedRadius, math.min(rect.width / 2, rect.height / 2))

        .toDouble();

    return Path()..addRRect(

      RRect.fromRectAndRadius(rect, Radius.circular(resolvedRadius)),

    );

  }

}
