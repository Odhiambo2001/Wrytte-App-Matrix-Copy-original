import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:wrytte/services/attachment_local_store.dart';

class WrytteVideoPlayer extends StatefulWidget {
  final String source;
  final bool autoPlay;
  final bool loop;
  final bool controlsEnabled;
  final bool showProgress;
  final bool autoPlayWhenVisible;
  final bool startMuted;
  final bool showRemainingTime;
  final BorderRadius borderRadius;
  final ValueChanged<double>? onAspectRatioReady;
  final bool compactOverlays;

  const WrytteVideoPlayer({
    super.key,
    required this.source,
    this.autoPlay = false,
    this.loop = false,
    this.controlsEnabled = true,
    this.showProgress = false,
    this.autoPlayWhenVisible = false,
    this.startMuted = false,
    this.showRemainingTime = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.onAspectRatioReady,
    this.compactOverlays = true,
  });

  @override
  State<WrytteVideoPlayer> createState() => _WrytteVideoPlayerState();
}

class _WrytteVideoPlayerState extends State<WrytteVideoPlayer> {
  static _WrytteVideoPlayerState? _activeAutoPlayer;

  VideoPlayerController? _controller;
  Future<void>? _initialise;
  Timer? _visibilityTimer;
  bool _muted = false;
  int _remainingSeconds = 0;
  bool _lastPlaying = false;
  int _controllerGeneration = 0;

  @override
  void initState() {
    super.initState();
    _muted = widget.startMuted;
    _createController();
  }

  @override
  void didUpdateWidget(covariant WrytteVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _disposeController();
      _muted = widget.startMuted;
      _createController();
    }
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    _controllerGeneration++;
    if (identical(_activeAutoPlayer, this)) {
      _activeAutoPlayer = null;
    }
    _visibilityTimer?.cancel();
    _visibilityTimer = null;
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _controller = null;
  }

  void _createController() {
    final generation = ++_controllerGeneration;
    _initialise = _createAndInitialiseController(generation);
  }

  Future<void> _createAndInitialiseController(int generation) async {
    final source = widget.source.trim();
    final localCopy =
        source.startsWith('http')
            ? await AttachmentLocalStore.instance.existingComplete(
              source: source,
              fileName: 'video.mp4',
            )
            : null;
    if (!mounted || generation != _controllerGeneration) return;
    if (localCopy != null) {
      _controller = VideoPlayerController.file(localCopy);
    } else if (source.startsWith('http')) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(source));
    } else {
      _controller = VideoPlayerController.file(File(source));
    }
    // Muted feed autoplay loops until the viewer deliberately opens/taps the
    // video. Explicit non-feed players continue to respect [widget.loop].
    _controller!.setLooping(widget.loop || widget.autoPlayWhenVisible);
    await _controller!.initialize();
    final controller = _controller;
    if (controller == null || generation != _controllerGeneration) return;
    await controller.setVolume(_muted ? 0 : 1);
    final aspectRatio = controller.value.aspectRatio;
    if (aspectRatio > 0) widget.onAspectRatioReady?.call(aspectRatio);
    controller.addListener(_onControllerChanged);
    _remainingSeconds = controller.value.duration.inSeconds;
    if (widget.autoPlayWhenVisible) {
      _visibilityTimer = Timer.periodic(
        const Duration(milliseconds: 300),
        (_) => _updateViewportPlayback(),
      );
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _updateViewportPlayback(),
      );
    } else if (widget.autoPlay) {
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    final controller = _controller;
    if (!mounted || controller == null || !controller.value.isInitialized) {
      return;
    }
    final remaining = (controller.value.duration - controller.value.position)
        .inMilliseconds
        .clamp(0, controller.value.duration.inMilliseconds);
    final remainingSeconds = (remaining / 1000).ceil();
    final playing = controller.value.isPlaying;
    if (remainingSeconds == _remainingSeconds && playing == _lastPlaying) {
      return;
    }
    setState(() {
      _remainingSeconds = remainingSeconds;
      _lastPlaying = playing;
    });
  }

  void _updateViewportPlayback() {
    if (!mounted || !widget.autoPlayWhenVisible) return;
    final controller = _controller;
    final renderObject = context.findRenderObject();
    if (controller == null ||
        !controller.value.isInitialized ||
        renderObject is! RenderBox ||
        !renderObject.hasSize) {
      return;
    }
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    final origin = renderObject.localToGlobal(Offset.zero);
    final bounds = origin & renderObject.size;
    final visibleBounds = bounds.intersect(screen);
    final visibleArea =
        visibleBounds.isEmpty
            ? 0.0
            : visibleBounds.width * visibleBounds.height;
    final totalArea = bounds.width * bounds.height;
    final visible = totalArea > 0 && visibleArea / totalArea >= 0.55;

    if (!visible) {
      if (identical(_activeAutoPlayer, this)) {
        _activeAutoPlayer = null;
      }
      controller.pause();
      return;
    }

    final active = _activeAutoPlayer;
    if (active == null || identical(active, this)) {
      _activeAutoPlayer = this;
      controller.play();
    } else {
      // Another visible post owns autoplay. Keep this video paused until that
      // player leaves the viewport and releases ownership.
      controller.pause();
    }
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() {
      controller.value.isPlaying ? controller.pause() : controller.play();
    });
  }

  Future<void> _handleVideoTap() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (widget.autoPlayWhenVisible) {
      // A deliberate tap switches this instance from passive, muted feed
      // playback to active viewing. Active viewing must not loop.
      await controller.setLooping(false);
      if (identical(_activeAutoPlayer, this) &&
          controller.value.isPlaying &&
          !_muted) {
        _togglePlay();
        return;
      }
      final previous = _activeAutoPlayer;
      if (previous != null && !identical(previous, this)) {
        previous._controller?.pause();
      }
      _activeAutoPlayer = this;
      await controller.play();
      if (_muted) {
        await _setMuted(false);
      }
      return;
    }
    _togglePlay();
  }

  Future<void> _setMuted(bool muted) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.setVolume(muted ? 0 : 1);
    if (!mounted) return;
    setState(() => _muted = muted);
  }

  String get _remainingLabel {
    final minutes = _remainingSeconds ~/ 60;
    final seconds = _remainingSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const _VideoLoadingPlaceholder();

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: FutureBuilder<void>(
        future: _initialise,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _VideoLoadingPlaceholder();
          }
          if (snapshot.hasError || !controller.value.isInitialized) {
            return const _VideoErrorPlaceholder();
          }
          return GestureDetector(
            onTap: widget.controlsEnabled ? _handleVideoTap : null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  color: Colors.black,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: controller.value.aspectRatio,
                      child: VideoPlayer(controller),
                    ),
                  ),
                ),
                if (widget.controlsEnabled && !controller.value.isPlaying)
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.42),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                if (widget.showRemainingTime)
                  Positioned(
                    left: widget.compactOverlays ? 8 : 10,
                    bottom: widget.showProgress ? 14 : 8,
                    child: _VideoBadge(
                      compact: widget.compactOverlays,
                      child: Text(
                        _remainingLabel,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: widget.compactOverlays ? 13 : 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (widget.controlsEnabled)
                  Positioned(
                    right: widget.compactOverlays ? 8 : 10,
                    bottom: widget.showProgress ? 14 : 8,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _setMuted(!_muted),
                      child: _VideoBadge(
                        compact: widget.compactOverlays,
                        child: Icon(
                          _muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: Colors.white,
                          size: widget.compactOverlays ? 18 : 20,
                        ),
                      ),
                    ),
                  ),
                if (widget.showProgress)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 6,
                    child: VideoProgressIndicator(
                      controller,
                      allowScrubbing: widget.controlsEnabled,
                      colors: const VideoProgressColors(
                        playedColor: Color(0xFF4DA3FF),
                        bufferedColor: Colors.white30,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _VideoBadge extends StatelessWidget {
  const _VideoBadge({required this.child, this.compact = false});

  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 7,
          vertical: compact ? 3 : 4,
        ),
        child: child,
      ),
    );
  }
}

class _VideoLoadingPlaceholder extends StatelessWidget {
  const _VideoLoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _VideoErrorPlaceholder extends StatelessWidget {
  const _VideoErrorPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Icon(Icons.videocam_off_outlined, color: Colors.white70),
      ),
    );
  }
}
