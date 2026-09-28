import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';

enum ChatMediaEditorLoadState {
  idle,
  loading,
  ready,
  failed,
}

class ChatMediaEditorViewModel extends ChangeNotifier {
  ChatMediaEditorViewModel({
    required this.asset,
    required MediaLibraryRepository repository,
    Future<String?>? prestartedSourcePath,
  }) : _repository = repository,
       _prestartedSourcePath = prestartedSourcePath;

  final MediaAsset asset;
  final MediaLibraryRepository _repository;

  /// This future may already be running before the editor State is created.
  ///
  /// That lets media-file resolution overlap with route creation instead of
  /// waiting until the editor's first rendered frame.
  final Future<String?>? _prestartedSourcePath;

  ChatMediaEditorLoadState _loadState =
      ChatMediaEditorLoadState.idle;

  String? _sourcePath;
  String? _errorMessage;

  bool _disposed = false;
  bool _prestartedSourcePathConsumed = false;

  int _loadGeneration = 0;

  ChatMediaEditorLoadState get loadState =>
      _loadState;

  String? get sourcePath =>
      _sourcePath;

  String? get errorMessage =>
      _errorMessage;

  bool get isReady =>
      _loadState ==
          ChatMediaEditorLoadState.ready &&
      _sourcePath != null;

  Future<void> initialize() {
    return _load(
      allowPrestartedFuture: true,
    );
  }

  Future<void> retry() async {
    if (_disposed ||
        _loadState ==
            ChatMediaEditorLoadState.loading) {
      return;
    }

    _sourcePath = null;
    _errorMessage = null;
    _loadState =
        ChatMediaEditorLoadState.idle;

    _notifySafely();

    await _load(
      allowPrestartedFuture: false,
    );
  }

  Future<void> _load({
    required bool allowPrestartedFuture,
  }) async {
    if (_disposed ||
        _loadState ==
            ChatMediaEditorLoadState.loading ||
        _loadState ==
            ChatMediaEditorLoadState.ready) {
      return;
    }

    final generation =
        ++_loadGeneration;

    _loadState =
        ChatMediaEditorLoadState.loading;

    _errorMessage = null;

    _notifySafely();

    try {
      final Future<String?> pathFuture;

      if (allowPrestartedFuture &&
          !_prestartedSourcePathConsumed &&
          _prestartedSourcePath != null) {
        _prestartedSourcePathConsumed =
            true;

        pathFuture =
            _prestartedSourcePath;
      } else {
        pathFuture =
            _repository.loadFilePath(
          asset.id,
        );
      }

      final path =
          await pathFuture;

      if (_disposed ||
          generation !=
              _loadGeneration) {
        return;
      }

      if (path == null ||
          path.trim().isEmpty) {
        _fail(
          'This photo could not be opened.',
          generation,
        );

        return;
      }

      final normalizedPath =
          path.trim();

      // The repository is responsible for materializing gallery assets.
      // We only perform a cheap final filesystem check here instead of
      // reading the entire original image into Dart memory.
      final exists =
          await File(
        normalizedPath,
      ).exists();

      if (_disposed ||
          generation !=
              _loadGeneration) {
        return;
      }

      if (!exists) {
        _fail(
          'This photo is no longer available on this device.',
          generation,
        );

        return;
      }

      _sourcePath =
          normalizedPath;

      _loadState =
          ChatMediaEditorLoadState.ready;

      _notifySafely();
    } catch (
      error,
      stackTrace
    ) {
      debugPrint(
        'Chat media editor source loading failed: $error',
      );

      debugPrintStack(
        stackTrace:
            stackTrace,
      );

      if (_disposed ||
          generation !=
              _loadGeneration) {
        return;
      }

      _fail(
        'This photo could not be opened.',
        generation,
      );
    }
  }

  void _fail(
    String message,
    int generation,
  ) {
    if (_disposed ||
        generation !=
            _loadGeneration) {
      return;
    }

    _sourcePath = null;
    _errorMessage = message;

    _loadState =
        ChatMediaEditorLoadState.failed;

    _notifySafely();
  }

  void _notifySafely() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;

    // Invalidate any outstanding async operation.
    _loadGeneration++;

    super.dispose();
  }
}