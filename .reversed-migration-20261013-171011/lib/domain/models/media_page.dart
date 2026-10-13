import 'package:wrytte/domain/models/media_asset.dart';

class MediaPage {
  const MediaPage({
    required this.assets,
    required this.nextPage,
    required this.hasMore,
    this.newAssetCount = 0,
  });

  final List<MediaAsset> assets;
  final int nextPage;
  final bool hasMore;
  final int newAssetCount;
}
