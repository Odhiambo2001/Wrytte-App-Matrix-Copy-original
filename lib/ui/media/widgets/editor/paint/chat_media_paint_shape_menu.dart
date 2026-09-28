import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaPaintShapeMenuButton
    extends StatefulWidget {
  const ChatMediaPaintShapeMenuButton({
    super.key,
    required this.editor,
  });

  final PaintEditorState editor;

  @override
  State<ChatMediaPaintShapeMenuButton>
  createState() =>
      _ChatMediaPaintShapeMenuButtonState();
}

class _ChatMediaPaintShapeMenuButtonState
    extends State<ChatMediaPaintShapeMenuButton> {
  final LayerLink _layerLink =
      LayerLink();

  OverlayEntry? _overlayEntry;

  bool get _shapeSelected {
    final mode =
        widget.editor.paintMode;

    return mode ==
            PaintMode.custom1 ||
        mode ==
            PaintMode.circle ||
        mode ==
            PaintMode.custom2 ||
        mode ==
            PaintMode.arrow;
  }

  void _toggleMenu() {
    unawaited(
      HapticFeedback.selectionClick(),
    );

    if (_overlayEntry != null) {
      _closeMenu();
      return;
    }

    _openMenu();
  }

  void _openMenu() {
    final overlay =
        Overlay.of(
      context,
      rootOverlay: true,
    );

    late final OverlayEntry entry;

    entry = OverlayEntry(
      builder: (
        overlayContext,
      ) {
        return Stack(
          children: [
            Positioned.fill(
              child:
                  GestureDetector(
                behavior:
                    HitTestBehavior
                        .translucent,

                onTap:
                    _closeMenu,

                child:
                    const SizedBox
                        .expand(),
              ),
            ),

            CompositedTransformFollower(
              link:
                  _layerLink,

              showWhenUnlinked:
                  false,

              targetAnchor:
                  Alignment.topCenter,

              followerAnchor:
                  Alignment.bottomCenter,

              offset:
                  const Offset(
                0,
                -10,
              ),

              child:
                  _ShapeMenu(
                editor:
                    widget.editor,

                onSelected: (
                  mode,
                ) {
                  unawaited(
                    HapticFeedback
                        .selectionClick(),
                  );

                  widget.editor
                      .setMode(
                    mode,
                  );

                  _closeMenu();
                },
              ),
            ),
          ],
        );
      },
    );

    _overlayEntry =
        entry;

    overlay.insert(
      entry,
    );

    setState(() {});
  }

  void _closeMenu() {
    final entry =
        _overlayEntry;

    _overlayEntry = null;

    if (entry != null &&
        entry.mounted) {
      entry.remove();
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    final entry =
        _overlayEntry;

    _overlayEntry = null;

    if (entry != null &&
        entry.mounted) {
      entry.remove();
    }

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Expanded(
      child:
          CompositedTransformTarget(
        link:
            _layerLink,

        child:
            Semantics(
          button: true,
          selected:
              _shapeSelected,
          label:
              'Choose drawing shape',

          child:
              InkResponse(
            onTap:
                _toggleMenu,

            containedInkWell:
                true,

            highlightShape:
                BoxShape.circle,

            radius:
                24,

            splashColor:
                Colors.transparent,

            highlightColor:
                Colors.white
                    .withValues(
              alpha:
                  .035,
            ),

            child:
                Center(
              child:
                  Icon(
                Icons.add_rounded,
                size:
                    29,
                color:
                    _shapeSelected
                    ? widget
                        .editor
                        .activeColor
                    : WrytteColors
                        .textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShapeMenu
    extends StatelessWidget {
  const _ShapeMenu({
    required this.editor,
    required this.onSelected,
  });

  final PaintEditorState editor;

  final ValueChanged<PaintMode>
  onSelected;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Material(
      type:
          MaterialType
              .transparency,

      child: SizedBox(
        width:
            190,

        child:
            WrytteGlassSurface(
          borderRadius:
              BorderRadius.circular(
            26,
          ),

          blur:
              22,

          child:
              Material(
            type:
                MaterialType
                    .transparency,

            child:
                Padding(
              padding:
                  const EdgeInsets
                      .symmetric(
                vertical:
                    7,
              ),

              child:
                  Column(
                mainAxisSize:
                    MainAxisSize.min,

                children: [
                  _ShapeOption(
                    editor:
                        editor,

                    mode:
                        PaintMode
                            .custom1,

                    label:
                        'Square',

                    asset:
                        'assets/svg/Square icon .svg',

                    onSelected:
                        onSelected,
                  ),

                  _ShapeOption(
                    editor:
                        editor,

                    mode:
                        PaintMode
                            .circle,

                    label:
                        'Circle',

                    asset:
                        'assets/svg/Circle icon.svg',

                    onSelected:
                        onSelected,
                  ),

                  _ShapeOption(
                    editor:
                        editor,

                    mode:
                        PaintMode
                            .custom2,

                    label:
                        'Triangle',

                    asset:
                        'assets/svg/Triangle icon.svg',

                    onSelected:
                        onSelected,
                  ),

                  _ShapeOption(
                    editor:
                        editor,

                    mode:
                        PaintMode.arrow,

                    label:
                        'Arrow',

                    asset:
                        'assets/svg/Arrow icon .svg',

                    onSelected:
                        onSelected,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShapeOption
    extends StatelessWidget {
  const _ShapeOption({
    required this.editor,
    required this.mode,
    required this.label,
    required this.asset,
    required this.onSelected,
  });

  final PaintEditorState editor;

  final PaintMode mode;

  final String label;
  final String asset;

  final ValueChanged<PaintMode>
  onSelected;

  @override
  Widget build(
    BuildContext context,
  ) {
    final selected =
        editor.paintMode ==
            mode;

    return Semantics(
      button:
          true,

      selected:
          selected,

      label:
          label,

      child:
          InkWell(
        onTap: () {
          onSelected(
            mode,
          );
        },

        splashFactory:
            NoSplash
                .splashFactory,

        child:
            SizedBox(
          height:
              44,

          child:
              Padding(
            padding:
                const EdgeInsets
                    .symmetric(
              horizontal:
                  16,
            ),

            child:
                Row(
              children: [
                SizedBox.square(
                  dimension:
                      24,

                  child:
                      Center(
                    child:
                        WrytteSvgIcon(
                      asset:
                          asset,

                      size:
                          22,

                      color:
                          selected
                          ? editor
                              .activeColor
                          : WrytteColors
                              .textPrimary,
                    ),
                  ),
                ),

                const SizedBox(
                  width:
                      12,
                ),

                Expanded(
                  child:
                      Text(
                    label,

                    style:
                        TextStyle(
                      color:
                          WrytteColors
                              .textPrimary,

                      fontFamily:
                          WrytteTypography
                              .primaryFontFamily,

                      fontSize:
                          16,

                      fontWeight:
                          selected
                          ? FontWeight
                              .w600
                          : FontWeight
                              .w400,
                    ),
                  ),
                ),

                if (selected)
                  const Icon(
                    Icons
                        .check_rounded,
                    size:
                        18,
                    color:
                        WrytteColors
                            .primary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}