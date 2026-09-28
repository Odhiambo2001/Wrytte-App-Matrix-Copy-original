import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

import 'package:wrytte/ui/media/widgets/editor/emoji/chat_media_emoji_sheet.dart';

class ChatMediaEditorBottomBar extends StatefulWidget {
  const ChatMediaEditorBottomBar({
    super.key,
    required this.editor,
    required this.cropActive,
    required this.filterActive,
    required this.isHd,
    required this.onQualityChanged,
  });

  /// Public layout contract used by ChatMediaEditorView.
  static const double height = 50;

  final ProImageEditorState editor;

  final bool cropActive;
  final bool filterActive;

  /// Current delivery quality preference.
  ///
  /// IMPORTANT:
  /// This is only UI state.
  ///
  /// Toggling it must NOT:
  /// - regenerate the image
  /// - resize the image
  /// - recompress the image
  /// - rebuild ProImageEditor
  ///
  /// Actual quality is applied later during final export.
  final bool isHd;

  final ValueChanged<bool> onQualityChanged;

  @override
  State<ChatMediaEditorBottomBar> createState() =>
      _ChatMediaEditorBottomBarState();
}

class _ChatMediaEditorBottomBarState
    extends State<ChatMediaEditorBottomBar> {
  static const double _radius = 25;

  bool _openingStickerSheet = false;

  // ==========================================================================
  // ACTIVE LAYER STATES
  // ==========================================================================

  bool get _hasPaintLayer {
    return widget.editor.activeLayers.any(
      (layer) => layer is PaintLayer,
    );
  }

  bool get _hasTextLayer {
    return widget.editor.activeLayers.any(
      (layer) => layer is TextLayer,
    );
  }

  bool get _hasStickerLayer {
    return widget.editor.activeLayers.any(
      (layer) => layer is EmojiLayer,
    );
  }

  // ==========================================================================
  // BASIC ACTION HELPER
  // ==========================================================================

  void _run(
    VoidCallback action,
  ) {
    unawaited(
      HapticFeedback.selectionClick(),
    );

    action();
  }

  // ==========================================================================
  // CROP
  // ==========================================================================

  void _openCrop() {
    _run(
      widget.editor.openCropRotateEditor,
    );
  }

  // ==========================================================================
  // DRAW
  // ==========================================================================

  void _openPaint() {
    _run(
      widget.editor.openPaintEditor,
    );
  }

  // ==========================================================================
  // TEXT
  // ==========================================================================

  void _openText() {
    _run(
      widget.editor.openTextEditor,
    );
  }

  // ==========================================================================
  // STICKER / EMOJI
  // ==========================================================================

  Future<void> _openSticker() async {
    if (!mounted ||
        _openingStickerSheet) {
      return;
    }

    setState(() {
      _openingStickerSheet = true;
    });

    try {
      await openChatMediaEmojiSheet(
        context: context,
        editor: widget.editor,
      );
    } catch (
      error,
      stackTrace
    ) {
      debugPrint(
        'Failed to open emoji picker: $error',
      );

      debugPrintStack(
        stackTrace: stackTrace,
      );
    } finally {
      if (!mounted) {
        return;
      }

      setState(() {
        _openingStickerSheet = false;
      });
    }
  }

  // ==========================================================================
  // FILTER
  // ==========================================================================

  void _openFilters() {
    _run(
      widget.editor.openFilterEditor,
    );
  }

  // ==========================================================================
  // HD / STANDARD QUALITY
  // ==========================================================================

  void _toggleQuality() {
    // This is intentionally cheap.
    //
    // We do NOT touch ProImageEditor here.
    //
    // The parent simply changes a ValueNotifier<bool>, which rebuilds this
    // small toolbar only. Actual image sizing/compression happens once at
    // final export.
    unawaited(
      HapticFeedback.selectionClick(),
    );

    widget.onQualityChanged(
      !widget.isHd,
    );
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    return SizedBox(
      height:
          ChatMediaEditorBottomBar.height,

      child:
          WrytteGlassSurface(
        borderRadius:
            BorderRadius.circular(
          _radius,
        ),

        blur:
            24,

        child:
            Material(
          type:
              MaterialType
                  .transparency,

          child:
              Row(
            children: [
              // ============================================================
              // CROP
              // ============================================================

              _EditorToolButton(
                asset:
                    'assets/svg/Crop icon.svg',

                semanticLabel:
                    'Crop',

                selected:
                    widget.cropActive,

                onPressed:
                    _openCrop,
              ),

              // ============================================================
              // DRAW
              // ============================================================

              _EditorToolButton(
                asset:
                    'assets/svg/Draw icon.svg',

                semanticLabel:
                    'Draw',

                selected:
                    _hasPaintLayer,

                onPressed:
                    _openPaint,
              ),

              // ============================================================
              // TEXT
              // ============================================================

              _EditorToolButton(
                asset:
                    'assets/svg/Text icon.svg',

                semanticLabel:
                    'Text',

                selected:
                    _hasTextLayer,

                onPressed:
                    _openText,
              ),

              // ============================================================
              // STICKER / EMOJI
              // ============================================================

              _EditorToolButton(
                asset:
                    'assets/svg/Sticker icon.svg',

                semanticLabel:
                    'Sticker',

                selected:
                    _hasStickerLayer,

                temporarilyDisabled:
                    _openingStickerSheet,

                onPressed: () {
                  unawaited(
                    _openSticker(),
                  );
                },
              ),

              // ============================================================
              // FILTERS
              // ============================================================

              _EditorToolButton(
                asset:
                    'assets/svg/Photo filter .svg',

                semanticLabel:
                    'Filters',

                selected:
                    widget.filterActive,

                iconSize:
                    26,

                iconScale:
                    1.08,

                onPressed:
                    _openFilters,
              ),

              // ============================================================
              // HD / STANDARD
              // ============================================================

              _QualityButton(
                isHd:
                    widget.isHd,

                onPressed:
                    _toggleQuality,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// NORMAL TOOL BUTTON
// =============================================================================

class _EditorToolButton
    extends StatelessWidget {
  const _EditorToolButton({
    required this.asset,
    required this.semanticLabel,
    required this.onPressed,
    this.selected = false,
    this.temporarilyDisabled = false,
    this.iconSize = 24,
    this.iconScale = .98,
  });

  final String asset;
  final String semanticLabel;

  final VoidCallback onPressed;

  final bool selected;
  final bool temporarilyDisabled;

  final double iconSize;
  final double iconScale;

  @override
  Widget build(
    BuildContext context,
  ) {
    final baseColor =
        selected
            ? WrytteColors.primary
            : WrytteColors.textPrimary;

    final color =
        temporarilyDisabled
            ? baseColor.withValues(
                alpha: .48,
              )
            : baseColor;

    return Expanded(
      child:
          Semantics(
        button:
            true,

        selected:
            selected,

        enabled:
            !temporarilyDisabled,

        label:
            semanticLabel,

        child:
            InkResponse(
          onTap:
              temporarilyDisabled
              ? null
              : onPressed,

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
              SizedBox.expand(
            child:
                Center(
              child:
                  AnimatedScale(
                duration:
                    const Duration(
                  milliseconds:
                      150,
                ),

                curve:
                    Curves.easeOutCubic,

                scale:
                    temporarilyDisabled
                    ? .90
                    : 1,

                child:
                    Transform.scale(
                  scale:
                      iconScale,

                  child:
                      WrytteSvgIcon(
                    asset:
                        asset,

                    size:
                        iconSize,

                    color:
                        color,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// HD / STANDARD QUALITY BUTTON
// =============================================================================

class _QualityButton
    extends StatelessWidget {
  const _QualityButton({
    required this.isHd,
    required this.onPressed,
  });

  final bool isHd;

  final VoidCallback onPressed;

  @override
  Widget build(
    BuildContext context,
  ) {
    final asset =
        isHd
            ? 'assets/svg/Hd icon .svg'
            : 'assets/svg/Sd icon.svg';

    return Expanded(
      child:
          Semantics(
        button:
            true,

        toggled:
            isHd,

        label:
            isHd
            ? 'HD quality'
            : 'Standard quality',

        hint:
            isHd
            ? 'Tap to use standard delivery quality'
            : 'Tap to use HD delivery quality',

        child:
            InkResponse(
          onTap:
              onPressed,

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
                AnimatedSwitcher(
              duration:
                  const Duration(
                milliseconds:
                    220,
              ),

              reverseDuration:
                  const Duration(
                milliseconds:
                    180,
              ),

              switchInCurve:
                  Curves.easeOutCubic,

              switchOutCurve:
                  Curves.easeInCubic,

              transitionBuilder: (
                child,
                animation,
              ) {
                // Keep this animation deliberately cheap.
                //
                // No rotation and no heavy layout changes are needed here.
                // Only opacity + a very small scale transition.
                final scale =
                    Tween<double>(
                  begin:
                      .86,

                  end:
                      1,
                ).animate(
                  CurvedAnimation(
                    parent:
                        animation,

                    curve:
                        Curves.easeOutCubic,
                  ),
                );

                return FadeTransition(
                  opacity:
                      animation,

                  child:
                      ScaleTransition(
                    scale:
                        scale,

                    child:
                        child,
                  ),
                );
              },

              child:
                  KeyedSubtree(
                key:
                    ValueKey<bool>(
                  isHd,
                ),

                child:
                    WrytteSvgIcon(
                  asset:
                      asset,

                  size:
                      24,

                  color:
                      WrytteColors
                          .textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}