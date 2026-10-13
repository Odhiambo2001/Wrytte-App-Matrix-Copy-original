import 'dart:async';

import 'dart:math' as math;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:video_player/video_player.dart';

import 'package:visibility_detector/visibility_detector.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';

import 'package:wrytte/ui/chat/view_models/chat_video_playback_view_model.dart';

import 'package:wrytte/ui/chat/widgets/message_actions/message_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_swipe_action_target.dart';

import 'package:wrytte/ui/chat/widgets/message_metadata.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

import 'package:wrytte/ui/media/video/wrytte_video_session.dart';

import 'package:wrytte/ui/media/video/wrytte_video_surface.dart';

// =============================================================================

// Shared metadata visual values

//

// These deliberately match the shared MessageMetadata used by all bubbles.

// =============================================================================

const Color _roundVideoMetadataColor = Color(0xD9FFFFFF);

const double _roundVideoMetadataFontSize = 11.0;

// Duration text is 11px and both metadata pills reserve the SAME

// 17px internal content height.

//

// This is important:

//

// timestamp/status now use their full shared 17px metadata height.

// The overlay itself adds only the small optical room used by Image/Video.

const double _roundVideoMetadataContentHeight = 17.0;

// =============================================================================

// ROUND VIDEO MESSAGE

// =============================================================================

class RoundVideoMessageBubble extends StatefulWidget {

  const RoundVideoMessageBubble({

    super.key,

    required this.message,

    required this.playback,

    this.actionConfig,

    this.onBeforePlay,

  });

  final ChatMessagePresentation message;

  final ChatVideoPlaybackViewModel playback;

  final MessageActionConfig? actionConfig;

  final Future<void> Function()? onBeforePlay;

  @override

  State<RoundVideoMessageBubble> createState() =>

      _RoundVideoMessageBubbleState();

}

// =============================================================================

// STATE

// =============================================================================

class _RoundVideoMessageBubbleState extends State<RoundVideoMessageBubble> {

  // ===========================================================================

  // COMPACT SIZE

  //

  // EXACT old sizing before expansion:

  //

  // min(screenWidth * .58, 244)

  // clamp(196, 244)

  // ===========================================================================

  static const double _compactWidthFactor = 0.58;

  static const double _minimumCompactDiameter = 196.0;

  static const double _maximumCompactDiameter = 244.0;

  // ===========================================================================

  // EXPANDED SIZE

  //

  // Old design allowed roughly 456px.

  //

  // We still respect:

  // - actual list width

  // - phone width

  // - 456px maximum

  //

  // No manual scroll-position math.

  // ===========================================================================

  static const double _expandedWidthFactor = 0.96;

  static const double _maximumExpandedDiameter = 456.0;

  // ===========================================================================

  // Animation

  // ===========================================================================

  static const Duration _expansionDuration = Duration(milliseconds: 360);

  static const Curve _expansionCurve = Curves.easeOutCubic;

  // ===========================================================================

  // Circle

  // ===========================================================================

  static const double _outlineWidth = 1.8;

  // ===========================================================================

  // Metadata

  // ===========================================================================

  static const double _metadataTopGap = 6.0;

  static const double _metadataHorizontalInset = 7.0;

  // The timestamp pill keeps 6px equal internal padding. Shift only the

  // outgoing timestamp pill 6px right so the metadata itself lands at 7px.

  static const double _outgoingTimestampBadgeShift = 6.0;

  // ===========================================================================

  // Mute button

  // ===========================================================================

  static const double _compactMuteDiameter = 36.0;

  static const double _expandedMuteDiameter = 40.0;

  static const double _compactMuteIcon = 15.0;

  static const double _expandedMuteIcon = 17.0;

  static const double _muteBottomFactor = 0.055;

  // ===========================================================================

  // Play button

  // ===========================================================================

  static const double _compactPlayDiameter = 52.0;

  static const double _expandedPlayDiameter = 76.0;

  static const double _compactPlayIcon = 34.0;

  static const double _expandedPlayIcon = 54.0;

  // ===========================================================================

  // Progress

  // ===========================================================================

  static const double _progressInset = 5.0;

  // ===========================================================================

  // State

  // ===========================================================================

  bool _expanded = false;

  int _expansionGeneration = 0;

  double _lastVisibleFraction = 0.0;

  DateTime? _expansionStartedAt;

  bool _expandedCompletionScheduled = false;

  final GlobalKey _bubbleKey = GlobalKey();

  // ===========================================================================

  // Convenience

  // ===========================================================================

  ChatMessagePresentation get message => widget.message;

  bool get _isMine => message.isMine;

  String get _source => message.assetPath?.trim() ?? '';

  VideoPlayerController? get _controller {

    return widget.playback.controllerFor(message.id);

  }

  WrytteVideoPhase get _phase {

    return widget.playback.phaseFor(message.id);

  }

  bool get _isPlaying => _phase == WrytteVideoPhase.playing;

  bool get _isInitializing => _phase == WrytteVideoPhase.initializing;

  bool get _hasFailed => _phase == WrytteVideoPhase.failed;

  Color get _outlineColor =>

      _isMine ? WrytteColors.primary : const Color(0xFF3A3F48);

  // ===========================================================================

  // Dispose

  // ===========================================================================

  @override

  void dispose() {

    widget.playback.unregisterAutoplayMessage(message.id);

    super.dispose();

  }

  // ===========================================================================

  // Circle tap

  //

  // IMPORTANT:

  //

  // collapsed + tap:

  //     EXPAND

  //     keep playing

  //

  // expanded + tap: toggle playback. Tapping outside collapses it.

  // ===========================================================================

  void _handleCircleTap() {

    if (_source.isEmpty) {

      return;

    }

    final generation = ++_expansionGeneration;

    if (!_expanded) {

      _expansionStartedAt = DateTime.now();

      setState(() {

        _expanded = true;

      });

      // -----------------------------------------------------------------------

      // The shared player keeps the compact playhead and switches off looping

      // while enlarged, so expansion never flashes or restarts the video.

      unawaited(

        widget.playback.expandAutoplayMessage(

          messageId: message.id,

          source: _source,

          beforePlay: widget.onBeforePlay,

        ),

      );

      // -----------------------------------------------------------------------

      // Let the bubble begin growing, then smoothly center it in the chat.

      // -----------------------------------------------------------------------

      unawaited(_bringExpandedBubbleIntoView(generation));

      // -----------------------------------------------------------------------

      // During the expansion animation the circle is changing size.

      //

      // We temporarily protect it from becoming an autoplay "loser" just

      // because its visibleFraction changes for a few frames.

      // -----------------------------------------------------------------------

      unawaited(_releaseExpansionVisibilityGuard(generation));

      return;

    }

    unawaited(widget.playback.toggleExpandedAutoplayPlayback(message.id));

  }

  void _collapseExpanded() {

    if (!_expanded) return;

    ++_expansionGeneration;

    _expansionStartedAt = null;

    _expandedCompletionScheduled = false;

    setState(() => _expanded = false);

    unawaited(widget.playback.collapseExpandedAutoplayMessage(message.id));

  }

  void _scheduleExpandedCompletion() {

    if (!_expanded ||

        _phase != WrytteVideoPhase.completed ||

        _expandedCompletionScheduled) {

      return;

    }

    _expandedCompletionScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {

      if (!mounted || !_expanded) return;

      await widget.playback.completeExpandedAutoplayMessage(message.id);

      if (!mounted) return;

      _expansionStartedAt = null;

      setState(() {

        _expanded = false;

        _expandedCompletionScheduled = false;

      });

    });

  }

  // ===========================================================================

  // Smoothly keep enlarged bubble visible

  // ===========================================================================

  Future<void> _bringExpandedBubbleIntoView(int generation) async {

    // Wait until most of the expansion has already happened.

    //

    // This makes ensureVisible work with nearly-final dimensions and avoids the

    // old jump-to-position behaviour.

    await Future<void>.delayed(const Duration(milliseconds: 150));

    if (!mounted || !_expanded || generation != _expansionGeneration) {

      return;

    }

    final targetContext = _bubbleKey.currentContext;

    if (targetContext == null || !targetContext.mounted) {

      return;

    }

    await Scrollable.ensureVisible(

      targetContext,

      duration: const Duration(milliseconds: 300),

      curve: Curves.easeOutCubic,

      // Slightly above exact screen center leaves comfortable space for

      // metadata and the composer below.

      alignment: 0.46,

      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,

    );

  }

  // ===========================================================================

  // Expansion visibility protection

  // ===========================================================================

  Future<void> _releaseExpansionVisibilityGuard(int generation) async {

    await Future<void>.delayed(const Duration(milliseconds: 430));

    if (!mounted || generation != _expansionGeneration) {

      return;

    }

    _expansionStartedAt = null;

    if (_source.isEmpty) {

      return;

    }

    // Send the real final visible fraction after expansion finishes.

    widget.playback.setAutoplayVisibility(

      messageId: message.id,

      source: _source,

      visibleFraction: _lastVisibleFraction,

      beforePlay: widget.onBeforePlay,

    );

  }

  // ===========================================================================

  // Visibility

  // ===========================================================================

  void _handleVisibilityChanged(VisibilityInfo info) {

    if (_source.isEmpty) {

      return;

    }

    final actualFraction = info.visibleFraction.clamp(0.0, 1.0).toDouble();

    _lastVisibleFraction = actualFraction;

    var reportedFraction = actualFraction;

    // -------------------------------------------------------------------------

    // While expanding, don't allow temporary geometry changes to pause/switch

    // the video we just opened.

    // -------------------------------------------------------------------------

    final started = _expansionStartedAt;

    if (_expanded &&

        started != null &&

        DateTime.now().difference(started).inMilliseconds < 430) {

      reportedFraction = math.max(actualFraction, 0.80);

    }

    widget.playback.setAutoplayVisibility(

      messageId: message.id,

      source: _source,

      visibleFraction: reportedFraction,

      beforePlay: widget.onBeforePlay,

    );

  }

  // ===========================================================================

  // Mute

  // ===========================================================================

  Future<void> _toggleMute() {

    return widget.playback.toggleMute(message.id);

  }

  // ===========================================================================

  // Build

  // ===========================================================================

  @override

  Widget build(BuildContext context) {

    return VisibilityDetector(

      key: ValueKey<String>('round-video-visibility-${message.id}'),

      onVisibilityChanged: _handleVisibilityChanged,

      child: AnimatedBuilder(

        animation: widget.playback,

        builder: (context, child) {

          return _buildAnimatedBubble(context);

        },

      ),

    );

  }

  // ===========================================================================

  // Animated bubble

  // ===========================================================================

  Widget _buildAnimatedBubble(BuildContext context) {

    _scheduleExpandedCompletion();

    return LayoutBuilder(

      builder: (context, constraints) {

        final screenWidth = MediaQuery.sizeOf(context).width;

        // =====================================================================

        // EXACT OLD COMPACT SIZE

        // =====================================================================

        final compactDiameter = math

            .min(screenWidth * _compactWidthFactor, _maximumCompactDiameter)

            .clamp(_minimumCompactDiameter, _maximumCompactDiameter)

            .toDouble();

        // =====================================================================

        // Expanded size

        // =====================================================================

        final availableWidth = constraints.hasBoundedWidth

            ? constraints.maxWidth

            : screenWidth - 24;

        final expandedDiameter = math

            .min(

              math.min(availableWidth, screenWidth * _expandedWidthFactor),

              _maximumExpandedDiameter,

            )

            .clamp(compactDiameter, _maximumExpandedDiameter)

            .toDouble();

        final targetDiameter = _expanded ? expandedDiameter : compactDiameter;

        final compactAlignment = _isMine

            ? AlignmentDirectional.centerEnd

            : AlignmentDirectional.centerStart;

        // =====================================================================

        // Animated alignment

        //

        // Compact:

        // outgoing -> right

        // incoming -> left

        //

        // Expanded:

        // center

        // =====================================================================

        return AnimatedAlign(

          duration: _expansionDuration,

          curve: _expansionCurve,

          alignment: _expanded ? AlignmentDirectional.center : compactAlignment,

          child: TweenAnimationBuilder<double>(

            tween: Tween<double>(end: targetDiameter),

            duration: _expansionDuration,

            curve: _expansionCurve,

            builder: (context, diameter, child) {

              // ===============================================================

              // Expansion progress

              //

              // Used only for internal control sizing.

              //

              // Metadata never scales.

              // ===============================================================

              final travel = expandedDiameter - compactDiameter;

              final expansion = travel <= 0

                  ? 0.0

                  : ((diameter - compactDiameter) / travel)

                        .clamp(0.0, 1.0)

                        .toDouble();

              final content = SizedBox(

                key: _bubbleKey,

                width: diameter,

                child: Column(

                  mainAxisSize: MainAxisSize.min,

                  crossAxisAlignment: CrossAxisAlignment.stretch,

                  children: [

                    // =========================================================

                    // Circular media

                    // =========================================================

                    Semantics(

                      button: true,

                      label: _expanded

                          ? (_isPlaying

                                ? 'Pause video message'

                                : 'Play video message')

                          : 'Expand video message',

                      child: GestureDetector(

                        behavior: HitTestBehavior.opaque,

                        onTap: _handleCircleTap,

                        child: SizedBox.square(

                          dimension: diameter,

                          child: _buildVideoCircle(

                            diameter: diameter,

                            expansion: expansion,

                          ),

                        ),

                      ),

                    ),

                    // =========================================================

                    // Circle -> metadata

                    // =========================================================

                    const SizedBox(height: _metadataTopGap),

                    // =========================================================

                    // Duration / timestamp metadata

                    //

                    // These DO NOT scale when circle expands.

                    // =========================================================

                    Padding(

                      padding: const EdgeInsets.symmetric(

                        horizontal: _metadataHorizontalInset,

                      ),

                      child: Row(

                        crossAxisAlignment: CrossAxisAlignment.center,

                        children: [

                          // ===================================================

                          // Duration overlay

                          // ===================================================

                          _RoundVideoMetadataOverlay(

                            child: _RoundVideoDuration(

                              controller: _controller,

                              fallbackDurationSeconds:

                                  message.videoDurationSeconds,

                            ),

                          ),

                          const Spacer(),

                          // ===================================================

                          // Timestamp + delivery state

                          //

                          // Canonical shared metadata. The badge owns a

                          // fixed 22px visual height, while MessageMetadata

                          // keeps its real 11px timestamp / 17px status sizes.

                          // ===================================================

                          Transform.translate(

                            offset: Offset(

                              message.isMine ? _outgoingTimestampBadgeShift : 0,

                              0,

                            ),

                            child: _RoundVideoMetadataOverlay(

                              compensateStatusOffset: message.isMine,

                              child: MessageMetadata(

                                message: message,

                                onMedia: true,

                              ),

                            ),

                          ),

                        ],

                      ),

                    ),

                  ],

                ),

              );

              final config = widget.actionConfig;

              final actionTarget = config == null || !config.hasContent

                  ? content

                  : MessageActionTarget(
                  config: config,
                  child: MessageSwipeActionTarget(
                    config: config,
                    child: content,
                  ),
                );

              return TapRegion(

                onTapOutside: (_) {

                  if (_expanded) _collapseExpanded();

                },

                child: actionTarget,

              );

            },

          ),

        );

      },

    );

  }

  // ===========================================================================

  // Video circle

  // ===========================================================================

  Widget _buildVideoCircle({

    required double diameter,

    required double expansion,

  }) {

    final controller = _controller;

    final initialized = controller != null && controller.value.isInitialized;

    final playDiameter =

        ui.lerpDouble(_compactPlayDiameter, _expandedPlayDiameter, expansion) ??

        _compactPlayDiameter;

    final playIconSize =

        ui.lerpDouble(_compactPlayIcon, _expandedPlayIcon, expansion) ??

        _compactPlayIcon;

    final muteDiameter =

        ui.lerpDouble(_compactMuteDiameter, _expandedMuteDiameter, expansion) ??

        _compactMuteDiameter;

    final muteIconSize =

        ui.lerpDouble(_compactMuteIcon, _expandedMuteIcon, expansion) ??

        _compactMuteIcon;

    return DecoratedBox(

      decoration: BoxDecoration(

        shape: BoxShape.circle,

        border: Border.all(color: _outlineColor, width: _outlineWidth),

      ),

      child: Padding(

        padding: const EdgeInsets.all(_outlineWidth),

        child: ClipOval(

          child: ColoredBox(

            color: Colors.black,

            child: Stack(

              fit: StackFit.expand,

              children: [

                // =============================================================

                // Static poster

                // =============================================================

                _RoundVideoPoster(message: message),

                // =============================================================

                // Live player

                // =============================================================

                if (initialized) _RoundVideoLiveLayer(controller: controller),

                // =============================================================

                // Subtle dark vignette

                // =============================================================

                IgnorePointer(

                  child: DecoratedBox(

                    decoration: BoxDecoration(

                      gradient: RadialGradient(

                        center: Alignment.center,

                        radius: 0.84,

                        colors: [

                          Colors.transparent,

                          Colors.black.withValues(alpha: 0.12),

                        ],

                      ),

                    ),

                  ),

                ),

                // =============================================================

                // Circular progress

                // =============================================================

                if (initialized)

                  Positioned.fill(

                    child: IgnorePointer(

                      child: Padding(

                        padding: const EdgeInsets.all(_progressInset),

                        child: ValueListenableBuilder<VideoPlayerValue>(

                          valueListenable: controller,

                          builder: (context, value, child) {

                            return CustomPaint(

                              painter: _RoundVideoProgressPainter(

                                progress: _progress(value),

                                paused: !_isPlaying,

                              ),

                            );

                          },

                        ),

                      ),

                    ),

                  ),

                // =============================================================

                // Initial load

                // =============================================================

                if (_isInitializing && !initialized)

                  Center(

                    child: SizedBox.square(

                      dimension: 22,

                      child: CircularProgressIndicator(

                        strokeWidth: 2.0,

                        color: const Color(0xFFE7ECEF).withValues(alpha: 0.86),

                      ),

                    ),

                  ),

                // =============================================================

                // Failure

                // =============================================================

                if (_hasFailed)

                  Center(

                    child: Container(

                      width: 48,

                      height: 48,

                      alignment: Alignment.center,

                      decoration: BoxDecoration(

                        color: const Color(0xFF111318).withValues(alpha: 0.84),

                        shape: BoxShape.circle,

                      ),

                      child: const Icon(

                        Icons.refresh_rounded,

                        color: Colors.white,

                        size: 24,

                      ),

                    ),

                  ),

                // =============================================================

                // Play visual

                //

                // The circle tap EXPANDS/COLLAPSES.

                // It does not pause playback.

                // =============================================================

                if (initialized &&

                    !_isPlaying &&

                    !_isInitializing &&

                    !_hasFailed)

                  Center(

                    child: Container(

                      width: playDiameter,

                      height: playDiameter,

                      alignment: Alignment.center,

                      decoration: BoxDecoration(

                        color: const Color(0xFF111318).withValues(alpha: 0.76),

                        shape: BoxShape.circle,

                      ),

                      child: WrytteSvgIcon(

                        asset: 'assets/svg/Play icon .svg',

                        size: playIconSize,

                        color: Colors.white,

                      ),

                    ),

                  ),

                // =============================================================

                // Mute

                // =============================================================

                if (initialized)

                  Positioned(

                    left: 0,

                    right: 0,

                    bottom: diameter * _muteBottomFactor,

                    child: Center(

                      child: Semantics(

                        button: true,

                        label: widget.playback.muted

                            ? 'Unmute video message'

                            : 'Mute video message',

                        child: GestureDetector(

                          behavior: HitTestBehavior.opaque,

                          onTap: () {

                            unawaited(_toggleMute());

                          },

                          child: Container(

                            width: muteDiameter,

                            height: muteDiameter,

                            alignment: Alignment.center,

                            decoration: BoxDecoration(

                              color: const Color(

                                0xFF05070A,

                              ).withValues(alpha: 0.46),

                              shape: BoxShape.circle,

                            ),

                            child: WrytteSvgIcon(

                              asset: widget.playback.muted

                                  ? 'assets/svg/Nosound icon.svg'

                                  : 'assets/svg/Sound icon.svg',

                              size: muteIconSize,

                              color: Colors.white,

                            ),

                          ),

                        ),

                      ),

                    ),

                  ),

              ],

            ),

          ),

        ),

      ),

    );

  }

  // ===========================================================================

  // Playback progress

  // ===========================================================================

  double _progress(VideoPlayerValue value) {

    final durationMs = value.duration.inMilliseconds;

    if (durationMs <= 0) {

      return 0;

    }

    return (value.position.inMilliseconds / durationMs)

        .clamp(0.0, 1.0)

        .toDouble();

  }

}

// =============================================================================

// POSTER

// =============================================================================

class _RoundVideoPoster extends StatelessWidget {

  const _RoundVideoPoster({required this.message});

  final ChatMessagePresentation message;

  @override

  Widget build(BuildContext context) {

    final bytes = message.videoThumbnailBytes;

    final thumbnailUrl = message.videoThumbnailUrl?.trim();

    final Widget image;

    // =========================================================================

    // Memory thumbnail

    // =========================================================================

    if (bytes != null && bytes.isNotEmpty) {

      image = Image.memory(

        bytes,

        fit: BoxFit.cover,

        alignment: Alignment.center,

        gaplessPlayback: true,

        filterQuality: FilterQuality.medium,

      );

    }

    // =========================================================================

    // Network thumbnail

    // =========================================================================

    else if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {

      image = Image.network(

        thumbnailUrl,

        fit: BoxFit.cover,

        alignment: Alignment.center,

        gaplessPlayback: true,

        filterQuality: FilterQuality.medium,

        loadingBuilder: (context, child, loading) {

          if (loading == null) {

            return child;

          }

          return const _RoundVideoFallback();

        },

        errorBuilder: (context, error, stackTrace) {

          return const _RoundVideoFallback();

        },

      );

    }

    // =========================================================================

    // Fallback

    // =========================================================================

    else {

      image = const _RoundVideoFallback();

    }

    // Old circular video used a deliberate overscale.

    return Transform.scale(scale: 1.26, child: SizedBox.expand(child: image));

  }

}

// =============================================================================

// FALLBACK

// =============================================================================

class _RoundVideoFallback extends StatelessWidget {

  const _RoundVideoFallback();

  @override

  Widget build(BuildContext context) {

    return const DecoratedBox(

      decoration: BoxDecoration(

        gradient: RadialGradient(

          center: Alignment.center,

          radius: 0.85,

          colors: [Color(0xFF20252C), Color(0xFF08090B)],

        ),

      ),

    );

  }

}

// =============================================================================

// LIVE VIDEO

// =============================================================================

class _RoundVideoLiveLayer extends StatelessWidget {

  const _RoundVideoLiveLayer({required this.controller});

  final VideoPlayerController controller;

  @override

  Widget build(BuildContext context) {

    return ValueListenableBuilder<VideoPlayerValue>(

      valueListenable: controller,

      builder: (context, value, child) {

        final firstFrameReady =

            value.position >= const Duration(milliseconds: 80) ||

            (value.isPlaying && !value.isBuffering);

        return AnimatedOpacity(

          opacity: firstFrameReady ? 1 : 0,

          duration: const Duration(milliseconds: 140),

          curve: Curves.easeOut,

          child: Transform.scale(

            scale: 1.26,

            child: WrytteVideoSurface(

              controller: controller,

              fit: BoxFit.cover,

            ),

          ),

        );

      },

    );

  }

}

// =============================================================================

// MEDIA METADATA OVERLAY

//

// SAME STYLE AS IMAGE MEDIA METADATA.

//

// The overlay height is controlled by:

//

// 13px child layout

// + 3px top

// + 3px bottom

//

// = 19px

//

// The checkmark can visually be 17px but still reserve only a 13px layout box.

// =============================================================================

class _RoundVideoMetadataOverlay extends StatelessWidget {

  const _RoundVideoMetadataOverlay({

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

// DURATION

//

// Same:

// - color

// - font size

// - layout height

//

// as timestamp.

// =============================================================================

class _RoundVideoDuration extends StatelessWidget {

  const _RoundVideoDuration({

    required this.controller,

    required this.fallbackDurationSeconds,

  });

  final VideoPlayerController? controller;

  final int? fallbackDurationSeconds;

  static const TextStyle _style = TextStyle(

    fontFamily: WrytteTypography.primaryFontFamily,

    color: _roundVideoMetadataColor,

    fontSize: _roundVideoMetadataFontSize,

    fontWeight: FontWeight.w400,

    height: 1,

    fontFeatures: [ui.FontFeature.tabularFigures()],

  );

  String _format(int totalSeconds) {

    final safe = math.max(0, totalSeconds);

    final hours = safe ~/ 3600;

    final minutes = (safe % 3600) ~/ 60;

    final seconds = safe % 60;

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

    final player = controller;

    if (player == null) {

      return _content(fallbackDurationSeconds ?? 0);

    }

    return ValueListenableBuilder<VideoPlayerValue>(

      valueListenable: player,

      builder: (context, value, child) {

        final duration = value.duration > Duration.zero

            ? value.duration.inSeconds

            : fallbackDurationSeconds ?? 0;

        return _content(duration);

      },

    );

  }

  Widget _content(int seconds) {

    return SizedBox(

      height: _roundVideoMetadataContentHeight,

      child: Align(

        alignment: Alignment.center,

        child: Text(_format(seconds), style: _style),

      ),

    );

  }

}

// =============================================================================

// TIMESTAMP + CHECKMARK

//

// This intentionally mirrors the image/video media metadata behaviour.

//

// The checkmark is visually 17px.

//

// BUT:

//

// its layout reservation stays 13px.

//

// Therefore the checkmark does NOT increase the black overlay's height.

class _RoundVideoProgressPainter extends CustomPainter {

  const _RoundVideoProgressPainter({

    required this.progress,

    required this.paused,

  });

  final double progress;

  final bool paused;

  @override

  void paint(Canvas canvas, Size size) {

    final radius = (math.min(size.width, size.height) / 2) - 2.5;

    if (radius <= 0) {

      return;

    }

    final center = size.center(Offset.zero);

    final rect = Rect.fromCircle(center: center, radius: radius);

    // =========================================================================

    // Paused track

    // =========================================================================

    if (paused) {

      canvas.drawCircle(

        center,

        radius,

        Paint()

          ..isAntiAlias = true

          ..style = PaintingStyle.stroke

          ..strokeWidth = 3.0

          ..strokeCap = StrokeCap.round

          ..color = Colors.white.withValues(alpha: 0.20),

      );

    }

    // =========================================================================

    // Active progress

    // =========================================================================

    final safeProgress = progress.clamp(0.0, 1.0).toDouble();

    if (safeProgress <= 0) {

      return;

    }

    const startAngle = -math.pi / 2;

    final sweep = math.pi * 2 * safeProgress;

    canvas.drawArc(

      rect,

      startAngle,

      sweep,

      false,

      Paint()

        ..isAntiAlias = true

        ..style = PaintingStyle.stroke

        ..strokeWidth = 3.2

        ..strokeCap = StrokeCap.round

        ..color = Colors.white.withValues(alpha: 0.84),

    );

  }

  @override

  bool shouldRepaint(covariant _RoundVideoProgressPainter oldDelegate) {

    return oldDelegate.progress != progress || oldDelegate.paused != paused;

  }

}
