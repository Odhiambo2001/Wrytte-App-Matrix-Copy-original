import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'package:wrytte/ui/media/video/wrytte_video_session.dart';

// =============================================================================
// AUTOPLAY CANDIDATE
// =============================================================================

class _AutoplayVideoCandidate {
  const _AutoplayVideoCandidate({
    required this.source,
    required this.visibleFraction,
    this.beforePlay,
  });

  final String source;
  final double visibleFraction;
  final Future<void> Function()? beforePlay;

  _AutoplayVideoCandidate copyWith({
    String? source,
    double? visibleFraction,
    Future<void> Function()? beforePlay,
  }) {
    return _AutoplayVideoCandidate(
      source: source ?? this.source,
      visibleFraction: visibleFraction ?? this.visibleFraction,
      beforePlay: beforePlay ?? this.beforePlay,
    );
  }
}

// =============================================================================
// CHAT VIDEO PLAYBACK VIEW MODEL
// =============================================================================

class ChatVideoPlaybackViewModel extends ChangeNotifier {
  ChatVideoPlaybackViewModel() {
    _session.addListener(_handleSessionChanged);
  }

  // ===========================================================================
  // NORMAL RECTANGULAR VIDEO
  // ===========================================================================

  static const double _normalPauseThreshold = 0.15;
  static const double _normalResumeThreshold = 0.60;

  // ===========================================================================
  // ROUND VIDEO AUTOPLAY
  //
  // Start high.
  // Stop low.
  //
  // This prevents tiny scrolling from constantly pausing/restarting playback.
  // ===========================================================================

  static const double _roundStartThreshold = 0.60;

  static const double _roundKeepPlayingThreshold = 0.15;

  static const double _roundSwitchThreshold = 0.72;

  static const double _roundSwitchAdvantage = 0.18;

  // ===========================================================================
  // ONE SHARED VIDEO SESSION
  // ===========================================================================

  final WrytteVideoSession _session = WrytteVideoSession();

  // ===========================================================================
  // NORMAL VIDEO VISIBILITY
  // ===========================================================================

  final Map<String, double> _normalVisibleFractions = <String, double>{};

  // ===========================================================================
  // ROUND VIDEO VISIBILITY
  // ===========================================================================

  final Map<String, _AutoplayVideoCandidate> _autoplayCandidates =
      <String, _AutoplayVideoCandidate>{};

  // ===========================================================================
  // EXPLICIT USER PAUSE
  //
  // Only used when the user manually pauses an expanded video.
  // ===========================================================================

  final Set<String> _autoplayUserPaused = <String>{};

  // ===========================================================================
  // ACTIVE VIDEO
  // ===========================================================================

  String? _activeMessageId;

  bool _activeIsAutoplay = false;

  // ===========================================================================
  // EXPANDED ROUND VIDEO
  // ===========================================================================

  String? _expandedAutoplayMessageId;

  // ===========================================================================
  // NORMAL VIDEO STATE
  // ===========================================================================

  bool _pausedByVisibility = false;

  bool _manualUserWantsPlayback = false;

  // ===========================================================================
  // AUTOPLAY SYNC
  // ===========================================================================

  bool _autoplaySyncRunning = false;

  bool _autoplaySyncPending = false;

  // ===========================================================================
  // ASYNC GENERATION
  // ===========================================================================

  int _generation = 0;

  bool _disposed = false;

  // ===========================================================================
  // PUBLIC STATE
  // ===========================================================================

  String? get activeMessageId => _activeMessageId;

  bool get hasActiveVideo => _activeMessageId != null;

  bool get muted => _session.muted;

  String? get errorMessage => _session.errorMessage;

  bool get isAutoplayActive => _activeIsAutoplay;

  String? get expandedAutoplayMessageId => _expandedAutoplayMessageId;

  bool isActive(String messageId) {
    return _activeMessageId == messageId;
  }

  bool isExpandedAutoplayMessage(String messageId) {
    return _expandedAutoplayMessageId == messageId;
  }

  bool isExplicitlyPaused(String messageId) {
    return _autoplayUserPaused.contains(messageId);
  }

  WrytteVideoPhase phaseFor(String messageId) {
    if (!isActive(messageId)) {
      return WrytteVideoPhase.idle;
    }

    return _session.phase;
  }

  VideoPlayerController? controllerFor(String messageId) {
    if (!isActive(messageId)) {
      return null;
    }

    final controller = _session.controller;

    if (controller == null || !controller.value.isInitialized) {
      return null;
    }

    return controller;
  }

  Duration durationFor(String messageId) {
    if (!isActive(messageId)) {
      return Duration.zero;
    }

    return _session.duration;
  }

  // ===========================================================================
  // NORMAL RECTANGULAR VIDEO
  // ===========================================================================

  Future<void> toggle({
    required String messageId,
    required String source,
    Future<void> Function()? beforePlay,
    bool loop = true,
  }) async {
    if (_disposed) {
      return;
    }

    final cleanId = messageId.trim();

    final cleanSource = source.trim();

    if (cleanId.isEmpty || cleanSource.isEmpty) {
      return;
    }

    // =========================================================================
    // SAME MANUAL VIDEO
    // =========================================================================

    if (_activeMessageId == cleanId && !_activeIsAutoplay) {
      final phase = _session.phase;

      if (phase == WrytteVideoPhase.playing) {
        _manualUserWantsPlayback = false;

        _pausedByVisibility = false;

        await _session.pause();

        _scheduleAutoplaySync();

        return;
      }

      if (phase == WrytteVideoPhase.initializing) {
        return;
      }

      if (beforePlay != null) {
        await beforePlay();
      }

      _manualUserWantsPlayback = true;

      final visibility = _normalVisibleFractions[cleanId] ?? 1.0;

      if (visibility < _normalResumeThreshold) {
        _pausedByVisibility = true;

        return;
      }

      _pausedByVisibility = false;

      if (phase == WrytteVideoPhase.completed) {
        await _session.replay();

        return;
      }

      if (phase == WrytteVideoPhase.paused || phase == WrytteVideoPhase.ready) {
        await _session.play();

        return;
      }

      return;
    }

    // =========================================================================
    // NEW NORMAL VIDEO
    // =========================================================================

    final request = ++_generation;

    if (beforePlay != null) {
      await beforePlay();
    }

    if (_disposed || request != _generation) {
      return;
    }

    _expandedAutoplayMessageId = null;

    _activeMessageId = cleanId;

    _activeIsAutoplay = false;

    _manualUserWantsPlayback = true;

    _pausedByVisibility = false;

    notifyListeners();

    final visibility = _normalVisibleFractions[cleanId] ?? 1.0;

    await _session.open(
      source: cleanSource,
      autoplay: visibility >= _normalResumeThreshold,
      loop: loop,
      startMuted: true,
    );

    if (visibility < _normalResumeThreshold) {
      _pausedByVisibility = true;
    }
  }

  // ===========================================================================
  // NORMAL VIDEO VISIBILITY
  // ===========================================================================

  Future<void> setVisibility({
    required String messageId,
    required double visibleFraction,
  }) async {
    if (_disposed) {
      return;
    }

    final fraction = visibleFraction.clamp(0.0, 1.0).toDouble();

    _normalVisibleFractions[messageId] = fraction;

    if (!isActive(messageId) || _activeIsAutoplay) {
      return;
    }

    if (fraction <= _normalPauseThreshold) {
      if (_session.isPlaying) {
        _pausedByVisibility = true;

        await _session.pause();
      }

      return;
    }

    if (fraction >= _normalResumeThreshold &&
        _pausedByVisibility &&
        _manualUserWantsPlayback) {
      _pausedByVisibility = false;

      await _session.play();
    }
  }

  // ===========================================================================
  // ROUND VIDEO VISIBILITY
  // ===========================================================================

  void setAutoplayVisibility({
    required String messageId,
    required String source,
    required double visibleFraction,
    Future<void> Function()? beforePlay,
  }) {
    if (_disposed) {
      return;
    }

    final id = messageId.trim();

    final cleanSource = source.trim();

    if (id.isEmpty || cleanSource.isEmpty) {
      return;
    }

    final fraction = visibleFraction.clamp(0.0, 1.0).toDouble();

    _autoplayCandidates[id] = _AutoplayVideoCandidate(
      source: cleanSource,
      visibleFraction: fraction,
      beforePlay: beforePlay,
    );

    // =========================================================================
    // If manually paused before, completely leaving the viewport resets that
    // explicit pause state.
    // =========================================================================

    if (fraction <= 0.01 && _expandedAutoplayMessageId != id) {
      _autoplayUserPaused.remove(id);
    }

    _scheduleAutoplaySync();
  }

  // ===========================================================================
  // UNREGISTER
  // ===========================================================================

  void unregisterAutoplayMessage(String messageId) {
    _autoplayCandidates.remove(messageId);

    _autoplayUserPaused.remove(messageId);

    if (_expandedAutoplayMessageId == messageId) {
      _expandedAutoplayMessageId = null;
    }

    if (_activeMessageId == messageId && _activeIsAutoplay) {
      _scheduleAutoplaySync();
    }
  }

  // ===========================================================================
  // OPEN / EXPAND ROUND VIDEO
  //
  // FINAL BEHAVIOR:
  //
  // Compact may be autoplaying.
  //
  // Tap compact:
  //
  // - same controller
  // - same playback position
  // - same mute state
  // - looping false
  // - preserve playback and position
  // ===========================================================================

  Future<void> expandAutoplayMessage({
    required String messageId,
    required String source,
    Future<void> Function()? beforePlay,
  }) async {
    if (_disposed) {
      return;
    }

    final id = messageId.trim();

    final cleanSource = source.trim();

    if (id.isEmpty || cleanSource.isEmpty) {
      return;
    }

    // =========================================================================
    // Lock ownership immediately.
    // =========================================================================

    _expandedAutoplayMessageId = id;

    // Opening paused is not the same thing as the USER manually pressing pause.
    _autoplayUserPaused.remove(id);

    final existing = _autoplayCandidates[id];

    _autoplayCandidates[id] = _AutoplayVideoCandidate(
      source: cleanSource,
      visibleFraction: existing?.visibleFraction ?? 1.0,
      beforePlay: beforePlay ?? existing?.beforePlay,
    );

    notifyListeners();

    // =========================================================================
    // SAME CURRENT COMPACT VIDEO
    //
    // Preserve position.
    //
    // Keep playing at that exact position.
    // =========================================================================

    if (_activeMessageId == id && _activeIsAutoplay && _session.isInitialized) {
      final controller = _session.controller;

      if (controller == null || !controller.value.isInitialized) {
        return;
      }

      try {
        await controller.setLooping(false);

        if (!controller.value.isPlaying) {
          await _session.play();
        }
      } catch (error) {
        debugPrint('Could not continue expanded round video: $error');
      }

      if (!_disposed) {
        notifyListeners();
      }

      return;
    }

    // =========================================================================
    // NOT ACTIVE
    //
    // Open the requested video directly in one-shot playback mode.
    // =========================================================================

    final request = ++_generation;

    if (beforePlay != null) {
      await beforePlay();
    }

    if (!_expandedRequestStillValid(id, request)) {
      return;
    }

    _activeMessageId = id;

    _activeIsAutoplay = true;

    _manualUserWantsPlayback = false;

    _pausedByVisibility = false;

    notifyListeners();

    await _session.open(
      source: cleanSource,

      autoplay: true,

      // Expanded mode plays once.
      loop: false,

      startMuted: true,
    );
  }

  // ===========================================================================
  // EXPANDED PLAY / PAUSE
  // ===========================================================================

  Future<void> toggleExpandedAutoplayPlayback(String messageId) async {
    if (_disposed ||
        _expandedAutoplayMessageId != messageId ||
        _activeMessageId != messageId ||
        !_activeIsAutoplay) {
      return;
    }

    final controller = _session.controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    // =========================================================================
    // PLAYING -> PAUSED
    // =========================================================================

    if (controller.value.isPlaying) {
      _autoplayUserPaused.add(messageId);

      await _session.pause();

      if (!_disposed) {
        notifyListeners();
      }

      return;
    }

    // =========================================================================
    // PAUSED -> PLAYING
    // =========================================================================

    _autoplayUserPaused.remove(messageId);

    try {
      await controller.setLooping(false);

      // If the user taps Play after already reaching the end, replay expanded
      // from the beginning.
      if (_controllerAtEnd(controller)) {
        await controller.seekTo(Duration.zero);
      }

      await _session.play();
    } catch (error) {
      debugPrint('Could not play expanded round video: $error');
    }

    if (!_disposed) {
      notifyListeners();
    }
  }

  // ===========================================================================
  // MANUAL COLLAPSE
  //
  // Closing before completion keeps the current playback position.
  //
  // Compact mode goes back to looping.
  //
  // Because expanded opens paused, a close before playing leaves that compact
  // video paused until normal autoplay visibility chooses it again.
  // ===========================================================================

  Future<void> collapseExpandedAutoplayMessage(String messageId) async {
    if (_disposed || _expandedAutoplayMessageId != messageId) {
      return;
    }

    _expandedAutoplayMessageId = null;

    if (_activeMessageId == messageId && _activeIsAutoplay) {
      final controller = _session.controller;

      if (controller != null && controller.value.isInitialized) {
        try {
          await controller.setLooping(true);
        } catch (error) {
          debugPrint('Could not restore compact round-video loop: $error');
        }
      }
    }

    if (!_disposed) {
      notifyListeners();
    }
  }

  // ===========================================================================
  // EXPANDED COMPLETION
  //
  // FINAL BEHAVIOR:
  //
  // Expanded reaches the end:
  //
  // 1. pause
  // 2. seek to zero
  // 3. restore compact looping
  // 4. clear manual-pause state
  // 5. autoplay again if still on screen
  // ===========================================================================

  Future<void> completeExpandedAutoplayMessage(String messageId) async {
    if (_disposed || _expandedAutoplayMessageId != messageId) {
      return;
    }

    ++_generation;

    _expandedAutoplayMessageId = null;

    // Completion returns this video to normal automatic compact behavior.
    _autoplayUserPaused.remove(messageId);

    if (_activeMessageId == messageId && _activeIsAutoplay) {
      final controller = _session.controller;

      if (controller != null && controller.value.isInitialized) {
        try {
          await controller.pause();

          await controller.seekTo(Duration.zero);

          await controller.setLooping(true);

          final visibility =
              _autoplayCandidates[messageId]?.visibleFraction ?? 0.0;

          // ===============================================================
          // The compact video was already the active video.
          //
          // We therefore use the KEEP threshold rather than requiring it to
          // satisfy the higher fresh-start threshold again.
          // ===============================================================

          if (visibility > _roundKeepPlayingThreshold) {
            await controller.play();
          }
        } catch (error) {
          debugPrint(
            'Could not restore compact autoplay after expanded completion: '
            '$error',
          );
        }
      }
    }

    if (!_disposed) {
      notifyListeners();
    }

    _scheduleAutoplaySync();
  }

  // ===========================================================================
  // COMPATIBILITY ROUND TOGGLE
  // ===========================================================================

  Future<void> toggleAutoplayMessage({
    required String messageId,
    required String source,
    Future<void> Function()? beforePlay,
  }) async {
    if (_disposed) {
      return;
    }

    if (_expandedAutoplayMessageId == messageId) {
      await toggleExpandedAutoplayPlayback(messageId);

      return;
    }

    final id = messageId.trim();

    final cleanSource = source.trim();

    if (id.isEmpty || cleanSource.isEmpty) {
      return;
    }

    if (_activeMessageId == id && _activeIsAutoplay) {
      if (_session.isPlaying) {
        _autoplayUserPaused.add(id);

        await _session.pause();

        return;
      }

      _autoplayUserPaused.remove(id);

      if (beforePlay != null) {
        await beforePlay();
      }

      await _session.play();

      return;
    }

    _autoplayUserPaused.remove(id);

    final existing = _autoplayCandidates[id];

    _autoplayCandidates[id] = _AutoplayVideoCandidate(
      source: cleanSource,
      visibleFraction: existing?.visibleFraction ?? 1.0,
      beforePlay: beforePlay ?? existing?.beforePlay,
    );

    await _openAutoplayCandidate(id, _autoplayCandidates[id]!);
  }

  // ===========================================================================
  // AUTOPLAY QUEUE
  // ===========================================================================

  void _scheduleAutoplaySync() {
    if (_disposed) {
      return;
    }

    if (_autoplaySyncRunning) {
      _autoplaySyncPending = true;

      return;
    }

    _autoplaySyncRunning = true;

    Future<void>(() async {
      try {
        do {
          _autoplaySyncPending = false;

          await _syncAutoplay();
        } while (_autoplaySyncPending && !_disposed);
      } finally {
        _autoplaySyncRunning = false;
      }
    });
  }

  // ===========================================================================
  // AUTOPLAY POLICY
  // ===========================================================================

  Future<void> _syncAutoplay() async {
    if (_disposed) {
      return;
    }

    // =========================================================================
    // EXPANDED VIDEO OWNS THE PLAYER.
    //
    // While expanded, visibility cannot automatically start another video.
    // =========================================================================

    if (_expandedAutoplayMessageId != null) {
      return;
    }

    // =========================================================================
    // MANUAL RECTANGULAR VIDEO OWNS PLAYBACK.
    // =========================================================================

    if (!_activeIsAutoplay &&
        _activeMessageId != null &&
        _manualUserWantsPlayback) {
      return;
    }

    // =========================================================================
    // CURRENT ROUND VIDEO
    // =========================================================================

    if (_activeIsAutoplay && _activeMessageId != null) {
      final currentId = _activeMessageId!;

      final current = _autoplayCandidates[currentId];

      final currentFraction = current?.visibleFraction ?? 0.0;

      final explicitlyPaused = _autoplayUserPaused.contains(currentId);

      // =======================================================================
      // USER MANUALLY PAUSED.
      //
      // Never resume this same video automatically.
      //
      // But if the user scrolls to another round video, that other candidate is
      // still allowed to take over.
      // =======================================================================

      if (explicitlyPaused) {
        final next = _bestAutoplayCandidate(
          minimumVisibleFraction: _roundStartThreshold,
          excludingMessageId: currentId,
        );

        if (next != null) {
          await _openAutoplayCandidate(next.$1, next.$2);
        }

        return;
      }

      // =======================================================================
      // CURRENT VIDEO IS STILL SUFFICIENTLY VISIBLE.
      //
      // Keep it alive.
      // =======================================================================

      if (currentFraction > _roundKeepPlayingThreshold) {
        final challenger = _bestAutoplayCandidate(
          minimumVisibleFraction: _roundSwitchThreshold,
          excludingMessageId: currentId,
        );

        if (challenger == null) {
          await _ensureCompactRoundVideoPlaying(currentId);

          return;
        }

        final challengerFraction = challenger.$2.visibleFraction;

        if (challengerFraction < currentFraction + _roundSwitchAdvantage) {
          await _ensureCompactRoundVideoPlaying(currentId);

          return;
        }

        await _openAutoplayCandidate(challenger.$1, challenger.$2);

        return;
      }
    }

    // =========================================================================
    // CURRENT VIDEO IS ALMOST OFF-SCREEN OR NOTHING ACTIVE.
    // =========================================================================

    final best = _bestAutoplayCandidate(
      minimumVisibleFraction: _roundStartThreshold,
    );

    if (best == null) {
      if (_activeIsAutoplay && _session.isPlaying) {
        await _session.pause();
      }

      return;
    }

    final bestId = best.$1;

    // =========================================================================
    // SAME ACTIVE VIDEO
    // =========================================================================

    if (_activeIsAutoplay && _activeMessageId == bestId) {
      if (!_autoplayUserPaused.contains(bestId)) {
        await _ensureCompactRoundVideoPlaying(bestId);
      }

      return;
    }

    // =========================================================================
    // DIFFERENT VIDEO
    // =========================================================================

    await _openAutoplayCandidate(bestId, best.$2);
  }

  // ===========================================================================
  // ENSURE COMPACT ROUND VIDEO IS PLAYING
  // ===========================================================================

  Future<void> _ensureCompactRoundVideoPlaying(String messageId) async {
    if (_disposed ||
        _expandedAutoplayMessageId != null ||
        _activeMessageId != messageId ||
        !_activeIsAutoplay ||
        _autoplayUserPaused.contains(messageId) ||
        !_session.isInitialized) {
      return;
    }

    final controller = _session.controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      if (!controller.value.isLooping) {
        await controller.setLooping(true);
      }

      if (_expandedAutoplayMessageId != null) {
        return;
      }

      if (!controller.value.isPlaying) {
        if (_controllerAtEnd(controller)) {
          await controller.seekTo(Duration.zero);
        }

        await _session.play();
      }
    } catch (error) {
      debugPrint('Could not keep compact round video playing: $error');
    }
  }

  // ===========================================================================
  // BEST CANDIDATE
  // ===========================================================================

  (String, _AutoplayVideoCandidate)? _bestAutoplayCandidate({
    required double minimumVisibleFraction,
    String? excludingMessageId,
  }) {
    String? bestId;

    _AutoplayVideoCandidate? bestCandidate;

    for (final entry in _autoplayCandidates.entries) {
      final id = entry.key;

      final candidate = entry.value;

      if (id == excludingMessageId) {
        continue;
      }

      if (_autoplayUserPaused.contains(id)) {
        continue;
      }

      if (candidate.visibleFraction < minimumVisibleFraction) {
        continue;
      }

      if (bestCandidate == null ||
          candidate.visibleFraction > bestCandidate.visibleFraction) {
        bestId = id;

        bestCandidate = candidate;
      }
    }

    if (bestId == null || bestCandidate == null) {
      return null;
    }

    return (bestId, bestCandidate);
  }

  // ===========================================================================
  // OPEN COMPACT ROUND VIDEO
  // ===========================================================================

  Future<void> _openAutoplayCandidate(
    String id,
    _AutoplayVideoCandidate candidate,
  ) async {
    if (_disposed || _expandedAutoplayMessageId != null) {
      return;
    }

    final request = ++_generation;

    if (candidate.beforePlay != null) {
      await candidate.beforePlay!();
    }

    if (_disposed ||
        request != _generation ||
        _expandedAutoplayMessageId != null) {
      return;
    }

    _autoplayUserPaused.remove(id);

    _activeMessageId = id;

    _activeIsAutoplay = true;

    _manualUserWantsPlayback = false;

    _pausedByVisibility = false;

    notifyListeners();

    await _session.open(
      source: candidate.source,

      // Compact round videos autoplay.
      autoplay: true,

      // Compact round videos loop.
      loop: true,

      startMuted: true,
    );
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  bool _expandedRequestStillValid(String id, int request) {
    return !_disposed &&
        request == _generation &&
        _expandedAutoplayMessageId == id;
  }

  bool _controllerAtEnd(VideoPlayerController controller) {
    if (!controller.value.isInitialized) {
      return false;
    }

    final duration = controller.value.duration;

    if (duration <= Duration.zero) {
      return false;
    }

    return controller.value.isCompleted ||
        controller.value.position >=
            duration - const Duration(milliseconds: 60);
  }

  // ===========================================================================
  // MUTE
  // ===========================================================================

  Future<void> toggleMute(String messageId) async {
    if (!isActive(messageId)) {
      return;
    }

    await _session.toggleMute();
  }

  // ===========================================================================
  // GENERAL PAUSE
  // ===========================================================================

  Future<void> pause() async {
    if (_activeIsAutoplay) {
      final id = _activeMessageId;

      if (id != null) {
        _autoplayUserPaused.add(id);
      }
    } else {
      _manualUserWantsPlayback = false;

      _pausedByVisibility = false;
    }

    await _session.pause();

    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> pauseIfActive(String messageId) async {
    if (!isActive(messageId)) {
      return;
    }

    await pause();
  }

  // ===========================================================================
  // STOP
  // ===========================================================================

  Future<void> stopAndClear() async {
    if (_disposed) {
      return;
    }

    ++_generation;

    _expandedAutoplayMessageId = null;

    _activeMessageId = null;

    _activeIsAutoplay = false;

    _manualUserWantsPlayback = false;

    _pausedByVisibility = false;

    _autoplayUserPaused.clear();

    await _session.close();

    if (!_disposed) {
      notifyListeners();
    }
  }

  // ===========================================================================
  // SESSION
  // ===========================================================================

  void _handleSessionChanged() {
    if (_disposed) {
      return;
    }

    notifyListeners();
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  @override
  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed = true;

    ++_generation;

    _session.removeListener(_handleSessionChanged);

    _session.dispose();

    super.dispose();
  }
}
