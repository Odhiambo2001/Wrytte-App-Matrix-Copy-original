import 'dart:async';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:wrytte/data/models/photo_manager_album_record.dart';
import 'package:wrytte/data/models/photo_manager_asset_record.dart';
import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/models/media_library_access.dart';

class DeviceMediaLibraryService {
  final _changes = StreamController<void>.broadcast();
  final _albumsById = <String, AssetPathEntity>{};
  final _assetsById = <String, AssetEntity>{};
  bool _observing = false;

  Stream<void> get changes => _changes.stream;

  Future<MediaLibraryAccess> requestAccess(Set<MediaKind> kinds) async {
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: _permissionOption(kinds),
    );
    return _mapPermission(permission);
  }

  Future<List<PhotoManagerAlbumRecord>> loadAlbums(Set<MediaKind> kinds) async {
    final paths = await PhotoManager.getAssetPathList(
      hasAll: true,
      type: _requestType(kinds),
      filterOption: _newestFirstFilter(),
    );
    _albumsById
      ..clear()
      ..addEntries(paths.map((path) => MapEntry(path.id, path)));

    final records = await Future.wait(paths.map(_albumRecord));
    final seenIds = <String>{};
    return records
        .where((album) {
          return album.assetCount > 0 && seenIds.add(album.id);
        })
        .toList(growable: false);
  }

  Future<PhotoManagerAlbumRecord?> loadRecentAlbum(Set<MediaKind> kinds) async {
    final paths = await PhotoManager.getAssetPathList(
      hasAll: true,
      onlyAll: true,
      type: _requestType(kinds),
      filterOption: _newestFirstFilter(),
    );
    if (paths.isEmpty) return null;
    final path = paths.first;
    _albumsById[path.id] = path;
    return _albumRecord(path);
  }

  Future<List<PhotoManagerAssetRecord>> loadPage({
    required String albumId,
    required int page,
    required int size,
    required Set<MediaKind> kinds,
  }) async {
    var album = _albumsById[albumId];
    album ??= await AssetPathEntity.fromId(
      albumId,
      type: _requestType(kinds),
      filterOption: _newestFirstFilter(),
    );
    _albumsById[albumId] = album;
    final entities = await album.getAssetListPaged(
      page: page,
      size: size,
      type: _requestType(kinds),
    );
    for (final entity in entities) {
      _assetsById[entity.id] = entity;
    }
    return entities.map(_assetRecord).toList(growable: false);
  }

  Future<Uint8List?> loadThumbnail(
    String assetId, {
    required int width,
    required int height,
  }) async {
    final entity = _assetsById[assetId] ?? await AssetEntity.fromId(assetId);
    if (entity == null) return null;
    _assetsById[assetId] = entity;
    return entity.thumbnailDataWithOption(
      ThumbnailOption(
        size: ThumbnailSize(width, height),
        format: ThumbnailFormat.jpeg,
        quality: 88,
      ),
    );
  }

  Future<String?> loadFilePath(String assetId) async {
    final entity = _assetsById[assetId] ?? await AssetEntity.fromId(assetId);
    if (entity == null) return null;
    _assetsById[assetId] = entity;
    final file = await entity.file;
    return file?.path;
  }

  Future<void> warmThumbnails(
    Iterable<String> assetIds, {
    required int width,
    required int height,
  }) async {
    final ids = assetIds.where(_assetsById.containsKey).toList(growable: false);
    if (ids.isEmpty) return;
    await PhotoCachingManager().requestCacheAssetsWithIds(
      assetIds: ids,
      option: ThumbnailOption(size: ThumbnailSize(width, height), quality: 88),
    );
  }

  Future<void> manageLimitedAccess(Set<MediaKind> kinds) {
    return PhotoManager.presentLimited(type: _requestType(kinds));
  }

  Future<void> openSettings() => PhotoManager.openSetting();

  Future<void> startObserving() async {
    if (_observing) return;
    PhotoManager.addChangeCallback(_handleNativeChange);
    try {
      await PhotoManager.startChangeNotify();
      _observing = true;
    } catch (_) {
      PhotoManager.removeChangeCallback(_handleNativeChange);
      rethrow;
    }
  }

  Future<void> stopObserving() async {
    if (!_observing) return;
    _observing = false;
    PhotoManager.removeChangeCallback(_handleNativeChange);
    await PhotoManager.stopChangeNotify();
  }

  void _handleNativeChange(MethodCall _) {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<PhotoManagerAlbumRecord> _albumRecord(AssetPathEntity path) async {
    final count = await path.assetCountAsync;
    List<AssetEntity> cover = const [];
    if (count > 0) {
      try {
        cover = await path.getAssetListPaged(page: 0, size: 1);
      } catch (_) {
        // A missing/cloud-only cover does not make the album unusable.
      }
    }
    if (cover.isNotEmpty) _assetsById[cover.first.id] = cover.first;
    return PhotoManagerAlbumRecord(
      id: path.id,
      name: path.isAll ? 'Recents' : path.name.trim(),
      assetCount: count,
      isAll: path.isAll,
      coverAssetId: cover.isEmpty ? null : cover.first.id,
    );
  }

  PhotoManagerAssetRecord _assetRecord(AssetEntity entity) {
    return PhotoManagerAssetRecord(
      id: entity.id,
      isVideo: entity.type == AssetType.video,
      width: entity.orientatedWidth,
      height: entity.orientatedHeight,
      createdAt: entity.createDateTime,
      durationSeconds: entity.duration,
      title: entity.title,
    );
  }

  PermissionRequestOption _permissionOption(Set<MediaKind> kinds) {
    return PermissionRequestOption(
      androidPermission: AndroidPermission(
        type: _requestType(kinds),
        mediaLocation: false,
      ),
    );
  }

  RequestType _requestType(Set<MediaKind> kinds) {
    final images = kinds.contains(MediaKind.image);
    final videos = kinds.contains(MediaKind.video);
    if (images && videos) return RequestType.common;
    if (videos) return RequestType.video;
    return RequestType.image;
  }

  FilterOptionGroup _newestFirstFilter() {
    return FilterOptionGroup(
      orders: const [OrderOption(type: OrderOptionType.createDate, asc: false)],
    );
  }

  MediaLibraryAccess _mapPermission(PermissionState state) {
    return switch (state) {
      PermissionState.authorized => MediaLibraryAccess.full,
      PermissionState.limited => MediaLibraryAccess.limited,
      PermissionState.restricted => MediaLibraryAccess.restricted,
      PermissionState.denied ||
      PermissionState.notDetermined => MediaLibraryAccess.denied,
    };
  }
}
