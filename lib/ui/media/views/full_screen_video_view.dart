import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/core/routing/expanding_surface_route.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_animated_popover.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/media/video/wrytte_video_session.dart';
import 'package:wrytte/ui/media/video/wrytte_video_surface.dart';
import 'package:wrytte/ui/media/widgets/media_circle_button.dart';

Future<void> showWrytteVideoViewer(
  BuildContext context, {
  required String source,
  ExpandingSurfaceOrigin? origin,
  String? title,
  String? subtitle,
  String? caption,
  VoidCallback? onShare,
  VoidCallback? onDownload,
  VoidCallback? onEdit,
  VoidCallback? onReply,
  VoidCallback? onShowInChat,
  VoidCallback? onDelete,
}) => Navigator.of(context, rootNavigator: true).push<void>(
  ExpandingSurfaceRoute<void>(
    origin: origin,
    animationsDisabled: MediaQuery.disableAnimationsOf(context),
    builder: (context, animation) => FullScreenVideoView(
      source: source,
      routeAnimation: animation,
      title: title,
      subtitle: subtitle,
      caption: caption,
      onShare: onShare,
      onDownload: onDownload,
      onEdit: onEdit,
      onReply: onReply,
      onShowInChat: onShowInChat,
      onDelete: onDelete,
    ),
  ),
);

class FullScreenVideoView extends StatefulWidget {
  const FullScreenVideoView({
    super.key,
    required this.source,
    required this.routeAnimation,
    this.title,
    this.subtitle,
    this.caption,
    this.onShare,
    this.onDownload,
    this.onEdit,
    this.onReply,
    this.onShowInChat,
    this.onDelete,
  });

  final String source;
  final Animation<double> routeAnimation;
  final String? title;
  final String? subtitle;
  final String? caption;
  final VoidCallback? onShare;
  final VoidCallback? onDownload;
  final VoidCallback? onEdit;
  final VoidCallback? onReply;
  final VoidCallback? onShowInChat;
  final VoidCallback? onDelete;

  @override
  State<FullScreenVideoView> createState() => _FullScreenVideoViewState();
}

class _FullScreenVideoViewState extends State<FullScreenVideoView> {
  final WrytteVideoSession _session = WrytteVideoSession();
  bool _controlsVisible = true;
  bool _deleteVisible = false;
  bool _moreVisible = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_refresh);
    unawaited(
      _session.open(
        source: widget.source,
        autoplay: true,
        loop: false,
        startMuted: false,
      ),
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _togglePlayback() =>
      _session.isPlaying ? _session.pause() : _session.play();

  void _run(VoidCallback? action) {
    setState(() => _moreVisible = false);
    action?.call();
  }

  void _toggleControls() {
    if (_deleteVisible || _moreVisible) {
      setState(() {
        _deleteVisible = false;
        _moreVisible = false;
      });
    } else {
      setState(() => _controlsVisible = !_controlsVisible);
    }
  }

  void _confirmDelete() {
    widget.onDelete?.call();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _session.removeListener(_refresh);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _session.controller;
    final initialized = controller?.value.isInitialized == true;
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    final routeControls = animationsDisabled
        ? const AlwaysStoppedAnimation<double>(1)
        : CurvedAnimation(
            parent: widget.routeAnimation,
            curve: const Interval(.42, 1, curve: Curves.easeOutCubic),
            reverseCurve: const Interval(0, .62, curve: Curves.easeInCubic),
          );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (initialized)
                WrytteVideoSurface(controller: controller!, fit: BoxFit.contain)
              else
                const Center(
                  child: SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ),
              if (initialized)
                Center(
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 190),
                    child: MediaCircleButton(
                      semanticLabel: _session.isPlaying
                          ? 'Pause video'
                          : 'Play video',
                      onPressed: () => unawaited(_togglePlayback()),
                      size: 68,
                      child: Icon(
                        _session.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 42,
                      ),
                    ),
                  ),
                ),
              FadeTransition(
                opacity: routeControls,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: animationsDisabled
                      ? Duration.zero
                      : const Duration(milliseconds: 210),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Stack(
                      children: [
                        _topControls(),
                        if (initialized)
                          ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: controller!,
                            builder: (context, value, _) =>
                                _bottomControls(controller!, value),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topControls() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              children: [
                MediaCircleButton(
                  semanticLabel: 'Close video',
                  size: 48,
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const WrytteSvgIcon(
                    asset: 'assets/svg/ic--round-arrow-back-ios.svg',
                    size: 26,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _VideoPill(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.title?.trim().isNotEmpty == true
                              ? widget.title!.trim()
                              : 'Video',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            height: 1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (widget.subtitle?.trim().isNotEmpty == true) ...[
                          const SizedBox(height: 3),
                          Text(
                            widget.subtitle!.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFB0B3B8),
                              fontSize: 13,
                              height: 1,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                MediaCircleButton(
                  semanticLabel: 'More video options',
                  size: 48,
                  onPressed: () => setState(() => _moreVisible = !_moreVisible),
                  child: const Icon(
                    Icons.more_horiz_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ],
            ),
            PositionedDirectional(
              top: 56,
              end: 0,
              child: WrytteAnimatedPopover(
                visible: _moreVisible,
                alignment: Alignment.topRight,
                child: _VideoMoreMenu(
                  muted: _session.muted,
                  onShowInChat: widget.onShowInChat == null
                      ? null
                      : () => _run(widget.onShowInChat),
                  onReply: widget.onReply == null
                      ? null
                      : () => _run(widget.onReply),
                  onSound: () {
                    setState(() => _moreVisible = false);
                    unawaited(_session.toggleMute());
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomControls(
    VideoPlayerController controller,
    VideoPlayerValue value,
  ) {
    final duration = value.duration;
    final position = value.position;
    final maxMs = duration.inMilliseconds.clamp(1, 1 << 31);
    final caption = widget.caption?.trim() ?? '';
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (caption.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: WrytteGlassSurface(
                    borderRadius: BorderRadius.circular(22),
                    blur: 14,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Text(
                      caption,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        height: 1.25,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              _VideoPill(
                child: Row(
                  children: [
                    SizedBox(
                      width: 45,
                      child: Text(
                        _format(position),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 7,
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: const Color(0xFF85878C),
                          thumbColor: Colors.white,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5.5,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Slider(
                          value: position.inMilliseconds
                              .clamp(0, maxMs)
                              .toDouble(),
                          max: maxMs.toDouble(),
                          onChanged: (value) => unawaited(
                            controller.seekTo(
                              Duration(milliseconds: value.round()),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 45,
                      child: Text(
                        _format(duration - position),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (widget.onDelete != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: WrytteAnimatedPopover(
                    visible: _deleteVisible,
                    alignment: Alignment.bottomRight,
                    child: _VideoDeleteConfirmation(onDelete: _confirmDelete),
                  ),
                ),
              if (widget.onDelete != null && _deleteVisible)
                const SizedBox(height: 8),
              Row(
                children: [
                  if (widget.onShare != null)
                    _circleAction(
                      label: 'Share video',
                      asset: 'assets/svg/Forward Icon.svg',
                      onTap: widget.onShare!,
                    )
                  else
                    const SizedBox(width: 48),
                  const Spacer(),
                  if (widget.onDownload != null || widget.onEdit != null)
                    WrytteGlassSurface(
                      borderRadius: BorderRadius.circular(24),
                      blur: 14,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.onDownload != null)
                            _VideoInlineAction(
                              label: 'Save video',
                              asset: 'assets/svg/Download Save icon.svg',
                              onTap: widget.onDownload!,
                            ),
                          if (widget.onEdit != null)
                            _VideoInlineAction(
                              label: 'Edit video',
                              asset: 'assets/svg/Edit pencil icon.svg',
                              onTap: widget.onEdit!,
                            ),
                        ],
                      ),
                    ),
                  const Spacer(),
                  if (widget.onDelete != null)
                    _circleAction(
                      label: 'Delete video',
                      asset: 'assets/svg/Delete icon.svg',
                      color: WrytteColors.destructive,
                      onTap: () =>
                          setState(() => _deleteVisible = !_deleteVisible),
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _circleAction({
    required String label,
    required String asset,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) => MediaCircleButton(
    semanticLabel: label,
    size: 48,
    onPressed: onTap,
    child: WrytteSvgIcon(asset: asset, size: 23, color: color),
  );

  String _format(Duration value) {
    final safeSeconds = value.inSeconds.clamp(0, 359999);
    final minutes = safeSeconds ~/ 60;
    final seconds = safeSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _VideoPill extends StatelessWidget {
  const _VideoPill({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: WrytteGlassSurface(
      borderRadius: BorderRadius.circular(24),
      blur: 14,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: child,
    ),
  );
}

class _VideoInlineAction extends StatelessWidget {
  const _VideoInlineAction({
    required this.label,
    required this.asset,
    required this.onTap,
  });
  final String label;
  final String asset;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox.square(
        dimension: 48,
        child: Center(
          child: WrytteSvgIcon(asset: asset, size: 24, color: Colors.white),
        ),
      ),
    ),
  );
}

class _VideoMoreMenu extends StatelessWidget {
  const _VideoMoreMenu({
    required this.muted,
    required this.onSound,
    this.onShowInChat,
    this.onReply,
  });
  final bool muted;
  final VoidCallback onSound;
  final VoidCallback? onShowInChat;
  final VoidCallback? onReply;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 210,
    child: WrytteGlassSurface(
      borderRadius: BorderRadius.circular(22),
      blur: 14,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onShowInChat != null)
            _VideoMoreItem(
              label: 'Show in chat',
              asset: 'assets/svg/Show in Chat icon.svg',
              onTap: onShowInChat!,
            ),
          if (onReply != null)
            _VideoMoreItem(
              label: 'Reply',
              asset: 'assets/svg/Forward Icon.svg',
              onTap: onReply!,
            ),
          _VideoMoreItem(
            label: muted ? 'Unmute' : 'Mute',
            asset: muted
                ? 'assets/svg/Nosound icon.svg'
                : 'assets/svg/Sound icon.svg',
            onTap: onSound,
          ),
        ],
      ),
    ),
  );
}

class _VideoMoreItem extends StatelessWidget {
  const _VideoMoreItem({
    required this.label,
    required this.asset,
    required this.onTap,
  });
  final String label;
  final String asset;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 46,
      child: Row(
        children: [
          const SizedBox(width: 16),
          WrytteSvgIcon(asset: asset, size: 21, color: Colors.white),
          const SizedBox(width: 13),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    ),
  );
}

class _VideoDeleteConfirmation extends StatelessWidget {
  const _VideoDeleteConfirmation({required this.onDelete});
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 180,
    height: 56,
    child: WrytteGlassSurface(
      borderRadius: BorderRadius.circular(28),
      blur: 10,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: onDelete,
          child: const Center(
            child: Text(
              'Delete video',
              style: TextStyle(
                color: WrytteColors.destructive,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
