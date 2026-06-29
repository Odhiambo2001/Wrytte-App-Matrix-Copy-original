import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class WrytteVideoPlayer extends StatefulWidget {
  final String source;
  final bool autoPlay;
  final bool loop;
  final bool controlsEnabled;
  final bool showProgress;
  final BorderRadius borderRadius;

  const WrytteVideoPlayer({
    super.key,
    required this.source,
    this.autoPlay = false,
    this.loop = false,
    this.controlsEnabled = true,
    this.showProgress = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  State<WrytteVideoPlayer> createState() => _WrytteVideoPlayerState();
}

class _WrytteVideoPlayerState extends State<WrytteVideoPlayer> {
  VideoPlayerController? _controller;
  Future<void>? _initialise;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  @override
  void didUpdateWidget(covariant WrytteVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _controller?.dispose();
      _createController();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _createController() {
    final source = widget.source.trim();
    if (source.startsWith('http')) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(source));
    } else {
      _controller = VideoPlayerController.file(File(source));
    }
    _controller!.setLooping(widget.loop);
    _initialise = _controller!.initialize().then((_) {
      if (widget.autoPlay) _controller!.play();
      if (mounted) setState(() {});
    });
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() {
      controller.value.isPlaying ? controller.pause() : controller.play();
    });
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
            onTap: widget.controlsEnabled ? _togglePlay : null,
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
                      color: Colors.black.withOpacity(0.42),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 38,
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
