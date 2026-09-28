import 'dart:async';
import 'dart:typed_data';

import 'package:wrytte/data/models/photo_manager_asset_record.dart';
import 'package:wrytte/data/services/device_media_library_service.dart';
import 'package:wrytte/domain/models/media_album.dart';
import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/models/media_library_access.dart';
import 'package:wrytte/domain/models/media_page.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';

class MediaLibraryRepositoryImpl implements MediaLibraryRepository {
  MediaLibraryRepositoryImpl(this._service) {
    _service.changes.listen(_scheduleChange);
  }

  final DeviceMediaLibraryService _service;
  final _changes = StreamController<void>.broadcast();
  final _albumCaches = <String, _AlbumCache>{};
  final _pageRequests = <String, Future<MediaPage>>{};
  final Map<String, Future<Uint8List?>> _thumbnailRequests =
      <String, Future<Uint8List?>>{};
  Timer? _changeDebounce;
  int _observers = 0;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<MediaLibraryAccess> requestAccess(Set<MediaKind> kinds) {
    return _service.requestAccess(kinds);
  }

  @override
  Future<MediaAlbum?> loadRecentAlbum(Set<MediaKind> kinds) async {
    final record = await _service.loadRecentAlbum(kinds);
    if (record == null || record.assetCount == 0) return null;
    return MediaAlbum(
      id: record.id,
      name: 'Recents',
      assetCount: record.assetCount,
      isAll: true,
      coverAssetId: record.coverAssetId,
    );
  }

  @override
  Future<List<MediaAlbum>> loadAlbums(Set<MediaKind> kinds) async {
    final records = await _service.loadAlbums(kinds);
    final hasAllAlbum = records.any((record) => record.isAll);
    final albums = records
        .where(
          (record) => !hasAllAlbum || record.isAll || record.name.trim() != '0',
        )
        .map(
          (record) => MediaAlbum(
            id: record.id,
            name: record.name.isEmpty ? 'Album' : record.name,
            assetCount: record.assetCount,
            isAll: record.isAll,
            coverAssetId: record.coverAssetId,
          ),
        )
        .toList(growable: false);
    albums.sort((a, b) {
      if (a.isAll != b.isAll) return a.isAll ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return albums;
  }

  @override
  Future<MediaPage> loadPage({
    required String albumId,
    required int page,
    required int size,
    required Set<MediaKind> kinds,
  }) {
    final cacheKey = _cacheKey(albumId, kinds);
    final requestKey = '$cacheKey:$page';
    final existing = _pageRequests[requestKey];
    if (existing != null) return existing;

    final request = _loadPage(
      cacheKey: cacheKey,
      albumId: albumId,
      page: page,
      size: size,
      kinds: kinds,
    );
    _pageRequests[requestKey] = request;
    return request.whenComplete(() => _pageRequests.remove(requestKey));
  }

  Future<MediaPage> _loadPage({
    required String cacheKey,
    required String albumId,
    required int page,
    required int size,
    required Set<MediaKind> kinds,
  }) async {
    final records = await _service.loadPage(
      albumId: albumId,
      page: page,
      size: size,
      kinds: kinds,
    );
    final incoming = records.map(_mapAsset);
    final previous = page == 0
        ? const <MediaAsset>[]
        : (_albumCaches[cacheKey]?.assets ?? const <MediaAsset>[]);
    final assets = _deduplicate([...previous, ...incoming]);
    final result = MediaPage(
      assets: assets,
      nextPage: page + 1,
      hasMore: records.length == size,
    );
    _albumCaches[cacheKey] = _AlbumCache(
      assets: assets,
      nextPage: result.nextPage,
      hasMore: result.hasMore,
    );
    return result;
  }

  @override
  Future<MediaPage> reconcileFirstPage({
    required String albumId,
    required int size,
    required Set<MediaKind> kinds,
  }) async {
    final cacheKey = _cacheKey(albumId, kinds);
    final previous = _albumCaches[cacheKey];
    if (previous == null) {
      return loadPage(albumId: albumId, page: 0, size: size, kinds: kinds);
    }
    final records = await _service.loadPage(
      albumId: albumId,
      page: 0,
      size: size,
      kinds: kinds,
    );
    final firstPage = records.map(_mapAsset).toList(growable: false);
    final oldIds = previous.assets.map((asset) => asset.id).toSet();
    final newCount = firstPage
        .where((asset) => !oldIds.contains(asset.id))
        .length;
    final assets = _deduplicate([...firstPage, ...previous.assets]);
    _albumCaches[cacheKey] = _AlbumCache(
      assets: assets,
      nextPage: previous.nextPage,
      hasMore: previous.hasMore,
    );
    return MediaPage(
      assets: assets,
      nextPage: previous.nextPage,
      hasMore: previous.hasMore,
      newAssetCount: newCount,
    );
  }

  @override
  Future<Uint8List?> loadThumbnail(
    String assetId, {
    required int width,
    required int height,
  }) {
    final widthBucket = _sizeBucket(width);
    final heightBucket = _sizeBucket(height);
    final key = '$assetId:$widthBucket:$heightBucket';
    final cached = _thumbnailRequests.remove(key);
    if (cached != null) {
      _thumbnailRequests[key] = cached;
      return cached;
    }
    final request = _service.loadThumbnail(
      assetId,
      width: widthBucket,
      height: heightBucket,
    );
    _thumbnailRequests[key] = request;
    while (_thumbnailRequests.length > 180) {
      _thumbnailRequests.remove(_thumbnailRequests.keys.first);
    }
    return request;
  }

  @override
  Future<String?> loadFilePath(String assetId) =>
      _service.loadFilePath(assetId);

  @override
  Future<void> warmThumbnails(
    Iterable<String> assetIds, {
    required int width,
    required int height,
  }) {
    return _service.warmThumbnails(
      assetIds,
      width: _sizeBucket(width),
      height: _sizeBucket(height),
    );
  }

  @override
  Future<void> manageLimitedAccess(Set<MediaKind> kinds) {
    return _service.manageLimitedAccess(kinds);
  }

  @override
  Future<void> openSettings() => _service.openSettings();

  @override
  Future<void> startObserving() async {
    if (_observers > 0) {
      _observers += 1;
      return;
    }
    try {
      await _service.startObserving();
      _observers = 1;
    } catch (_) {
      _observers = 0;
      rethrow;
    }
  }

  @override
  Future<void> stopObserving() async {
    if (_observers == 0) return;
    _observers -= 1;
    if (_observers == 0) await _service.stopObserving();
  }

  void _scheduleChange(void _) {
    _changeDebounce?.cancel();
    _changeDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!_changes.isClosed) _changes.add(null);
    });
  }

  String _cacheKey(String albumId, Set<MediaKind> kinds) {
    final kindKey = kinds.map((kind) => kind.name).toList()..sort();
    return '$albumId:${kindKey.join(',')}';
  }

  int _sizeBucket(int value) => ((value.clamp(64, 1024) + 31) ~/ 64) * 64;

  MediaAsset _mapAsset(PhotoManagerAssetRecord record) {
    return MediaAsset(
      id: record.id,
      kind: record.isVideo ? MediaKind.video : MediaKind.image,
      width: record.width,
      height: record.height,
      createdAt: record.createdAt,
      duration: Duration(seconds: record.durationSeconds),
      title: record.title,
    );
  }

  List<MediaAsset> _deduplicate(Iterable<MediaAsset> input) {
    final ids = <String>{};
    return input.where((asset) => ids.add(asset.id)).toList(growable: false);
  }
}

class _AlbumCache {
  const _AlbumCache({
    required this.assets,
    required this.nextPage,
    required this.hasMore,
  });

  final List<MediaAsset> assets;
  final int nextPage;
  final bool hasMore;
}
