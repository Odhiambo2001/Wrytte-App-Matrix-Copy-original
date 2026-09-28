import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wrytte/domain/models/attachment_gallery_config.dart';
import 'package:wrytte/domain/models/attachment_gallery_result.dart';
import 'package:wrytte/domain/models/media_album.dart';
import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/models/media_library_access.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';

enum GalleryContentState { initialLoading, ready, empty, failed }

enum GalleryPagingState { idle, loading, exhausted, failed }

enum GalleryRefreshState { idle, reconciling }

class AttachmentGalleryViewModel extends ChangeNotifier {
  AttachmentGalleryViewModel(this._repository, {required this.config});

  static const int pageSize = 80;

  final MediaLibraryRepository _repository;
  final AttachmentGalleryConfig config;
  StreamSubscription<void>? _changeSubscription;
  int _requestGeneration = 0;
  bool _disposed = false;
  bool _observing = false;

  MediaLibraryAccess access = MediaLibraryAccess.unknown;
  GalleryContentState contentState = GalleryContentState.initialLoading;
  GalleryPagingState pagingState = GalleryPagingState.idle;
  GalleryRefreshState refreshState = GalleryRefreshState.idle;
  List<MediaAlbum> albums = const [];
  MediaAlbum? selectedAlbum;
  List<MediaAsset> assets = const [];
  String? errorMessage;
  int nextPage = 0;
  int newAssetCount = 0;
  final List<String> _selectedIds = [];

  List<String> get selectedIds => List.unmodifiable(_selectedIds);
  bool get hasSelection => _selectedIds.isNotEmpty;
  bool get hasMore => pagingState != GalleryPagingState.exhausted;

  List<MediaAsset> get selectedAssets {
    final byId = {for (final asset in assets) asset.id: asset};
    return _selectedIds.map((id) => byId[id]).whereType<MediaAsset>().toList();
  }

  AttachmentGalleryResult get result => AttachmentGalleryResult(selectedAssets);

  Future<void> initialize() async {
    await _changeSubscription?.cancel();
    _changeSubscription = null;
    if (_observing) {
      await _repository.stopObserving();
      _observing = false;
    }
    contentState = GalleryContentState.initialLoading;
    notifyListeners();
    try {
      access = await _repository.requestAccess(config.allowedKinds);
      if (!access.canRead) {
        contentState = GalleryContentState.empty;
        notifyListeners();
        return;
      }

      final recent = await _repository.loadRecentAlbum(config.allowedKinds);
      if (recent == null) {
        albums = await _repository.loadAlbums(config.allowedKinds);
        selectedAlbum = albums.firstOrNull;
      } else {
        albums = [recent];
        selectedAlbum = recent;
      }

      final album = selectedAlbum;
      if (album == null) {
        contentState = GalleryContentState.empty;
        notifyListeners();
        return;
      }
      await _loadFirstPage(album);
      try {
        await _repository.startObserving();
        _observing = true;
        _changeSubscription = _repository.changes.listen((_) => reconcile());
      } catch (_) {
        // Live refresh is an enhancement; it must not hide readable media.
      }
      unawaited(_discoverAlbums());
    } catch (error, stackTrace) {
      debugPrint('Attachment gallery initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      errorMessage = 'Could not load your photos.';
      contentState = GalleryContentState.failed;
      notifyListeners();
    }
  }

  Future<void> _discoverAlbums() async {
    try {
      final discovered = await _repository.loadAlbums(config.allowedKinds);
      if (_disposed) return;
      final active = selectedAlbum;
      albums = discovered;
      if (active != null && !albums.any((album) => album.id == active.id)) {
        albums = [active, ...albums];
      }
      notifyListeners();
    } catch (_) {
      // Recents remains fully usable if secondary album discovery fails.
    }
  }

  Future<void> retry() => initialize();

  Future<void> changeAlbum(MediaAlbum album) async {
    if (album.id == selectedAlbum?.id) return;
    selectedAlbum = album;
    assets = const [];
    nextPage = 0;
    contentState = GalleryContentState.initialLoading;
    pagingState = GalleryPagingState.idle;
    newAssetCount = 0;
    errorMessage = null;
    _selectedIds.clear();
    notifyListeners();
    await _loadFirstPage(album);
  }

  Future<void> _loadFirstPage(MediaAlbum album) async {
    final generation = ++_requestGeneration;
    try {
      final page = await _repository.loadPage(
        albumId: album.id,
        page: 0,
        size: pageSize,
        kinds: config.allowedKinds,
      );
      if (_disposed || generation != _requestGeneration) return;
      assets = page.assets;
      nextPage = page.nextPage;
      pagingState = page.hasMore
          ? GalleryPagingState.idle
          : GalleryPagingState.exhausted;
      contentState = assets.isEmpty
          ? GalleryContentState.empty
          : GalleryContentState.ready;
      notifyListeners();
    } catch (error, stackTrace) {
      debugPrint('Attachment gallery page load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (_disposed || generation != _requestGeneration) return;
      errorMessage = 'Could not load this album.';
      contentState = GalleryContentState.failed;
      notifyListeners();
    }
  }

  Future<void> loadNextPage() async {
    final album = selectedAlbum;
    if (album == null ||
        contentState != GalleryContentState.ready ||
        pagingState == GalleryPagingState.loading ||
        pagingState == GalleryPagingState.exhausted) {
      return;
    }
    final generation = _requestGeneration;
    pagingState = GalleryPagingState.loading;
    notifyListeners();
    try {
      final page = await _repository.loadPage(
        albumId: album.id,
        page: nextPage,
        size: pageSize,
        kinds: config.allowedKinds,
      );
      if (_disposed || generation != _requestGeneration) return;
      assets = page.assets;
      nextPage = page.nextPage;
      pagingState = page.hasMore
          ? GalleryPagingState.idle
          : GalleryPagingState.exhausted;
      notifyListeners();
    } catch (_) {
      if (_disposed || generation != _requestGeneration) return;
      pagingState = GalleryPagingState.failed;
      notifyListeners();
    }
  }

  Future<void> reconcile() async {
    final album = selectedAlbum;
    if (album == null ||
        !access.canRead ||
        refreshState != GalleryRefreshState.idle) {
      return;
    }
    final generation = _requestGeneration;
    refreshState = GalleryRefreshState.reconciling;
    notifyListeners();
    try {
      final page = await _repository.reconcileFirstPage(
        albumId: album.id,
        size: pageSize,
        kinds: config.allowedKinds,
      );
      if (_disposed || generation != _requestGeneration) return;
      assets = page.assets;
      newAssetCount = page.newAssetCount;
      contentState = assets.isEmpty
          ? GalleryContentState.empty
          : GalleryContentState.ready;
    } finally {
      if (!_disposed && generation == _requestGeneration) {
        refreshState = GalleryRefreshState.idle;
        notifyListeners();
      }
    }
  }

  void clearNewAssetNotice() {
    if (newAssetCount == 0) return;
    newAssetCount = 0;
    notifyListeners();
  }

  void toggleSelection(MediaAsset asset) {
    final index = _selectedIds.indexOf(asset.id);
    if (index >= 0) {
      _selectedIds.removeAt(index);
    } else if (config.selectionMode == AttachmentSelectionMode.single) {
      _selectedIds
        ..clear()
        ..add(asset.id);
    } else if (_selectedIds.length < config.maxSelectionCount) {
      _selectedIds.add(asset.id);
    }
    notifyListeners();
  }

  int selectionIndex(String assetId) => _selectedIds.indexOf(assetId) + 1;

  Future<void> manageLimitedAccess() async {
    await _repository.manageLimitedAccess(config.allowedKinds);
    await initialize();
  }

  Future<void> openSettings() => _repository.openSettings();

  @override
  void dispose() {
    _disposed = true;
    _changeSubscription?.cancel();
    if (_observing) {
      unawaited(_repository.stopObserving());
    }
    super.dispose();
  }
}
