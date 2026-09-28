import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class MediaThumbnailImage extends StatefulWidget {
  const MediaThumbnailImage({
    super.key,
    required this.assetId,
    required this.repository,
    required this.pixelSize,
    this.fit = BoxFit.cover,
    this.semanticLabel,
  });

  final String assetId;
  final MediaLibraryRepository repository;
  final int pixelSize;
  final BoxFit fit;
  final String? semanticLabel;

  @override
  State<MediaThumbnailImage> createState() => _MediaThumbnailImageState();
}

class _MediaThumbnailImageState extends State<MediaThumbnailImage> {
  late Future<Uint8List?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MediaThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.pixelSize != widget.pixelSize ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  void _load() {
    _thumbnail = widget.repository.loadThumbnail(
      widget.assetId,
      width: widget.pixelSize,
      height: widget.pixelSize,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: WrytteColors.surfaceRaised,
      child: FutureBuilder<Uint8List?>(
        future: _thumbnail,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            if (snapshot.connectionState == ConnectionState.done) {
              return const Center(
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: WrytteColors.textMuted,
                  size: 24,
                ),
              );
            }
            return const SizedBox.expand();
          }
          return Image.memory(
            bytes,
            fit: widget.fit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            semanticLabel: widget.semanticLabel,
          );
        },
      ),
    );
  }
}

class MediaAssetThumbnail extends StatelessWidget {
  const MediaAssetThumbnail({
    super.key,
    required this.asset,
    required this.repository,
    required this.pixelSize,
    this.fit = BoxFit.cover,
  });

  final MediaAsset asset;
  final MediaLibraryRepository repository;
  final int pixelSize;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return MediaThumbnailImage(
      assetId: asset.id,
      repository: repository,
      pixelSize: pixelSize,
      fit: fit,
      semanticLabel: asset.kind == MediaKind.video ? 'Video' : 'Photo',
    );
  }
}
