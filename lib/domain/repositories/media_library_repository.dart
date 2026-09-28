import 'dart:typed_data';

import 'package:wrytte/domain/models/media_album.dart';
import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/models/media_library_access.dart';
import 'package:wrytte/domain/models/media_page.dart';

abstract interface class MediaLibraryRepository {
  Stream<void> get changes;

  Future<MediaLibraryAccess> requestAccess(Set<MediaKind> kinds);
  Future<MediaAlbum?> loadRecentAlbum(Set<MediaKind> kinds);
  Future<List<MediaAlbum>> loadAlbums(Set<MediaKind> kinds);
  Future<MediaPage> loadPage({
    required String albumId,
    required int page,
    required int size,
    required Set<MediaKind> kinds,
  });
  Future<MediaPage> reconcileFirstPage({
    required String albumId,
    required int size,
    required Set<MediaKind> kinds,
  });
  Future<Uint8List?> loadThumbnail(
    String assetId, {
    required int width,
    required int height,
  });
  Future<String?> loadFilePath(String assetId);
  Future<void> warmThumbnails(
    Iterable<String> assetIds, {
    required int width,
    required int height,
  });
  Future<void> manageLimitedAccess(Set<MediaKind> kinds);
  Future<void> openSettings();
  Future<void> startObserving();
  Future<void> stopObserving();
}
