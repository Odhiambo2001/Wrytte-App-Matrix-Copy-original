import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/attachment_local_store.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/core/routing/expanding_surface_route.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_animated_popover.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/media/widgets/media_circle_button.dart';

enum FullScreenImageResult { closed, deleteRequested }

Future<FullScreenImageResult?> showWrytteImageViewer(
  BuildContext context, {
  required ImageProvider image,
  String? mediaSource,
  ExpandingSurfaceOrigin? origin,
  double? imageAspectRatio,
  String? title,
  String? subtitle,
  String? caption,
  VoidCallback? onShare,
  VoidCallback? onDownload,
  VoidCallback? onEdit,
  VoidCallback? onReply,
  VoidCallback? onShowInChat,
  bool allowDelete = false,
  bool showHeaderLabel = true,
  bool enableVerticalDragDismiss = false,
}) async {
  var resolvedImage = image;
  final source = mediaSource?.trim() ?? '';
  if (source.startsWith('mxc://') || _isMatrixMediaUrl(source)) {
    final uri = Uri.tryParse(source);
    if (uri != null && uri.host.isNotEmpty) {
      final downloadUrl = source.startsWith('mxc://')
          ? Uri.parse(MatrixConfig.homeserver).replace(
              path: '/_matrix/client/v1/media/download/${Uri.encodeComponent(uri.host)}/${Uri.encodeComponent(uri.pathSegments.join('/'))}',
            ).toString()
          : source;
      try {
        final cached = await AttachmentLocalStore.instance.existingComplete(
          source: source,
          fileName: 'image',
        ) ??
            await AttachmentLocalStore.instance.existingComplete(
              source: downloadUrl,
              fileName: 'image',
            );
        if (cached != null) {
          resolvedImage = FileImage(cached);
        } else {
          final copy = await AttachmentLocalStore.instance.ensureComplete(
            source: downloadUrl,
            fileName: 'image',
          );
          resolvedImage = FileImage(copy.file);
        }
      } catch (_) {
        // Keep the supplied provider as the viewer fallback.
      }
    }
  }
  return Navigator.of(context, rootNavigator: true).push<FullScreenImageResult>(
    ExpandingSurfaceRoute<FullScreenImageResult>(
    origin: origin,
    animationsDisabled: MediaQuery.disableAnimationsOf(context),
    keepUnderlyingVisible: enableVerticalDragDismiss,
    builder: (context, animation) => FullScreenImageView(
      image: resolvedImage,
      imageAspectRatio: imageAspectRatio,
      routeAnimation: animation,
      title: title,
      subtitle: subtitle,
      caption: caption,
      onShare: onShare,
      onDownload: onDownload,
      onEdit: onEdit,
      onReply: onReply,
      onShowInChat: onShowInChat,
      allowDelete: allowDelete,
      showHeaderLabel: showHeaderLabel,
      enableVerticalDragDismiss: enableVerticalDragDismiss,
    ),
    ),
  );
}

bool _isMatrixMediaUrl(String source) {
  final uri = Uri.tryParse(source);
  final homeserver = Uri.tryParse(MatrixConfig.homeserver);
  return uri != null &&
      homeserver != null &&
      uri.origin == homeserver.origin &&
      uri.path.contains('/_matrix/client/') &&
      uri.path.contains('/media/');
}

class FullScreenImageView extends StatefulWidget {
  const FullScreenImageView({
    super.key,
    required this.image,
    required this.routeAnimation,
    this.imageAspectRatio,
    this.title,
    this.subtitle,
    this.caption,
    this.onShare,
    this.onDownload,
    this.onEdit,
    this.onReply,
    this.onShowInChat,
    this.allowDelete = false,
    this.showHeaderLabel = true,
    this.enableVerticalDragDismiss = false,
  });

  final ImageProvider image;
  final Animation<double> routeAnimation;
  final double? imageAspectRatio;
  final String? title;
  final String? subtitle;
  final String? caption;
  final VoidCallback? onShare;
  final VoidCallback? onDownload;
  final VoidCallback? onEdit;
  final VoidCallback? onReply;
  final VoidCallback? onShowInChat;
  final bool allowDelete;
  final bool showHeaderLabel;
  final bool enableVerticalDragDismiss;

  @override
  State<FullScreenImageView> createState() => _FullScreenImageViewState();
}

class _FullScreenImageViewState extends State<FullScreenImageView> {
  static const _dismissVelocity = 850.0;

  bool _controlsVisible = true;
  bool _deleteVisible = false;
  bool _moreVisible = false;
  bool _verticalDragActive = false;
  double _verticalDragOffset = 0;

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

  void _run(VoidCallback? action) {
    setState(() => _moreVisible = false);
    action?.call();
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    if (!widget.enableVerticalDragDismiss) return;
    setState(() {
      _verticalDragActive = true;
      _deleteVisible = false;
      _moreVisible = false;
    });
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (!widget.enableVerticalDragDismiss) return;
    final height = MediaQuery.sizeOf(context).height;
    setState(() {
      _verticalDragOffset = (_verticalDragOffset + details.delta.dy).clamp(
        -height * .72,
        height * .72,
      );
    });
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (!widget.enableVerticalDragDismiss) return;
    final height = MediaQuery.sizeOf(context).height;
    final velocity = details.primaryVelocity ?? 0;
    final dismiss =
        _verticalDragOffset.abs() >= height * .12 ||
        velocity.abs() >= _dismissVelocity;
    _verticalDragActive = false;
    if (dismiss) {
      Navigator.of(context).pop(FullScreenImageResult.closed);
      return;
    }
    setState(() => _verticalDragOffset = 0);
  }

  void _handleVerticalDragCancel() {
    if (!widget.enableVerticalDragDismiss) return;
    _verticalDragActive = false;
    setState(() => _verticalDragOffset = 0);
  }

  @override
  Widget build(BuildContext context) {
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
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: widget.enableVerticalDragDismiss
            ? Colors.transparent
            : Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onVerticalDragStart: widget.enableVerticalDragDismiss
              ? _handleVerticalDragStart
              : null,
          onVerticalDragUpdate: widget.enableVerticalDragDismiss
              ? _handleVerticalDragUpdate
              : null,
          onVerticalDragEnd: widget.enableVerticalDragDismiss
              ? _handleVerticalDragEnd
              : null,
          onVerticalDragCancel: widget.enableVerticalDragDismiss
              ? _handleVerticalDragCancel
              : null,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: _verticalDragOffset),
            duration: _verticalDragActive || animationsDisabled
                ? Duration.zero
                : const Duration(milliseconds: 210),
            curve: Curves.easeOutCubic,
            builder: (context, dragOffset, _) {
              final height = MediaQuery.sizeOf(context).height;
              final progress = (dragOffset.abs() / (height * .46)).clamp(
                0.0,
                1.0,
              );
              final backdropOpacity = 1 - progress * .78;
              final mediaScale = 1 - progress * .10;
              final controlsOpacity = (1 - progress * 2).clamp(0.0, 1.0);
              return Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black.withValues(alpha: backdropOpacity),
                  ),
                  Transform.translate(
                    offset: Offset(0, dragOffset),
                    child: Transform.scale(
                      scale: mediaScale,
                      child: _media(progress),
                    ),
                  ),
                  Opacity(
                    opacity: controlsOpacity,
                    child: IgnorePointer(
                      ignoring: controlsOpacity < .95,
                      child: FadeTransition(
                        opacity: routeControls,
                        child: AnimatedOpacity(
                          opacity: _controlsVisible ? 1 : 0,
                          duration: animationsDisabled
                              ? Duration.zero
                              : const Duration(milliseconds: 210),
                          child: IgnorePointer(
                            ignoring: !_controlsVisible,
                            child: Stack(
                              children: [_topControls(), _bottomControls()],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _media(double dragProgress) {
    Widget image = widget.imageAspectRatio == null
        ? Image(
            image: widget.image,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.high,
          )
        : AspectRatio(
            aspectRatio: widget.imageAspectRatio!,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18 * dragProgress),
              child: Image(
                image: widget.image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.high,
              ),
            ),
          );
    image = Center(child: image);
    if (widget.enableVerticalDragDismiss) return image;
    return InteractiveViewer(minScale: .8, maxScale: 5, child: image);
  }

  Widget _topControls() {
    final hasMore = widget.onShowInChat != null || widget.onReply != null;
    final controlSize = widget.enableVerticalDragDismiss ? 42.0 : 48.0;
    final iconSize = widget.enableVerticalDragDismiss ? 24.0 : 26.0;
    final horizontalPadding = widget.enableVerticalDragDismiss ? 20.0 : 12.0;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          14,
          horizontalPadding,
          0,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              children: [
                MediaCircleButton(
                  semanticLabel: 'Close photo',
                  size: controlSize,
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: WrytteSvgIcon(
                    asset: 'assets/svg/ic--round-arrow-back-ios.svg',
                    size: iconSize,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.showHeaderLabel)
                  Expanded(
                    child: _ViewerPill(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            widget.title?.trim().isNotEmpty == true
                                ? widget.title!.trim()
                                : 'Photo',
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
                  )
                else
                  const Spacer(),
                const SizedBox(width: 8),
                if (hasMore)
                  MediaCircleButton(
                    semanticLabel: 'More photo options',
                    size: controlSize,
                    onPressed: () =>
                        setState(() => _moreVisible = !_moreVisible),
                    child: const Icon(
                      Icons.more_horiz_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  )
                else
                  SizedBox(width: controlSize),
              ],
            ),
            if (hasMore)
              PositionedDirectional(
                top: 56,
                end: 0,
                child: WrytteAnimatedPopover(
                  visible: _moreVisible,
                  alignment: Alignment.topRight,
                  child: _ViewerMoreMenu(
                    onShowInChat: widget.onShowInChat == null
                        ? null
                        : () => _run(widget.onShowInChat),
                    onReply: widget.onReply == null
                        ? null
                        : () => _run(widget.onReply),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomControls() {
    final caption = widget.caption?.trim() ?? '';
    final controlSize = widget.enableVerticalDragDismiss ? 42.0 : 48.0;
    final iconSize = widget.enableVerticalDragDismiss ? 24.0 : 23.0;
    final horizontalPadding = widget.enableVerticalDragDismiss ? 24.0 : 12.0;
    final hasActions =
        widget.onShare != null ||
        widget.onDownload != null ||
        widget.onEdit != null ||
        widget.allowDelete;
    if (!hasActions && caption.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            12,
          ),
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
              if (widget.allowDelete)
                Align(
                  alignment: Alignment.centerRight,
                  child: TweenAnimationBuilder<double>(
                    key: const ValueKey(
                      'full-screen-image-delete-confirmation-animation',
                    ),
                    tween: Tween<double>(end: _deleteVisible ? 1 : 0),
                    duration: const Duration(milliseconds: 190),
                    curve: _deleteVisible
                        ? Curves.easeOutCubic
                        : Curves.easeInCubic,
                    builder: (context, progress, _) => IgnorePointer(
                      ignoring: progress < .98,
                      child: Opacity(
                        opacity: progress,
                        child: SizedBox(
                          width: 220 * progress,
                          height: 60 * progress,
                          child: _DeleteConfirmation(
                            onDelete: () => Navigator.of(
                              context,
                            ).pop(FullScreenImageResult.deleteRequested),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.allowDelete)
                SizedBox(height: 8 * (_deleteVisible ? 1 : 0)),
              Row(
                children: [
                  if (widget.onShare != null)
                    _circleAction(
                      label: 'Share photo',
                      asset: 'assets/svg/Forward Icon.svg',
                      onTap: widget.onShare!,
                      size: controlSize,
                      iconSize: iconSize,
                    )
                  else
                    SizedBox(width: controlSize),
                  const Spacer(),
                  if (widget.onDownload != null || widget.onEdit != null)
                    WrytteGlassSurface(
                      borderRadius: BorderRadius.circular(24),
                      blur: 14,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.onDownload != null)
                            _InlineAction(
                              label: 'Save photo',
                              asset: 'assets/svg/Download Save icon.svg',
                              onTap: widget.onDownload!,
                            ),
                          if (widget.onEdit != null)
                            _InlineAction(
                              label: 'Edit photo',
                              asset: 'assets/svg/Edit pencil icon.svg',
                              onTap: widget.onEdit!,
                            ),
                        ],
                      ),
                    ),
                  const Spacer(),
                  if (widget.allowDelete)
                    _circleAction(
                      label: 'Delete photo',
                      asset: 'assets/svg/Delete icon.svg',
                      color: WrytteColors.destructive,
                      size: controlSize,
                      iconSize: iconSize,
                      onTap: () =>
                          setState(() => _deleteVisible = !_deleteVisible),
                    )
                  else
                    SizedBox(width: controlSize),
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
    double size = 48,
    double iconSize = 23,
  }) => MediaCircleButton(
    semanticLabel: label,
    size: size,
    onPressed: onTap,
    child: WrytteSvgIcon(asset: asset, size: iconSize, color: color),
  );
}

class _ViewerPill extends StatelessWidget {
  const _ViewerPill({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: WrytteGlassSurface(
      borderRadius: BorderRadius.circular(24),
      blur: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: child,
    ),
  );
}

class _InlineAction extends StatelessWidget {
  const _InlineAction({
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

class _ViewerMoreMenu extends StatelessWidget {
  const _ViewerMoreMenu({this.onShowInChat, this.onReply});
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
            _MoreItem(
              label: 'Show in chat',
              asset: 'assets/svg/Show in Chat icon.svg',
              onTap: onShowInChat!,
            ),
          if (onReply != null)
            _MoreItem(
              label: 'Reply',
              asset: 'assets/svg/Forward Icon.svg',
              onTap: onReply!,
            ),
        ],
      ),
    ),
  );
}

class _MoreItem extends StatelessWidget {
  const _MoreItem({
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

class _DeleteConfirmation extends StatelessWidget {
  const _DeleteConfirmation({required this.onDelete});
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) => WrytteGlassSurface(
    borderRadius: BorderRadius.circular(30),
    blur: 10,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onDelete,
        child: const Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Text(
              'Delete',
              style: TextStyle(
                color: WrytteColors.destructive,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
