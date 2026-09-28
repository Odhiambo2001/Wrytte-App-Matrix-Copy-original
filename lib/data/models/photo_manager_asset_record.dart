class PhotoManagerAssetRecord {
  const PhotoManagerAssetRecord({
    required this.id,
    required this.isVideo,
    required this.width,
    required this.height,
    required this.createdAt,
    required this.durationSeconds,
    this.title,
  });

  final String id;
  final bool isVideo;
  final int width;
  final int height;
  final DateTime createdAt;
  final int durationSeconds;
  final String? title;
}
