enum MediaKind { image, video }

class MediaAsset {
  const MediaAsset({
    required this.id,
    required this.kind,
    required this.width,
    required this.height,
    required this.createdAt,
    this.duration = Duration.zero,
    this.title,
  });

  final String id;
  final MediaKind kind;
  final int width;
  final int height;
  final DateTime createdAt;
  final Duration duration;
  final String? title;

  double get aspectRatio => width > 0 && height > 0 ? width / height : 1;
}
