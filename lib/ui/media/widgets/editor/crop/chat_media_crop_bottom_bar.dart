import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaCropBottomBar extends StatefulWidget {
  const ChatMediaCropBottomBar({
    super.key,
    required this.editor,
    required this.onApplied,
    required this.onDiscarded,
  });

  final CropRotateEditorState editor;

  final ValueChanged<bool> onApplied;
  final VoidCallback onDiscarded;

  @override
  State<ChatMediaCropBottomBar> createState() => _ChatMediaCropBottomBarState();
}

class _ChatMediaCropBottomBarState extends State<ChatMediaCropBottomBar> {
  static const double _contentHeight = 132;

  static const double _toolBarWidth = 184;

  static const double _roundButtonSize = 52;

  bool _applying = false;
  bool _discardDialogOpen = false;

  bool _near(double first, double second, {double tolerance = .001}) {
    return (first - second).abs() <= tolerance;
  }

  bool _sameOffset(Offset first, Offset second) {
    return _near(first.dx, second.dx, tolerance: .25) &&
        _near(first.dy, second.dy, tolerance: .25);
  }

  bool _sameRect(Rect first, Rect second) {
    return _near(first.left, second.left, tolerance: .5) &&
        _near(first.top, second.top, tolerance: .5) &&
        _near(first.right, second.right, tolerance: .5) &&
        _near(first.bottom, second.bottom, tolerance: .5);
  }

  bool _sameTransform(TransformConfigs first, TransformConfigs second) {
    return _near(first.angle, second.angle) &&
        _near(first.aspectRatio, second.aspectRatio) &&
        first.flipX == second.flipX &&
        first.flipY == second.flipY &&
        first.cropMode == second.cropMode &&
        _sameOffset(first.offset, second.offset) &&
        _sameRect(first.cropRect, second.cropRect) &&
        _near(first.scaleUser, second.scaleUser) &&
        _near(first.scaleRotation, second.scaleRotation) &&
        _near(first.tiltRotate, second.tiltRotate) &&
        _near(first.tiltHorizontal, second.tiltHorizontal) &&
        _near(first.tiltVertical, second.tiltVertical);
  }

  bool get _sessionHasChanges {
    final initial = widget.editor.initialTransformConfigs;

    if (initial == null) {
      return widget.editor.activeHistory.isNotEmpty;
    }

    return !_sameTransform(widget.editor.activeHistory, initial);
  }

  void _reset() {
    if (_applying || !_sessionHasChanges) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    // Package reset returns this crop editor to the transform that existed
    // when the crop session opened.
    widget.editor.reset();
  }

  void _rotate() {
    if (_applying) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    widget.editor.rotate();
  }

  void _flip() {
    if (_applying) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    widget.editor.flip();
  }

  void _openAspectRatio() {
    if (_applying) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    widget.editor.openAspectRatioOptions();
  }

  Future<void> _cancel() async {
    if (_applying || _discardDialogOpen) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    // Nothing changed: simply return to main editor.
    if (!_sessionHasChanges) {
      widget.onDiscarded();
      return;
    }

    _discardDialogOpen = true;

    final discard = await _showDiscardChangesMenu(context);

    _discardDialogOpen = false;

    if (!discard) {
      return;
    }

    unawaited(HapticFeedback.lightImpact());

    // IMPORTANT:
    //
    // This is the package's close-without-applying operation.
    //
    // It throws away this crop session and returns to the main editor
    // preserving the image exactly as it was before Crop was opened.
    widget.onDiscarded();
  }

  Future<void> _apply() async {
    if (_applying) {
      return;
    }

    final changed = _sessionHasChanges;

    final onApplied = widget.onApplied;

    setState(() {
      _applying = true;
    });

    unawaited(HapticFeedback.lightImpact());

    try {
      await widget.editor.done();

      onApplied(changed);
    } catch (error, stackTrace) {
      debugPrint('Failed to apply crop: $error');

      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _applying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = _sessionHasChanges;

    // CropRotateEditor already owns its EditorSafeArea.
    //
    // SafeArea here therefore adds the physical bottom inset only when it
    // remains available, and always keeps at least another 10dp of breathing
    // room over gesture/navigation controls.
    return SafeArea(
      top: false,
      left: false,
      right: false,
      minimum: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        height: _contentHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: changed && !_applying ? _reset : null,
                style: ButtonStyle(
                  foregroundColor: WidgetStateProperty.resolveWith<Color?>((
                    states,
                  ) {
                    if (states.contains(WidgetState.disabled)) {
                      return WrytteColors.textMuted;
                    }

                    if (states.contains(WidgetState.pressed)) {
                      return const Color(0xFFB8B8B8);
                    }

                    return WrytteColors.textPrimary;
                  }),
                  overlayColor: const WidgetStatePropertyAll<Color>(
                    Colors.transparent,
                  ),
                  splashFactory: NoSplash.splashFactory,
                  minimumSize: const WidgetStatePropertyAll<Size>(Size.zero),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                    EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  ),
                  textStyle: const WidgetStatePropertyAll<TextStyle>(
                    TextStyle(
                      fontFamily: WrytteTypography.primaryFontFamily,
                      fontSize: 17,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                child: const Text('Reset'),
              ),

              const SizedBox(height: 8),

              Row(
                children: [
                  _CropRoundActionButton(
                    tooltip: 'Cancel crop',
                    onTap: _applying
                        ? null
                        : () {
                            unawaited(_cancel());
                          },
                    child: const Icon(
                      Icons.close_rounded,
                      size: 29,
                      color: WrytteColors.textPrimary,
                    ),
                  ),

                  const Spacer(),

                  SizedBox(
                    width: _toolBarWidth,
                    height: 50,
                    child: WrytteGlassSurface(
                      borderRadius: BorderRadius.circular(25),
                      blur: 22,
                      child: Material(
                        type: MaterialType.transparency,
                        child: Row(
                          children: [
                            _CropToolButton(
                              tooltip: 'Rotate left',
                              asset: 'assets/svg/Rotate left icon.svg',
                              onTap: _rotate,
                            ),

                            _CropToolButton(
                              tooltip: 'Flip horizontally',
                              asset: 'assets/svg/Flip mirror icon.svg',
                              onTap: _flip,
                            ),

                            _CropToolButton(
                              tooltip: 'Change aspect ratio',
                              asset: 'assets/svg/Screen size icon.svg',
                              onTap: _openAspectRatio,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const Spacer(),

                  _CropRoundActionButton(
                    tooltip: 'Apply crop',
                    backgroundColor: WrytteColors.primary,
                    onTap: _applying
                        ? null
                        : () {
                            unawaited(_apply());
                          },

                    // Keep the visual stable while Pro Image Editor commits.
                    // No loading spinner jumping into the toolbar.
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: _applying ? .62 : 1,
                      child: const WrytteSvgIcon(
                        asset: 'assets/svg/Checkmark edit.svg',
                        size: 27,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _showDiscardChangesMenu(BuildContext context) async {
    final result = await showGeneralDialog<bool>(
      context: context,

      // Keep the confirmation independent from Pro ImageEditor's nested crop
      // route. Once this route is completely dismissed, _cancel() calls
      // editor.close().
      useRootNavigator: true,

      barrierDismissible: true,
      barrierLabel: 'Dismiss discard changes menu',
      barrierColor: Colors.transparent,

      transitionDuration: const Duration(milliseconds: 150),

      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final bottomInset = MediaQuery.viewPaddingOf(dialogContext).bottom;

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              // The route barrier handles outside taps. This is just the menu.
              PositionedDirectional(
                start: 10,

                // X sits in the bottom row.
                // This places the menu slightly above that button.
                bottom: bottomInset + 78,

                child: SizedBox(
                  width: 216,
                  child: WrytteGlassSurface(
                    borderRadius: BorderRadius.circular(26),
                    blur: 22,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        onTap: () {
                          Navigator.of(dialogContext).pop(true);
                        },
                        splashFactory: NoSplash.splashFactory,
                        overlayColor: WidgetStateProperty.resolveWith<Color?>((
                          states,
                        ) {
                          if (states.contains(WidgetState.pressed)) {
                            return const Color(0x22FF4D4D);
                          }

                          return Colors.transparent;
                        }),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 17,
                          ),
                          child: Text(
                            'Discard changes',
                            style: TextStyle(
                              color: Color(0xFFFF4D4F),
                              fontFamily: WrytteTypography.primaryFontFamily,
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },

      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );

        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            alignment: Alignment.bottomLeft,
            scale: Tween<double>(begin: .96, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );

    return result ?? false;
  }
}

class _CropToolButton extends StatelessWidget {
  const _CropToolButton({
    required this.tooltip,
    required this.asset,
    required this.onTap,
  });

  final String tooltip;
  final String asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkResponse(
          onTap: onTap,
          containedInkWell: true,
          highlightShape: BoxShape.circle,
          radius: 24,
          splashColor: Colors.transparent,
          highlightColor: Colors.white.withValues(alpha: .035),
          child: Center(
            child: WrytteSvgIcon(
              asset: asset,
              size: 27,
              color: WrytteColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _CropRoundActionButton extends StatelessWidget {
  const _CropRoundActionButton({
    required this.tooltip,
    required this.child,
    required this.onTap,
    this.backgroundColor,
  });

  final String tooltip;
  final Widget child;
  final VoidCallback? onTap;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox.square(
      dimension: _ChatMediaCropBottomBarState._roundButtonSize,
      child: backgroundColor == null
          ? WrytteGlassSurface(
              borderRadius: BorderRadius.circular(26),
              blur: 22,
              child: Material(
                type: MaterialType.transparency,
                child: InkResponse(
                  onTap: onTap,
                  containedInkWell: true,
                  highlightShape: BoxShape.circle,
                  radius: 26,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.white.withValues(alpha: .045),
                  child: Center(child: child),
                ),
              ),
            )
          : Material(
              type: MaterialType.transparency,
              child: InkResponse(
                onTap: onTap,
                containedInkWell: true,
                highlightShape: BoxShape.circle,
                radius: 26,
                splashColor: Colors.transparent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    shape: BoxShape.circle,
                  ),
                  child: Center(child: child),
                ),
              ),
            ),
    );

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: tooltip,
      child: button,
    );
  }
}
