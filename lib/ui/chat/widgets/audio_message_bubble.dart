import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';

import 'package:wrytte/ui/chat/view_models/chat_audio_playback_view_model.dart';

import 'package:wrytte/ui/chat/widgets/message_bubble_surface.dart';

import 'package:wrytte/ui/chat/widgets/message_actions/message_action_target.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_swipe_action_target.dart';

import 'package:wrytte/ui/chat/widgets/message_metadata.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class AudioMessageBubble extends StatefulWidget {

  const AudioMessageBubble({

    super.key,

    required this.message,

    required this.showTail,

    this.playback,

    this.actionConfig,

  });

  final ChatMessagePresentation message;

  final bool showTail;

  final ChatAudioPlaybackViewModel? playback;

  final MessageActionConfig? actionConfig;

  @override

  State<AudioMessageBubble> createState() => _AudioMessageBubbleState();

}

class _AudioMessageBubbleState extends State<AudioMessageBubble>

    with SingleTickerProviderStateMixin {

  // ===========================================================================

  // Geometry

  // ===========================================================================

  static const double _bubbleWidth = 280;

  static const double _contentWidth = 240;

  static const double _controlsHeight = 34;

  static const double _playSlotWidth = 36;

  static const double _playSlotHeight = 34;

  static const double _playToWaveformGap = 6;

  static const double _waveformHeight = 26;

  static const double _microphoneCanvas = 22;

  static const double _waveformToSpeedGap = 8;

  static const double _speedButtonSize = 32;

  static const double _metadataTopGap = 3;

  // MessageMetadata can be 17px tall when delivery ticks are present.

  // Keep the entire bottom row at this height for BOTH directions so the

  // visible duration/time baseline has the same vertical relationship to the

  // waveform whether a status icon exists or not.

  static const double _metadataRowHeight = 17;

  // play slot 36 + gap 6

  static const double _durationLeftInset = 42;

  static const double _metadataRightInset = 8;

  // ===========================================================================

  // Local state

  // ===========================================================================

  late final AnimationController _progress;

  bool _playing = false;

  double _speed = 1;

  // ===========================================================================

  // Playback state

  // ===========================================================================

  bool get _hasRealAudio =>

      widget.playback != null &&

      (widget.message.assetPath?.isNotEmpty ?? false);

  bool get _isPlaying {

    if (_hasRealAudio) {

      return widget.playback!.isActive(widget.message.id) &&

          widget.playback!.playing;

    }

    return _playing;

  }

  double get _visualProgress {

    final value = _hasRealAudio

        ? widget.playback!.progressFor(widget.message.id)

        : _progress.value;

    return value.clamp(0.0, 1.0).toDouble();

  }

  Animation<double> get _waveformProgress {

    if (_hasRealAudio) {

      return AlwaysStoppedAnimation<double>(_visualProgress);

    }

    return _progress;

  }

  double get _playbackSpeed {

    if (_hasRealAudio) {

      return widget.playback!.speed;

    }

    return _speed;

  }

  int get _totalSeconds {

    return math.max(

      1,

      widget.message.audioDurationSeconds ?? 1,

    );

  }

  int get _displayedSeconds {

    final progress = _visualProgress;

    if (!_isPlaying && progress <= 0) {

      return _totalSeconds;

    }

    return (_totalSeconds * progress)

        .round()

        .clamp(

          0,

          _totalSeconds,

        )

        .toInt();

  }

  bool get _showSpeedControl {

    final progress = _visualProgress;

    return _isPlaying || (progress > 0 && progress < 0.999);

  }

  // ===========================================================================

  // Lifecycle

  // ===========================================================================

  @override

  void initState() {

    super.initState();

    _progress = AnimationController(

      vsync: this,

      duration: Duration(

        seconds: _totalSeconds,

      ),

    )..addStatusListener((status) {

        if (status == AnimationStatus.completed && mounted) {

          setState(() {

            _playing = false;

          });

        }

      });

    widget.playback?.addListener(_refreshFromPlayback);

  }

  @override

  void didUpdateWidget(

    covariant AudioMessageBubble oldWidget,

  ) {

    super.didUpdateWidget(oldWidget);

    if (!identical(

      oldWidget.playback,

      widget.playback,

    )) {

      oldWidget.playback?.removeListener(

        _refreshFromPlayback,

      );

      widget.playback?.addListener(

        _refreshFromPlayback,

      );

    }

    if (oldWidget.message.audioDurationSeconds !=

        widget.message.audioDurationSeconds) {

      _progress.duration = Duration(

        seconds: _totalSeconds,

      );

    }

  }

  @override

  void dispose() {

    widget.playback?.removeListener(

      _refreshFromPlayback,

    );

    _progress.dispose();

    super.dispose();

  }

  void _refreshFromPlayback() {

    if (!mounted) return;

    setState(() {});

  }

  // ===========================================================================

  // Playback

  // ===========================================================================

  void _togglePlayback() {

    if (_hasRealAudio) {

      widget.playback!.toggle(widget.message);

      return;

    }

    if (_playing) {

      _progress.stop();

      setState(() {

        _playing = false;

      });

      return;

    }

    if (_progress.isCompleted) {

      _progress.value = 0;

    }

    final reduceMotion =

        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    if (!reduceMotion) {

      final remaining = 1 - _progress.value;

      final milliseconds =

          ((_totalSeconds * 1000) * remaining / _speed).round();

      _progress.animateTo(

        1,

        duration: Duration(

          milliseconds: math.max(

            1,

            milliseconds,

          ),

        ),

        curve: Curves.linear,

      );

    }

    setState(() {

      _playing = true;

    });

  }

  void _seek(

    double localX,

    double width,

  ) {

    if (width <= 0) return;

    const markerSize = _microphoneCanvas;

    const markerRadius = markerSize / 2;

    final usableWidth = math.max(

      1.0,

      width - markerSize,

    );

    final progress = (

      (localX - markerRadius) / usableWidth

    ).clamp(0.0, 1.0).toDouble();

    if (_hasRealAudio) {

      widget.playback!.seek(

        widget.message,

        progress,

      );

      return;

    }

    _progress.value = progress;

    setState(() {});

  }

  void _cycleSpeed() {

    if (_hasRealAudio) {

      widget.playback!.cycleSpeed();

      return;

    }

    setState(() {

      _speed = switch (_speed) {

        1 => 1.5,

        1.5 => 2,

        _ => 1,

      };

    });

    if (!_playing) return;

    _progress.stop();

    final remaining = 1 - _progress.value;

    final milliseconds =

        ((_totalSeconds * 1000) * remaining / _speed).round();

    _progress.animateTo(

      1,

      duration: Duration(

        milliseconds: math.max(

          1,

          milliseconds,

        ),

      ),

      curve: Curves.linear,

    );

  }

  // ===========================================================================

  // Play / pause

  // ===========================================================================

  Widget _buildPlayPauseButton(

    Color color,

  ) {

    return Semantics(

      button: true,

      label:

          _isPlaying ? 'Pause voice message' : 'Play voice message',

      child: GestureDetector(

        behavior: HitTestBehavior.opaque,

        onTap: _togglePlayback,

        child: SizedBox(

          width: _playSlotWidth,

          height: _playSlotHeight,

          child: Center(

            child: AnimatedSwitcher(

              duration: const Duration(

                milliseconds: 170,

              ),

              switchInCurve: Curves.easeOutBack,

              switchOutCurve: Curves.easeInCubic,

              child: _isPlaying

                  ? Icon(

                      Icons.pause_rounded,

                      key: const ValueKey(

                        'voice-message-pause',

                      ),

                      color: color,

                      size: 28,

                    )

                  : KeyedSubtree(

                      key: const ValueKey(

                        'voice-message-play',

                      ),

                      child: Transform.scale(

                        scale: 1.22,

                        child: WrytteSvgIcon(

                          asset: 'assets/svg/Play icon .svg',

                          size: 29,

                          color: color,

                        ),

                      ),

                    ),

            ),

          ),

        ),

      ),

    );

  }

  // ===========================================================================

  // Speed button

  // ===========================================================================

  Widget _buildSpeedButton({

    required Color background,

  }) {

    final speed = _playbackSpeed;

    final number = speed == speed.roundToDouble()

        ? speed.toInt().toString()

        : speed.toString();

    return Semantics(

      button: true,

      label: 'Playback speed $speed times',

      child: GestureDetector(

        behavior: HitTestBehavior.opaque,

        onTap: _cycleSpeed,

        child: Container(

          width: _speedButtonSize,

          height: _speedButtonSize,

          alignment: Alignment.center,

          decoration: BoxDecoration(

            color: background,

            shape: BoxShape.circle,

            border: Border.all(

              color: Colors.white.withValues(

                alpha: 0.07,

              ),

              width: 0.8,

            ),

          ),

          child: AnimatedSwitcher(

            duration: const Duration(

              milliseconds: 140,

            ),

            switchInCurve: Curves.easeOutCubic,

            switchOutCurve: Curves.easeInCubic,

            child: Row(

              key: ValueKey<double>(speed),

              mainAxisSize: MainAxisSize.min,

              mainAxisAlignment: MainAxisAlignment.center,

              children: [

                Text(

                  number,

                  maxLines: 1,

                  softWrap: false,

                  style: const TextStyle(

                    color: WrytteColors.textPrimary,

                    fontFamily:

                        WrytteTypography.primaryFontFamily,

                    fontSize: 12,

                    height: 1,

                    fontWeight: FontWeight.w600,

                    decoration: TextDecoration.none,

                    fontFeatures: [

                      FontFeature.tabularFigures(),

                    ],

                  ),

                ),

                Transform.translate(

                  offset: const Offset(

                    -1,

                    0,

                  ),

                  child: Transform.scale(

                    scale: 1.94,

                    child: WrytteSvgIcon(

                      asset:

                          'assets/svg/Speed X icon.svg',

                      size: 8,

                      color:

                          WrytteColors.textPrimary,

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

  Widget _buildSpeedReveal(

    Color background,

  ) {

    return TweenAnimationBuilder<double>(

      tween: Tween<double>(

        begin: 0,

        end: _showSpeedControl ? 1 : 0,

      ),

      duration: const Duration(

        milliseconds: 220,

      ),

      curve: Curves.easeOutCubic,

      builder: (

        context,

        reveal,

        child,

      ) {

        return ExcludeSemantics(

          excluding: !_showSpeedControl,

          child: IgnorePointer(

            ignoring: !_showSpeedControl,

            child: ClipRect(

              child: Align(

                alignment: Alignment.centerRight,

                widthFactor: reveal,

                child: Opacity(

                  opacity: reveal,

                  child: Transform.scale(

                    alignment: Alignment.centerRight,

                    scale:

                        0.84 + (0.16 * reveal),

                    child: child,

                  ),

                ),

              ),

            ),

          ),

        );

      },

      child: SizedBox(

        width:

            _waveformToSpeedGap +

            _speedButtonSize,

        child: Align(

          alignment: Alignment.centerRight,

          child: _buildSpeedButton(

            background: background,

          ),

        ),

      ),

    );

  }

  // ===========================================================================

  // Main UI

  // ===========================================================================

  @override

  Widget build(

    BuildContext context,

  ) {

    final message = widget.message;

    final screenWidth =

        MediaQuery.sizeOf(context).width;

    final surfaceWidth = math.min(

      _bubbleWidth,

      screenWidth * 0.80,

    );

    final primaryIconColor =

        message.isMine

        ? Colors.white.withValues(

            alpha: 0.92,

          )

        : WrytteColors.textSecondary;

    final microphoneColor =

        _visualProgress > 0

        ? const Color(

            0xFF2978FF,

          )

        : primaryIconColor;

    final inactiveWaveformColor =

        message.isMine

        ? Colors.white.withValues(

            alpha: 0.40,

          )

        : WrytteColors.textMuted;

    final speedBackground =

        message.isMine

        ? const Color(

            0xFF2568A8,

          ).withValues(

            alpha: 0.56,

          )

        : Colors.white.withValues(

            alpha: 0.16,

          );

    final metadataBandHeight =

        _metadataTopGap +

        MediaQuery.textScalerOf(

          context,

        ).scale(12);

    final bubble = Semantics(

      container: true,

      label:

          '${message.isMine ? 'Sent' : 'Received'} '

          'voice message, '

          '${_formatDuration(_totalSeconds)}',

      child: MessageBubbleSurface(

        isMine: message.isMine,

        showTail: widget.showTail,

        color: message.isMine

            ? WrytteColors.primary

            : WrytteColors.surfaceRaised,

        radius: 20,

        child: SizedBox(

          width: surfaceWidth,

          child: Padding(

            padding:

                const EdgeInsets.symmetric(

              horizontal: 20,

              vertical: 4,

            ),

            child: ConstrainedBox(

              constraints:

                  const BoxConstraints(

                maxWidth: _contentWidth,

              ),

              child: Column(

                mainAxisSize:

                    MainAxisSize.min,

                crossAxisAlignment:

                    CrossAxisAlignment.start,

                children: [

                  SizedBox(

                    height:

                        metadataBandHeight,

                  ),

                  Transform.translate(

                    offset: const Offset(

                      0,

                      -3,

                    ),

                    child: SizedBox(

                      height:

                          _controlsHeight,

                      child: Row(

                        crossAxisAlignment:

                            CrossAxisAlignment.center,

                        children: [

                          _buildPlayPauseButton(

                            primaryIconColor,

                          ),

                          const SizedBox(

                            width:

                                _playToWaveformGap,

                          ),

                          Expanded(

                            child:

                                RepaintBoundary(

                              child:

                                  _WaveformTrack(

                                progress:

                                    _waveformProgress,

                                samples:

                                    message

                                        .audioWaveform,

                                microphoneColor:

                                    microphoneColor,

                                activeColor:

                                    Colors

                                        .white

                                        .withValues(

                                  alpha:

                                      0.96,

                                ),

                                inactiveColor:

                                    inactiveWaveformColor,

                                onSeek:

                                    _seek,

                              ),

                            ),

                          ),

                          _buildSpeedReveal(

                            speedBackground,

                          ),

                        ],

                      ),

                    ),

                  ),

                  const SizedBox(

                    height:

                        _metadataTopGap,

                  ),

                  SizedBox(

                    height: _metadataRowHeight,

                    child: Row(

                      crossAxisAlignment: CrossAxisAlignment.end,

                      children: [

                        const SizedBox(

                          width:

                              _durationLeftInset,

                        ),

                        AnimatedBuilder(

                          animation:

                              _waveformProgress,

                          builder: (

                            context,

                            child,

                          ) {

                            return Text(

                              _formatDuration(

                                _displayedSeconds,

                              ),

                              style:

                                  TextStyle(

                                color: Colors

                                    .white

                                    .withValues(

                                  alpha:

                                      0.68,

                                ),

                                fontFamily:

                                    WrytteTypography

                                        .primaryFontFamily,

                                fontSize:

                                    12,

                                height: 1,

                                fontWeight:

                                    FontWeight.w400,

                                fontFeatures:

                                    const [

                                  FontFeature

                                      .tabularFigures(),

                                ],

                              ),

                            );

                          },

                        ),

                        const Spacer(),

                        const SizedBox(

                          width:

                              _metadataRightInset,

                        ),

                        // Incoming has no delivery icon, but the fixed 17px

                        // row gives it the same vertical metadata band as an

                        // outgoing message that does have 17px checkmarks.

                        MessageMetadata(

                          message: message,

                        ),

                      ],

                    ),

                  ),

                ],

              ),

            ),

          ),

        ),

      ),

    );

    final config = widget.actionConfig;

    return Align(

      alignment: message.isMine

          ? AlignmentDirectional.centerEnd

          : AlignmentDirectional.centerStart,

      child: config == null || !config.hasContent

          ? bubble

          : MessageActionTarget(
                  config: config,
                  child: MessageSwipeActionTarget(
                    config: config,
                    child: bubble,
                  ),
                ),

    );

  }

}

// =============================================================================

// Waveform track

// =============================================================================

class _WaveformTrack extends StatelessWidget {

  const _WaveformTrack({

    required this.progress,

    required this.samples,

    required this.microphoneColor,

    required this.activeColor,

    required this.inactiveColor,

    required this.onSeek,

  });

  final Animation<double> progress;

  final List<double> samples;

  final Color microphoneColor;

  final Color activeColor;

  final Color inactiveColor;

  final void Function(

    double localX,

    double width,

  ) onSeek;

  @override

  Widget build(

    BuildContext context,

  ) {

    return SizedBox(

      height:

          _AudioMessageBubbleState

              ._waveformHeight,

      child: LayoutBuilder(

        builder: (

          context,

          constraints,

        ) {

          const markerSize =

              _AudioMessageBubbleState

                  ._microphoneCanvas;

          const markerRadius =

              markerSize / 2;

          final trackWidth =

              constraints.maxWidth;

          final markerTravel = math.max(

            0.0,

            trackWidth - markerSize,

          );

          return GestureDetector(

            behavior:

                HitTestBehavior.opaque,

            onTapDown: (

              details,

            ) {

              onSeek(

                details

                    .localPosition.dx,

                trackWidth,

              );

            },

            onHorizontalDragUpdate: (

              details,

            ) {

              onSeek(

                details

                    .localPosition.dx,

                trackWidth,

              );

            },

            child: AnimatedBuilder(

              animation: progress,

              builder: (

                context,

                child,

              ) {

                final safeProgress =

                    progress.value

                        .clamp(

                          0.0,

                          1.0,

                        )

                        .toDouble();

                return Stack(

                  clipBehavior:

                      Clip.none,

                  alignment:

                      Alignment.centerLeft,

                  children: [

                    // Waveform begins at the CENTER of the mic,

                    // and ends at the CENTER position of the mic at 100%.

                    Positioned(

                      left: markerRadius,

                      right: markerRadius,

                      top: 0,

                      bottom: 0,

                      child: CustomPaint(

                        painter:

                            _WaveformPainter(

                          progress:

                              safeProgress,

                          samples:

                              samples,

                          activeColor:

                              activeColor,

                          inactiveColor:

                              inactiveColor,

                        ),

                      ),

                    ),

                    PositionedDirectional(

                      start:

                          markerTravel *

                          safeProgress,

                      top: 2,

                      width:

                          markerSize,

                      height:

                          markerSize,

                      child:

                          WrytteSvgIcon(

                        asset:

                            'assets/svg/Fill voice icon .svg',

                        size:

                            markerSize,

                        color:

                            microphoneColor,

                      ),

                    ),

                  ],

                );

              },

            ),

          );

        },

      ),

    );

  }

}

// =============================================================================

// Waveform painter

// =============================================================================

class _WaveformPainter

    extends CustomPainter {

  const _WaveformPainter({

    required this.progress,

    required this.samples,

    required this.activeColor,

    required this.inactiveColor,

  });

  static const List<double>

      _fallbackHeights = [

    6,

    10,

    14,

    20,

    9,

    16,

    24,

    12,

    18,

    7,

    22,

    15,

    10,

    25,

    17,

    8,

    20,

    13,

    23,

    11,

    16,

    7,

    19,

    25,

    12,

    18,

    9,

    21,

    14,

    8,

    17,

    23,

  ];

  final double progress;

  final List<double> samples;

  final Color activeColor;

  final Color inactiveColor;

  @override

  void paint(

    Canvas canvas,

    Size size,

  ) {

    if (size.width <= 0 ||

        size.height <= 0) {

      return;

    }

    const double preferredPitch =

        4.2;

    const double barWidth =

        2.2;

    final count = math.max(

      2,

      (size.width /

              preferredPitch)

          .floor(),

    );

    // Distribute bars cleanly from one end of the usable track to the other.

    final spacing =

        count <= 1

        ? 0.0

        : (size.width -

                barWidth) /

            (count - 1);

    final safeProgress =

        progress

            .clamp(

              0.0,

              1.0,

            )

            .toDouble();

    final activeUntil =

        size.width *

        safeProgress;

    final paint = Paint()

      ..strokeCap =

          StrokeCap.round

      ..strokeWidth =

          barWidth;

    for (

      var index = 0;

      index < count;

      index++

    ) {

      final x =

          (barWidth / 2) +

          (index * spacing);

      final height =

          _resolveBarHeight(

        index: index,

        count: count,

        availableHeight:

            size.height,

      );

      paint.color =

          x <= activeUntil

          ? activeColor

          : inactiveColor;

      canvas.drawLine(

        Offset(

          x,

          (size.height -

                  height) /

              2,

        ),

        Offset(

          x,

          (size.height +

                  height) /

              2,

        ),

        paint,

      );

    }

  }

  double _resolveBarHeight({

    required int index,

    required int count,

    required double availableHeight,

  }) {

    double height;

    if (samples.isNotEmpty) {

      final fraction =

          count <= 1

          ? 0.0

          : index /

              (count - 1);

      final samplePosition =

          fraction *

          (samples.length - 1);

      final sampleIndex =

          samplePosition

              .round()

              .clamp(

                0,

                samples.length - 1,

              );

      final amplitude =

          samples[sampleIndex]

              .clamp(

                0.02,

                1.0,

              )

              .toDouble();

      height =

          3 +

          (amplitude * 22);

    } else {

      height =

          _fallbackHeights[

            index %

                _fallbackHeights

                    .length

          ];

    }

    return math.min(

      height,

      availableHeight - 2,

    );

  }

  @override

  bool shouldRepaint(

    covariant _WaveformPainter

        oldDelegate,

  ) {

    return oldDelegate.progress !=

            progress ||

        !identical(

          oldDelegate.samples,

          samples,

        ) ||

        oldDelegate.activeColor !=

            activeColor ||

        oldDelegate.inactiveColor !=

            inactiveColor;

  }

}

// =============================================================================

// Duration

// =============================================================================

String _formatDuration(

  int seconds,

) {

  final safeSeconds =

      math.max(

    0,

    seconds,

  );

  final minutes =

      safeSeconds ~/ 60;

  final remainingSeconds =

      (safeSeconds % 60)

          .toString()

          .padLeft(

            2,

            '0',

          );

  return '$minutes:$remainingSeconds';

}
