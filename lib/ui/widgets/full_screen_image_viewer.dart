import 'package:flutter/material.dart';
import 'package:wrytte/ui/widgets/wrytte_persistent_image.dart';

class FullScreenImageViewer extends StatelessWidget {
  final String source;

  const FullScreenImageViewer({super.key, required this.source});

  static Future<void> open(BuildContext context, String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return Future.value();
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => FullScreenImageViewer(source: trimmed),
        transitionsBuilder:
            (_, animation, __, child) =>
                FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 5,
              child: Center(child: _image()),
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

  Widget _image() {
    return WryttePersistentImage(
      source: source,
      fit: BoxFit.contain,
      placeholder: const CircularProgressIndicator(strokeWidth: 2),
      errorWidget: const Icon(
        Icons.broken_image_outlined,
        color: Colors.white70,
        size: 48,
      ),
    );
  }
}
