import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';
import 'package:wrytte/services/attachment_local_store.dart';

enum WrytteVideoPhase {
  idle,
  initializing,
  ready,
  playing,
  paused,
  completed,
  failed,
}

/// Owns exactly one native video player session.
///
/// This class is intentionally generic and has no knowledge of:
///
/// - chat messages
/// - message IDs
/// - captions
/// - message bubbles
/// - delivery status
///
/// Chat-specific coordination belongs in ChatVideoPlaybackViewModel.
class WrytteVideoSession extends ChangeNotifier
    with WidgetsBindingObserver {
  WrytteVideoSession() {
    WidgetsBinding.instance.addObserver(this);
  }

  VideoPlayerController? _controller;

  String? _source;

  WrytteVideoPhase _phase =
      WrytteVideoPhase.idle;

  bool _muted = true;

  String? _errorMessage;

  int _generation = 0;

  bool _disposed = false;

  // ===========================================================================
  // Public state
  // ===========================================================================

  VideoPlayerController? get controller =>
      _controller;

  String? get source =>
      _source;

  WrytteVideoPhase get phase =>
      _phase;

  bool get muted =>
      _muted;

  String? get errorMessage =>
      _errorMessage;

  bool get isInitialized {
    final controller =
        _controller;

    return controller != null &&
        controller.value.isInitialized;
  }

  bool get isPlaying {
    final controller =
        _controller;

    return controller != null &&
        controller.value.isInitialized &&
        controller.value.isPlaying;
  }

  Duration get duration {
    final controller =
        _controller;

    if (controller == null ||
        !controller.value.isInitialized) {
      return Duration.zero;
    }

    return controller.value.duration;
  }

  Size get videoSize {
    final controller =
        _controller;

    if (controller == null ||
        !controller.value.isInitialized) {
      return Size.zero;
    }

    return controller.value.size;
  }

  double? get aspectRatio {
    final size =
        videoSize;

    if (size.width <= 0 ||
        size.height <= 0) {
      return null;
    }

    return size.width /
        size.height;
  }

  // ===========================================================================
  // Open
  // ===========================================================================

  Future<void> open({
    required String source,
    bool autoplay = true,
    bool loop = false,
    bool startMuted = true,
  }) async {
    final cleanSource =
        source.trim();

    if (_disposed ||
        cleanSource.isEmpty) {
      return;
    }

    final requestGeneration =
        ++_generation;

    await _releaseController();

    if (_disposed ||
        requestGeneration !=
            _generation) {
      return;
    }

    _source =
        cleanSource;

    _muted =
        startMuted;

    _errorMessage =
        null;

    _setPhase(
      WrytteVideoPhase.initializing,
    );

    VideoPlayerController? controller;

    try {
      // Matrix media download URLs are protected. ExoPlayer's network
      // controller cannot attach the Matrix access token, so handing the URL
      // directly to it produces HTTP 401 and a silent full-screen failure.
      // Resolve remote media through the authenticated attachment store first
      // and give the native player a local file instead.
      final playbackSource =
          cleanSource.startsWith('http')
              ? (await AttachmentLocalStore.instance
                    .ensureComplete(
                      source: cleanSource,
                      fileName: 'video.mp4',
                    ))
                    .file
                    .path
              : cleanSource;

      if (_disposed ||
          requestGeneration != _generation) {
        return;
      }

      controller =
          _createController(
        playbackSource,
      );

      _controller =
          controller;

      controller.addListener(
        _handleControllerChanged,
      );

      await controller.initialize();

      if (_disposed ||
          requestGeneration !=
              _generation ||
          !identical(
            controller,
            _controller,
          )) {
        controller.removeListener(
          _handleControllerChanged,
        );

        await controller.dispose();

        return;
      }

      await controller.setLooping(
        loop,
      );

      await controller.setVolume(
        startMuted
            ? 0.0
            : 1.0,
      );

      _setPhase(
        WrytteVideoPhase.ready,
      );

      if (autoplay) {
        await controller.play();
      }
    } catch (error) {
      if (_disposed ||
          requestGeneration !=
              _generation) {
        return;
      }

      _errorMessage =
          error.toString();

      if (controller != null) {
        controller.removeListener(
          _handleControllerChanged,
        );

        if (identical(
          controller,
          _controller,
        )) {
          _controller =
              null;
        }

        try {
          await controller.dispose();
        } catch (_) {
          // Best-effort cleanup.
        }
      }

      _setPhase(
        WrytteVideoPhase.failed,
      );
    }
  }

  // ===========================================================================
  // Playback
  // ===========================================================================

  Future<void> toggle() async {
    if (isPlaying) {
      await pause();

      return;
    }

    await play();
  }

  Future<void> play() async {
    final controller =
        _controller;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    if (controller.value.isCompleted ||
        _phase ==
            WrytteVideoPhase.completed) {
      await controller.seekTo(
        Duration.zero,
      );
    }

    await controller.play();
  }

  Future<void> pause() async {
    final controller =
        _controller;

    if (controller == null ||
        !controller.value.isInitialized ||
        !controller.value.isPlaying) {
      return;
    }

    await controller.pause();
  }

  Future<void> replay() async {
    final controller =
        _controller;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    await controller.seekTo(
      Duration.zero,
    );

    await controller.play();
  }

  // ===========================================================================
  // Audio
  // ===========================================================================

  Future<void> toggleMute() async {
    final controller =
        _controller;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    final nextMuted =
        !_muted;

    await controller.setVolume(
      nextMuted
          ? 0.0
          : 1.0,
    );

    if (_disposed) {
      return;
    }

    _muted =
        nextMuted;

    notifyListeners();
  }

  // ===========================================================================
  // Close
  // ===========================================================================

  Future<void> close() async {
    if (_disposed) {
      return;
    }

    ++_generation;

    await _releaseController();

    _source =
        null;

    _muted =
        true;

    _errorMessage =
        null;

    _setPhase(
      WrytteVideoPhase.idle,
    );
  }

  Future<void> _releaseController() async {
    final controller =
        _controller;

    _controller =
        null;

    if (controller == null) {
      return;
    }

    controller.removeListener(
      _handleControllerChanged,
    );

    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    } catch (_) {
      // Best effort.
    }

    try {
      await controller.dispose();
    } catch (_) {
      // Video teardown should never crash the chat.
    }
  }

  // ===========================================================================
  // Native controller factory
  // ===========================================================================

  VideoPlayerController _createController(
    String source,
  ) {
    final options =
        VideoPlayerOptions(
      // Don't mix chat-video audio with another player.
      mixWithOthers:
          false,

      // Wrytte chat video should not continue when backgrounded.
      allowBackgroundPlayback:
          false,

      preventsDisplaySleepDuringVideoPlayback:
          true,
    );

    // -------------------------------------------------------------------------
    // Flutter asset
    // -------------------------------------------------------------------------

    if (source.startsWith(
      'assets/',
    )) {
      return VideoPlayerController.asset(
        source,
        videoPlayerOptions:
            options,
      );
    }

    final uri =
        Uri.tryParse(
      source,
    );

    // -------------------------------------------------------------------------
    // Network
    // -------------------------------------------------------------------------

    if (uri != null &&
        (
          uri.scheme ==
                  'https' ||
              uri.scheme ==
                  'http'
        )) {
      return VideoPlayerController.networkUrl(
        uri,
        videoPlayerOptions:
            options,
      );
    }

    // -------------------------------------------------------------------------
    // Android content URI
    // -------------------------------------------------------------------------

    if (uri != null &&
        uri.scheme ==
            'content') {
      return VideoPlayerController.contentUri(
        uri,
        videoPlayerOptions:
            options,
      );
    }

    // -------------------------------------------------------------------------
    // file:// URI
    // -------------------------------------------------------------------------

    if (uri != null &&
        uri.scheme ==
            'file') {
      return VideoPlayerController.file(
        File(
          uri.toFilePath(),
        ),
        videoPlayerOptions:
            options,
      );
    }

    // -------------------------------------------------------------------------
    // Normal local filesystem path
    // -------------------------------------------------------------------------

    return VideoPlayerController.file(
      File(
        source,
      ),
      videoPlayerOptions:
          options,
    );
  }

  // ===========================================================================
  // Native value listener
  //
  // VideoPlayerController can notify very frequently while the playhead moves.
  // We deliberately notify Wrytte only when the meaningful phase changes.
  // ===========================================================================

  void _handleControllerChanged() {
    if (_disposed) {
      return;
    }

    final controller =
        _controller;

    if (controller == null) {
      return;
    }

    final value =
        controller.value;

    if (value.hasError) {
      _errorMessage =
          value.errorDescription;

      _setPhase(
        WrytteVideoPhase.failed,
      );

      return;
    }

    if (!value.isInitialized) {
      return;
    }

    if (value.isCompleted &&
        !value.isLooping) {
      _setPhase(
        WrytteVideoPhase.completed,
      );

      return;
    }

    if (value.isPlaying) {
      _setPhase(
        WrytteVideoPhase.playing,
      );

      return;
    }

    if (_phase ==
            WrytteVideoPhase.playing ||
        _phase ==
            WrytteVideoPhase.ready) {
      _setPhase(
        WrytteVideoPhase.paused,
      );
    }
  }

  void _setPhase(
    WrytteVideoPhase next,
  ) {
    if (_disposed ||
        next == _phase) {
      return;
    }

    _phase =
        next;

    notifyListeners();
  }

  // ===========================================================================
  // App lifecycle
  // ===========================================================================

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // Never leave chat video playing behind another app.
        unawaited(
          pause(),
        );

      case AppLifecycleState.detached:
        unawaited(
          close(),
        );

      case AppLifecycleState.resumed:
        // Deliberately do nothing.
        //
        // Returning to Wrytte should NOT automatically restart sound/video.
        break;
    }
  }

  // ===========================================================================
  // Dispose
  // ===========================================================================

  @override
  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed =
        true;

    ++_generation;

    WidgetsBinding.instance.removeObserver(
      this,
    );

    final controller =
        _controller;

    _controller =
        null;

    if (controller != null) {
      controller.removeListener(
        _handleControllerChanged,
      );

      unawaited(
        controller.dispose(),
      );
    }

    super.dispose();
  }
}
