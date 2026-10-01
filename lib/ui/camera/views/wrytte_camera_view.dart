import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/domain/models/camera_capabilities.dart';
import 'package:wrytte/domain/models/camera_capture_result.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';
import 'package:wrytte/domain/models/camera_session_state.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';
import 'package:wrytte/ui/camera/models/camera_route_result.dart';
import 'package:wrytte/ui/camera/view_models/camera_view_model.dart';
import 'package:wrytte/ui/camera/widgets/camera_control_button.dart';
import 'package:wrytte/ui/camera/widgets/camera_shutter_button.dart';
import 'package:wrytte/ui/camera/widgets/wrytte_camera_preview.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

typedef CameraCaptureReviewer =
    Future<CameraCaptureResult?> Function(
      BuildContext context,
      CameraCaptureResult capture,
    );

class WrytteCameraView extends StatefulWidget {
  const WrytteCameraView({
    super.key,
    required this.repository,
    required this.config,
    required this.keepSessionAliveOnExit,
    required this.routeAnimation,
    this.galleryThumbnail,
    this.returnToGallery = false,
    this.captureReviewer,
  });

  final CameraRepository repository;
  final CameraSessionConfig config;
  final bool keepSessionAliveOnExit;
  final Animation<double> routeAnimation;
  final Uint8List? galleryThumbnail;
  final bool returnToGallery;
  final CameraCaptureReviewer? captureReviewer;

  @override
  State<WrytteCameraView> createState() => _WrytteCameraViewState();
}

class _WrytteCameraViewState extends State<WrytteCameraView> {
  late final CameraViewModel _model;
  Offset? _focusPoint;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _model = CameraViewModel(
      widget.repository,
      config: widget.config,
      keepSessionAliveOnExit: widget.keepSessionAliveOnExit,
    )..addListener(_refresh);
    unawaited(_model.initialize());
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _model.removeListener(_refresh);
    unawaited(_model.release());
    _model.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _capture() async {
    try {
      final capture = await _model.pressShutter();
      if (!mounted || capture == null) return;
      final reviewed = widget.captureReviewer == null
          ? capture
          : await widget.captureReviewer!(context, capture);
      if (!mounted || reviewed == null) return;
      Navigator.of(context).pop(CameraRouteResult.capture(reviewed));
    } catch (_) {
      // The repository publishes a user-facing failure state.
    }
  }

  void _handleFocus(TapUpDetails details, Size size) {
    if (!_model.state.isReady || size.width <= 0 || size.height <= 0) return;
    final local = details.localPosition;
    setState(() => _focusPoint = local);
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    final normalized = _previewPoint(local, size);
    unawaited(_model.focus(normalized.dx, normalized.dy));
  }

  Offset _previewPoint(Offset point, Size viewport) {
    var aspect =
        _model.state.previewAspectRatio ?? (viewport.width / viewport.height);
    final viewportIsLandscape = viewport.width > viewport.height;
    if (viewportIsLandscape && aspect < 1) aspect = 1 / aspect;
    if (!viewportIsLandscape && aspect > 1) aspect = 1 / aspect;
    final scale = math.max(viewport.width / aspect, viewport.height);
    final renderedWidth = aspect * scale;
    final renderedHeight = scale;
    final left = (viewport.width - renderedWidth) / 2;
    final top = (viewport.height - renderedHeight) / 2;
    return Offset(
      ((point.dx - left) / renderedWidth).clamp(0, 1),
      ((point.dy - top) / renderedHeight).clamp(0, 1),
    );
  }

  Future<void> _handleBack() async {
    if (_blocksBackNavigation(_model.state.status)) return;
    Navigator.of(context).pop();
  }

  bool _blocksBackNavigation(CameraSessionStatus status) => switch (status) {
    CameraSessionStatus.capturing ||
    CameraSessionStatus.recordingStarting ||
    CameraSessionStatus.recording ||
    CameraSessionStatus.recordingPaused ||
    CameraSessionStatus.recordingStopping => true,
    _ => false,
  };

  void _returnToGallery() {
    if (!widget.returnToGallery) return;
    Navigator.of(context).pop(const CameraRouteResult.returnToGallery());
  }

  @override
  Widget build(BuildContext context) {
    final state = _model.state;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final controlsAnimation = disableAnimations
        ? const AlwaysStoppedAnimation<double>(1)
        : CurvedAnimation(
            parent: widget.routeAnimation,
            curve: const Interval(.42, 1, curve: Curves.easeOutCubic),
            reverseCurve: const Interval(0, .62, curve: Curves.easeInCubic),
          );
    return PopScope(
      canPop: !_blocksBackNavigation(state.status),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF050608),
          extendBody: true,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) => _model.beginZoomGesture(),
                onScaleUpdate: (details) {
                  if (details.pointerCount > 1) {
                    _model.updateZoomGesture(details.scale);
                  }
                },
                onScaleEnd: (_) => unawaited(_model.endZoomGesture()),
                onDoubleTap: () => unawaited(_model.switchCamera()),
                onTapUp: (details) => _handleFocus(details, size),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: WrytteCameraPreview(
                        repository: widget.repository,
                        state: state,
                      ),
                    ),
                    const IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0, .2, .7, 1],
                            colors: [
                              Color(0x8A000000),
                              Colors.transparent,
                              Colors.transparent,
                              Color(0xB8000000),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_focusPoint case final point?)
                      Positioned(
                        left: point.dx - 24,
                        top: point.dy - 24,
                        child: IgnorePointer(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 1.35, end: 1),
                            duration: disableAnimations
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            curve: Curves.easeOutBack,
                            builder: (_, scale, child) =>
                                Transform.scale(scale: scale, child: child),
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFF5F5F5),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    AnimatedBuilder(
                      animation: widget.routeAnimation,
                      child: _CameraChrome(
                        model: _model,
                        galleryThumbnail: widget.galleryThumbnail,
                        onBack: _handleBack,
                        onReturnToGallery: widget.returnToGallery
                            ? _returnToGallery
                            : null,
                        onCapture: _capture,
                      ),
                      builder: (context, child) => IgnorePointer(
                        ignoring: widget.routeAnimation.value < .9,
                        child: Opacity(
                          opacity: controlsAnimation.value,
                          child: child,
                        ),
                      ),
                    ),
                    if (state.status == CameraSessionStatus.opening)
                      FadeTransition(
                        opacity: disableAnimations
                            ? const AlwaysStoppedAnimation<double>(1)
                            : CurvedAnimation(
                                parent: widget.routeAnimation,
                                curve: const Interval(
                                  .78,
                                  1,
                                  curve: Curves.easeOut,
                                ),
                              ),
                        child: const IgnorePointer(
                          child: Center(
                            child: SizedBox.square(
                              dimension: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Color(0xFFF5F5F5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (state.status == CameraSessionStatus.failure)
                      _CameraFailureView(
                        message:
                            state.failure?.message ??
                            'The camera could not be started.',
                        onRetry: () => unawaited(_model.initialize()),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CameraChrome extends StatelessWidget {
  const _CameraChrome({
    required this.model,
    required this.galleryThumbnail,
    required this.onBack,
    required this.onReturnToGallery,
    required this.onCapture,
  });

  final CameraViewModel model;
  final Uint8List? galleryThumbnail;
  final VoidCallback onBack;
  final VoidCallback? onReturnToGallery;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final state = model.state;
    final recording = state.isRecording;
    final flashAvailable = state.capabilities?.flashAvailable == true;
    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          PositionedDirectional(
            top: 8,
            // The control remains a full 52dp target; the smaller chevron is
            // optically aligned with the visible left edge of the gallery tile.
            start: 8,
            child: CameraControlButton(
              semanticLabel: 'Back',
              onPressed: recording ? null : onBack,
              svgAsset: 'assets/svg/ic--round-arrow-back-ios.svg',
              iconSize: 25,
              size: 52,
            ),
          ),
          PositionedDirectional(
            top: 8,
            end: 22,
            child: CameraControlButton(
              semanticLabel: flashAvailable
                  ? 'Change flash mode'
                  : 'Flash unavailable',
              onPressed: recording || !flashAvailable
                  ? null
                  : () => unawaited(model.cycleFlash()),
              svgAsset: state.flashMode == WrytteFlashMode.off
                  ? 'assets/svg/Flash off icon.svg'
                  : 'assets/svg/Flash on icon .svg',
              iconSize: 27,
              size: 52,
            ),
          ),
          if (recording)
            Positioned(
              top: 18,
              left: 0,
              right: 0,
              child: Center(
                child: _RecordingClock(duration: model.recordingDuration),
              ),
            ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final safeBottom = MediaQuery.paddingOf(context).bottom;
                final lowerRowBottom = safeBottom + 11;
                final shutterBottom = safeBottom + 76;
                final shutterCenterX = constraints.maxWidth / 2;
                return Stack(
                  alignment: Alignment.bottomCenter,
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      bottom: shutterBottom,
                      child: CameraShutterButton(
                        videoMode: model.videoMode,
                        recording: recording,
                        enabled: state.isReady || recording,
                        onPressed: onCapture,
                      ),
                    ),
                    Positioned(
                      left: shutterCenterX + 62,
                      bottom: shutterBottom + 25,
                      child: _ZoomButton(
                        state: state,
                        displayZoom: model.displayZoom,
                        onPressed: model.setZoom,
                      ),
                    ),
                    if (onReturnToGallery != null)
                      PositionedDirectional(
                        start: 22,
                        bottom: lowerRowBottom,
                        child: SizedBox.square(
                          dimension: 48,
                          child: _GalleryButton(
                            thumbnail: galleryThumbnail,
                            onPressed: onReturnToGallery!,
                          ),
                        ),
                      ),
                    if (model.showModePicker && !recording)
                      Positioned(
                        bottom: safeBottom + 16,
                        child: _CaptureModePicker(model: model),
                      ),
                    if (!recording)
                      PositionedDirectional(
                        end: 22,
                        bottom: safeBottom + 9,
                        child: CameraControlButton(
                          semanticLabel: 'Switch camera',
                          onPressed: state.isReady
                              ? () => unawaited(model.switchCamera())
                              : null,
                          svgAsset: 'assets/svg/Flip camera icon .svg',
                          iconSize: 28,
                          size: 52,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureModePicker extends StatelessWidget {
  const _CaptureModePicker({required this.model});
  final CameraViewModel model;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .32),
        borderRadius: BorderRadius.circular(22),
      ),
      child: SizedBox(
        width: 138,
        height: 38,
        child: Row(
          children: [
            _ModeButton(
              label: 'PHOTO',
              selected: !model.videoMode,
              onPressed: model.selectPhotoMode,
            ),
            _ModeButton(
              label: 'VIDEO',
              selected: model.videoMode,
              onPressed: model.selectVideoMode,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Expanded(
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(48, 38),
        foregroundColor: selected
            ? WrytteColors.primary
            : const Color(0xFFF5F5F5),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _GalleryButton extends StatelessWidget {
  const _GalleryButton({required this.thumbnail, required this.onPressed});
  final Uint8List? thumbnail;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Return to gallery',
      child: Material(
        color: const Color(0x24FFFFFF),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          splashFactory: NoSplash.splashFactory,
          child: thumbnail == null
              ? const Icon(
                  Icons.photo_library_outlined,
                  color: Color(0xFFF5F5F5),
                  size: 25,
                )
              : Image.memory(
                  thumbnail!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                ),
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.state,
    required this.displayZoom,
    required this.onPressed,
  });
  final CameraSessionState state;
  final double displayZoom;
  final Future<void> Function(double) onPressed;

  @override
  Widget build(BuildContext context) {
    final capabilities = state.capabilities;
    if (capabilities == null) return const SizedBox.shrink();
    final choices =
        <double>{
            capabilities.minimumZoom,
            if (capabilities.minimumZoom < .98) 1,
            if (capabilities.maximumZoom >= 1.9) 2,
          }.where((value) => value <= capabilities.maximumZoom + .01).toList()
          ..sort();
    final currentIndex = choices.indexWhere(
      (value) => (value - displayZoom).abs() < .08,
    );
    final next =
        choices[(currentIndex < 0 ? 0 : currentIndex + 1) % choices.length];
    final label = displayZoom < 1
        ? displayZoom.toStringAsFixed(1)
        : displayZoom.toStringAsFixed(displayZoom % 1 == 0 ? 0 : 1);
    return Semantics(
      button: true,
      label: 'Zoom $label times',
      child: Material(
        color: Colors.black.withValues(alpha: .36),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: state.isReady ? () => unawaited(onPressed(next)) : null,
          customBorder: const CircleBorder(),
          splashFactory: NoSplash.splashFactory,
          child: SizedBox.square(
            dimension: 38,
            child: Center(
              child: Text(
                '${label}x',
                style: const TextStyle(
                  color: Color(0xFFF5F5F5),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordingClock extends StatelessWidget {
  const _RecordingClock({required this.duration});
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          '$minutes:$seconds',
          style: const TextStyle(
            color: Color(0xFFFF4D4F),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CameraFailureView extends StatelessWidget {
  const _CameraFailureView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF050608),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: WrytteColors.textMuted,
              size: 42,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WrytteColors.textPrimary,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    ),
  );
}
