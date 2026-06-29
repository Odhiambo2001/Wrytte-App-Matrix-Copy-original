import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wrytte/services/attachment_local_store.dart';
import 'package:wrytte/ui/widgets/wrytte_video_player.dart';

class FullScreenVideoViewer extends StatefulWidget {
  final String source;

  const FullScreenVideoViewer({super.key, required this.source});

  static Future<void> open(BuildContext context, String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return Future.value();
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => FullScreenVideoViewer(source: trimmed),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  State<FullScreenVideoViewer> createState() => _FullScreenVideoViewerState();
}

class _FullScreenVideoViewerState extends State<FullScreenVideoViewer> {
  static final Map<String, Future<String>> _localSources = {};
  late final Future<String> _playbackSource;

  @override
  void initState() {
    super.initState();
    _playbackSource = _localSources.putIfAbsent(
      widget.source,
      () => _resolvePlaybackSource(widget.source),
    );
  }

  Future<String> _resolvePlaybackSource(String source) async {
    if (!source.startsWith('http')) return source;

    final downloaded =
        (
          await AttachmentLocalStore.instance.ensureComplete(
            source: source,
            fileName: 'video.mp4',
          ),
        ).$1.file;
    if (!await downloaded.exists()) {
      throw const FileSystemException('Downloaded video is unavailable');
    }
    return downloaded.path;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: FutureBuilder<String>(
                future: _playbackSource,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Icon(
                      Icons.videocam_off_outlined,
                      color: Colors.white70,
                      size: 48,
                    );
                  }
                  final localSource = snapshot.data;
                  if (localSource == null) {
                    return const CircularProgressIndicator(strokeWidth: 2);
                  }
                  return WrytteVideoPlayer(
                    source: localSource,
                    autoPlay: true,
                    borderRadius: BorderRadius.zero,
                  );
                },
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
