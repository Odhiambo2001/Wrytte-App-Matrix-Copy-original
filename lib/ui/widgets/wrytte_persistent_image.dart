import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wrytte/services/attachment_local_store.dart';

class WryttePersistentImage extends StatefulWidget {
  final String source;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  const WryttePersistentImage({
    super.key,
    required this.source,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<WryttePersistentImage> createState() => _WryttePersistentImageState();
}

class _WryttePersistentImageState extends State<WryttePersistentImage> {
  static final Map<String, Future<File>> _copies = {};
  late Future<File> _copy;
  bool _retriedAfterDecodeFailure = false;

  @override
  void initState() {
    super.initState();
    _copy = _resolve(widget.source);
  }

  @override
  void didUpdateWidget(covariant WryttePersistentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _retriedAfterDecodeFailure = false;
      _copy = _resolve(widget.source);
    }
  }

  Future<void> _retryAfterDecodeFailure() async {
    if (_retriedAfterDecodeFailure) return;
    _retriedAfterDecodeFailure = true;
    await AttachmentLocalStore.instance.deleteLocalCopy(
      source: widget.source,
      fileName: 'photo.jpg',
    );
    if (!mounted) return;
    setState(() => _copy = _resolve(widget.source));
  }

  Future<File> _resolve(String source) {
    final cleanSource = source.trim();
    return _copies.putIfAbsent(cleanSource, () async {
      // Optimistic outgoing messages already point at the selected local file.
      // Use it synchronously instead of routing it through the attachment
      // store, which otherwise leaves the bubble showing its placeholder for
      // one or more frames while the cache lookup completes.
      final localPath = cleanSource.startsWith('file://')
          ? Uri.parse(cleanSource).toFilePath()
          : cleanSource;
      if (!cleanSource.startsWith('http://') &&
          !cleanSource.startsWith('https://') &&
          !cleanSource.startsWith('mxc://')) {
        final localFile = File(localPath);
        if (localFile.existsSync()) return localFile;
      }
      final copy = await AttachmentLocalStore.instance.ensureComplete(
        source: cleanSource,
        fileName: 'photo.jpg',
      );
      return copy.file;
    });
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source.trim();
    final localPath = source.startsWith('file://')
        ? Uri.parse(source).toFilePath()
        : source;
    if (!source.startsWith('http://') &&
        !source.startsWith('https://') &&
        !source.startsWith('mxc://')) {
      final localFile = File(localPath);
      if (localFile.existsSync()) {
        return Image.file(
          localFile,
          fit: widget.fit,
          errorBuilder: (context, error, stackTrace) =>
              widget.errorWidget ?? const SizedBox.shrink(),
        );
      }
    }
    return FutureBuilder<File>(
      future: _copy,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Image.file(
            snapshot.data!,
            fit: widget.fit,
            errorBuilder: (context, error, stackTrace) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _retryAfterDecodeFailure();
              });
              return const Center(
                child: Icon(Icons.image_outlined, color: Colors.white54),
              );
            },
          );
        }
        if (snapshot.hasError) {
          return widget.errorWidget ??
              const Center(
                child: Icon(Icons.broken_image_outlined, color: Colors.white70),
              );
        }
        return widget.placeholder ??
            const Center(
              child: Icon(Icons.image_outlined, color: Colors.white54),
            );
      },
    );
  }
}
