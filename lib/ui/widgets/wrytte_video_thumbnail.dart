import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:wrytte/services/attachment_local_store.dart';

class WrytteVideoThumbnail extends StatefulWidget {
  final String source;
  final BoxFit fit;

  const WrytteVideoThumbnail({
    super.key,
    required this.source,
    this.fit = BoxFit.cover,
  });

  @override
  State<WrytteVideoThumbnail> createState() => _WrytteVideoThumbnailState();
}

class _WrytteVideoThumbnailState extends State<WrytteVideoThumbnail> {
  static final Map<String, Future<File?>> _thumbnailTasks = {};
  late Future<File?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = _taskFor(widget.source);
  }

  @override
  void didUpdateWidget(covariant WrytteVideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _thumbnail = _taskFor(widget.source);
    }
  }

  Future<File?> _taskFor(String source) {
    return _thumbnailTasks.putIfAbsent(source, () async {
      try {
        final thumbnail = await _createThumbnail(source);
        if (thumbnail == null) _thumbnailTasks.remove(source);
        return thumbnail;
      } catch (error) {
        _thumbnailTasks.remove(source);
        debugPrint(
          '[WrytteVideoThumbnail] generation failed source="$source" '
          'error=$error',
        );
        return null;
      }
    });
  }

  Future<File?> _createThumbnail(String source) async {
    final cleanSource = source.trim();
    if (cleanSource.isEmpty) return null;

    final cacheDirectory = await getTemporaryDirectory();
    final cachedThumbnail = File(
      '${cacheDirectory.path}/wrytte_video_thumb_v2_${cleanSource.hashCode}.jpg',
    );
    if (await cachedThumbnail.exists() && await cachedThumbnail.length() > 0) {
      return cachedThumbnail;
    }

    final resolvedVideoFile =
        (
          await AttachmentLocalStore.instance.ensureComplete(
            source: cleanSource,
            fileName: 'video.mp4',
          ),
        ).$1.file;
    if (!await resolvedVideoFile.exists()) return null;

    var videoFile = resolvedVideoFile;
    if (cleanSource.startsWith('http') &&
        !resolvedVideoFile.path.toLowerCase().endsWith('.mp4')) {
      final normalizedVideo = File(
        '${cacheDirectory.path}/wrytte_video_source_${cleanSource.hashCode}.mp4',
      );
      if (!await normalizedVideo.exists() ||
          await normalizedVideo.length() == 0) {
        await resolvedVideoFile.copy(normalizedVideo.path);
      }
      videoFile = normalizedVideo;
    }

    final generatedPath = await VideoThumbnail.thumbnailFile(
      video: videoFile.path,
      thumbnailPath: cacheDirectory.path,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 720,
      timeMs: 1000,
      quality: 82,
    );
    if (generatedPath == null || generatedPath.isEmpty) return null;

    final generated = File(generatedPath);
    if (!await generated.exists()) return null;
    if (generated.path != cachedThumbnail.path) {
      await generated.copy(cachedThumbnail.path);
    }
    return cachedThumbnail;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _thumbnail,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file != null) {
          return SizedBox.expand(
            child: Image.file(file, fit: widget.fit, gaplessPlayback: true),
          );
        }
        return const SizedBox.expand(child: ColoredBox(color: Colors.black));
      },
    );
  }
}
