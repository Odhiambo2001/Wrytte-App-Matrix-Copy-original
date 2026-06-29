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

  @override
  void initState() {
    super.initState();
    _copy = _resolve(widget.source);
  }

  @override
  void didUpdateWidget(covariant WryttePersistentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _copy = _resolve(widget.source);
  }

  Future<File> _resolve(String source) {
    final cleanSource = source.trim();
    return _copies.putIfAbsent(cleanSource, () async {
      final copy = await AttachmentLocalStore.instance.ensureComplete(
        source: cleanSource,
        fileName: 'photo.jpg',
      );
      return copy.file;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: _copy,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Image.file(snapshot.data!, fit: widget.fit);
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
