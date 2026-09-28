class PhotoManagerAlbumRecord {
  const PhotoManagerAlbumRecord({
    required this.id,
    required this.name,
    required this.assetCount,
    required this.isAll,
    this.coverAssetId,
  });

  final String id;
  final String name;
  final int assetCount;
  final bool isAll;
  final String? coverAssetId;
}
