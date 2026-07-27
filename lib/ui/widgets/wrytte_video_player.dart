import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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

  const WrytteVideoPlayer({
    super.key,
    required this.source,
    this.autoPlay = false,
    this.loop = false,
    this.controlsEnabled = true,
    this.showProgress = true,
    this.autoPlayWhenVisible = false,
    this.startMuted = false,
    this.showRemainingTime = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  State<WrytteVideoPlayer> createState() => _WrytteVideoPlayerState();
}

class _WrytteVideoPlayerState extends State<WrytteVideoPlayer> {
  VideoPlayerController? _controller;
  Future<void>? _initialise;
  Timer? _visibilityTimer;
  bool _muted = false;
  bool _isVisible = false;
  int _remainingSeconds = 0;
  bool _lastPlaying = false;

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
    _visibilityTimer?.cancel();
    _visibilityTimer = null;
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _controller = null;
  }

  void _createController() {
    final source = widget.source.trim();
    if (source.startsWith('http')) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(source));
    } else {
      _controller = VideoPlayerController.file(File(source));
    }
    _controller!.setLooping(widget.loop);
    _initialise = _controller!.initialize().then((_) async {
      final controller = _controller;
      if (controller == null) return;
      await controller.setVolume(_muted ? 0 : 1);
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
    });
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
    if (visible == _isVisible) return;
    _isVisible = visible;
    if (visible) {
      controller.play();
    } else {
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
    if (widget.autoPlayWhenVisible && _muted) {
      await _setMuted(false);
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
    if (controller == null) return const _VideoErrorPlaceholder();

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
                    left: 10,
                    bottom: widget.showProgress ? 14 : 8,
                    child: _VideoBadge(
                      child: Text(
                        _remainingLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (widget.controlsEnabled)
                  Positioned(
                    right: 10,
                    bottom: widget.showProgress ? 14 : 8,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _setMuted(!_muted),
                      child: _VideoBadge(
                        child: Icon(
                          _muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: Colors.white,
                          size: 20,
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
  const _VideoBadge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
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
