import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/media/widgets/editor/paint/chat_media_paint_shape_menu.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaPaintBottomBar extends StatefulWidget {
  const ChatMediaPaintBottomBar({
    super.key,
    required this.editor,
    required this.onDiscarded,
  });

  static const double baseHeight = 132;

  final PaintEditorState editor;
  final VoidCallback onDiscarded;

  @override
  State<ChatMediaPaintBottomBar> createState() =>
      _ChatMediaPaintBottomBarState();
}

class _ChatMediaPaintBottomBarState extends State<ChatMediaPaintBottomBar> {
  static const double _toolBarWidth = 222;

  static const double _roundButtonSize = 40;

  bool _closing = false;
  bool _discardDialogOpen = false;

  bool get _hasChanges {
    // PaintEditor owns its own session history.
    //
    // Color/brush selection alone does not create history, which is exactly
    // what we want: X should not ask to discard when no pixels/layers changed.
    return widget.editor.canUndo;
  }

  bool get _supportsFill {
    switch (widget.editor.paintMode) {
      case PaintMode.custom1:
      case PaintMode.circle:
      case PaintMode.custom2:
        return true;

      default:
        return false;
    }
  }

  void _selectBrush(double strokeWidth) {
    if (_closing) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    widget.editor.setMode(PaintMode.freeStyle);

    widget.editor.setStrokeWidth(strokeWidth);
  }

  void _setFill(bool filled) {
    if (_closing) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    widget.editor.setFill(filled);
  }

  void _reset() {
    if (_closing || !_hasChanges) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    // Undo only PaintEditor's own session history.
    //
    // We no longer need to manually restore PaintLayer fields because we're
    // not mutating them behind the package's history system.
    while (widget.editor.canUndo) {
      widget.editor.undoAction();
    }

    widget.editor.setMode(PaintMode.freeStyle);

    widget.editor.setStrokeWidth(3);

    widget.editor.setFill(false);
  }

  Future<void> _cancel() async {
    debugPrint(
      '[PAINTDBG][X] entered closing=$_closing '
      'dialogOpen=$_discardDialogOpen canUndo=${widget.editor.canUndo}',
    );

    if (_closing || _discardDialogOpen) {
      debugPrint('[PAINTDBG][X] ignored because the editor is already closing');
      return;
    }

    if (!_hasChanges) {
      debugPrint('[PAINTDBG][X] no changes; closing sub-editor');
      _closing = true;
      Navigator.of(widget.editor.context).pop();
      return;
    }

    _discardDialogOpen = true;
    debugPrint('[PAINTDBG][X] showing discard dialog');
    final discard = await _showDiscardDialog(context);
    _discardDialogOpen = false;
    debugPrint('[PAINTDBG][X] discard dialog result=$discard mounted=$mounted');

    if (!discard || !mounted) {
      return;
    }

    _reset();
    _closing = true;
    debugPrint('[PAINTDBG][X] discarded changes; closing sub-editor');
    Navigator.of(widget.editor.context).pop();
  }

  void _apply() {
    debugPrint(
      '[PAINTDBG][CHECK] entered closing=$_closing '
      'canUndo=${widget.editor.canUndo}',
    );

    if (_closing) {
      debugPrint('[PAINTDBG][CHECK] ignored because the editor is already closing');
      return;
    }

    _closing = true;
    debugPrint('[PAINTDBG][CHECK] calling PaintEditorState.done()');

    // PaintEditor.done() has no result to commit when this session has no
    // paint history. Close the parent sub-editor explicitly in that case.
    if (!widget.editor.canUndo) {
      debugPrint(
        '[PAINTDBG][CHECK] no paint history; closing parent sub-editor',
      );
      Navigator.of(widget.editor.context).pop();
      return;
    }

    widget.editor.done();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: SizedBox(
        height: ChatMediaPaintBottomBar.baseHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),

          child: Stack(
            clipBehavior: Clip.none,

            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.end,

                children: [
                  TextButton(
                    onPressed: _hasChanges && !_closing ? _reset : null,

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

                      minimumSize: const WidgetStatePropertyAll<Size>(
                        Size.zero,
                      ),

                      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                        EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      ),

                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,

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
                      _RoundActionButton(
                        tooltip: 'Cancel drawing',

                        onTap: _closing
                            ? null
                            : () {
                                debugPrint('[PAINTDBG][X] tap received');
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
                                _BrushButton(
                                  editor: widget.editor,

                                  tooltip: 'Thin brush',

                                  asset: 'assets/svg/Draw icon 1.svg',

                                  strokeWidth: 3,

                                  onPressed: _selectBrush,
                                ),

                                _BrushButton(
                                  editor: widget.editor,

                                  tooltip: 'Medium brush',

                                  asset: 'assets/svg/Draw icon 2.svg',

                                  strokeWidth: 6,

                                  onPressed: _selectBrush,
                                ),

                                _BrushButton(
                                  editor: widget.editor,

                                  tooltip: 'Thick brush',

                                  asset: 'assets/svg/Draw icon 3.svg',

                                  strokeWidth: 10,

                                  onPressed: _selectBrush,
                                ),

                                ChatMediaPaintShapeMenuButton(
                                  editor: widget.editor,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const Spacer(),

                      _RoundActionButton(
                        tooltip: 'Apply drawing',

                        backgroundColor: WrytteColors.primary,

                        onTap: _closing
                            ? null
                            : () {
                                debugPrint('[PAINTDBG][CHECK] tap received');
                                _apply();
                              },

                        child: const WrytteSvgIcon(
                          asset: 'assets/svg/Checkmark edit.svg',
                          size: 27,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              // Fill / outline controls are only meaningful for closed shapes.
              //
              // Instead of modifying a previously-created PaintLayer directly,
              // this sets the package's real current fill mode BEFORE drawing.
              if (_supportsFill)
                PositionedDirectional(
                  start: 0,

                  bottom: 56,

                  child: _FillSelector(
                    editor: widget.editor,

                    onChanged: _setFill,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _showDiscardDialog(BuildContext context) async {
    final result = await showGeneralDialog<bool>(
      context: context,

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
              PositionedDirectional(
                start: 10,

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
                          return states.contains(WidgetState.pressed)
                              ? const Color(0x22FF4D4D)
                              : Colors.transparent;
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

class _BrushButton extends StatelessWidget {
  const _BrushButton({
    required this.editor,
    required this.tooltip,
    required this.asset,
    required this.strokeWidth,
    required this.onPressed,
  });

  final PaintEditorState editor;

  final String tooltip;
  final String asset;

  final double strokeWidth;

  final ValueChanged<double> onPressed;

  @override
  Widget build(BuildContext context) {
    final selected =
        editor.paintMode == PaintMode.freeStyle &&
        (editor.strokeWidth - strokeWidth).abs() < .1;

    return Expanded(
      child: Semantics(
        button: true,

        selected: selected,

        label: tooltip,

        child: InkResponse(
          onTap: () {
            onPressed(strokeWidth);
          },

          containedInkWell: true,

          highlightShape: BoxShape.circle,

          radius: 24,

          splashColor: Colors.transparent,

          highlightColor: Colors.white.withValues(alpha: .035),

          child: Center(
            child: WrytteSvgIcon(
              asset: asset,

              size: 29,

              color: selected ? editor.activeColor : WrytteColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _FillSelector extends StatelessWidget {
  const _FillSelector({required this.editor, required this.onChanged});

  final PaintEditorState editor;

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,

      height: 40,

      child: WrytteGlassSurface(
        borderRadius: BorderRadius.circular(20),

        blur: 22,

        child: Material(
          type: MaterialType.transparency,

          child: Row(
            children: [
              _FillOption(
                selected: !editor.fillBackground,

                tooltip: 'Outline shape',

                asset: 'assets/svg/Circle icon.svg',

                onTap: () {
                  onChanged(false);
                },
              ),

              _FillOption(
                selected: editor.fillBackground,

                tooltip: 'Filled shape',

                asset: 'assets/svg/Fill circle icon.svg',

                onTap: () {
                  onChanged(true);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FillOption extends StatelessWidget {
  const _FillOption({
    required this.selected,
    required this.tooltip,
    required this.asset,
    required this.onTap,
  });

  final bool selected;

  final String tooltip;
  final String asset;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,

        selected: selected,

        label: tooltip,

        child: InkResponse(
          onTap: onTap,

          containedInkWell: true,

          highlightShape: BoxShape.circle,

          radius: 20,

          splashColor: Colors.transparent,

          child: Center(
            child: AnimatedScale(
              duration: const Duration(milliseconds: 180),

              curve: Curves.easeOutBack,

              scale: selected ? 1 : .72,

              child: WrytteSvgIcon(
                asset: asset,

                size: selected ? 24 : 17,

                color: selected ? Colors.white : const Color(0xFF777A80),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
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
    return Semantics(
      button: true,

      enabled: onTap != null,

      label: tooltip,

      child: SizedBox.square(
        dimension: _ChatMediaPaintBottomBarState._roundButtonSize,

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
      ),
    );
  }
}
