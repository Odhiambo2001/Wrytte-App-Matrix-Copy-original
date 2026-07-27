import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Renders a channel image at its real aspect ratio.
///
/// Matrix events created by older clients may not contain width/height
/// metadata. In that case the decoded image dimensions are used instead of
/// assuming 9:16, which prevents landscape images from being cropped/zoomed.
class ChannelPostImage extends StatefulWidget {
  const ChannelPostImage({
    super.key,
    required this.source,
    this.mediaWidth,
    this.mediaHeight,
  });

  final String source;
  final int? mediaWidth;
  final int? mediaHeight;

  @override
  State<ChannelPostImage> createState() => _ChannelPostImageState();
}

class _ChannelPostImageState extends State<ChannelPostImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspectRatio;
  bool _resolvedIntrinsicRatio = false;

  @override
  void initState() {
    super.initState();
    _setMetadataRatio();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_resolvedIntrinsicRatio) _resolveIntrinsicRatio();
  }

  @override
  void didUpdateWidget(covariant ChannelPostImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.mediaWidth != widget.mediaWidth ||
        oldWidget.mediaHeight != widget.mediaHeight) {
      _removeImageListener();
      _aspectRatio = null;
      _resolvedIntrinsicRatio = false;
      _setMetadataRatio();
      _resolveIntrinsicRatio();
    }
  }

  @override
  void dispose() {
    _removeImageListener();
    super.dispose();
  }

  ImageProvider get _provider =>
      widget.source.startsWith('/')
          ? FileImage(File(widget.source))
          : CachedNetworkImageProvider(widget.source);

  void _setMetadataRatio() {
    final width = widget.mediaWidth;
    final height = widget.mediaHeight;
    if (width != null && width > 0 && height != null && height > 0) {
      _aspectRatio = width / height;
    }
  }

  void _resolveIntrinsicRatio() {
    _removeImageListener();
    final stream = _provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, _) {
        final ratio = image.image.width / image.image.height;
        _resolvedIntrinsicRatio = true;
        _removeImageListener();
        if (!mounted || ratio <= 0) return;
        setState(() => _aspectRatio = ratio);
      },
      onError: (_, __) {
        _resolvedIntrinsicRatio = true;
        _removeImageListener();
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _removeImageListener() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _aspectRatio;
    final isNineBySixteen = ratio != null && (ratio - 9 / 16).abs() <= 0.08;
    final isPortrait = ratio != null && ratio < 1;

    return Padding(
      padding: EdgeInsets.only(
        right:
            isNineBySixteen
                ? 0
                : isPortrait
                ? 50
                : 8,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          // Match the action-row span ending immediately before Share.
          widthFactor: isNineBySixteen ? 0.70 : 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              // While decoding old media without metadata, contain the image
              // rather than cropping it. The real ratio replaces this quickly.
              aspectRatio: ratio ?? 1,
              child: Image(
                image: _provider,
                fit: ratio == null ? BoxFit.contain : BoxFit.cover,
                frameBuilder:
                    (context, child, frame, wasSynchronouslyLoaded) =>
                        frame != null || wasSynchronouslyLoaded
                            ? child
                            : const ColoredBox(
                              color: Color(0xFF23262C),
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFF4DA3FF),
                                ),
                              ),
                            ),
                errorBuilder:
                    (_, __, ___) => const ColoredBox(
                      color: Color(0xFF23262C),
                      child: Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white54,
                        ),
                      ),
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
