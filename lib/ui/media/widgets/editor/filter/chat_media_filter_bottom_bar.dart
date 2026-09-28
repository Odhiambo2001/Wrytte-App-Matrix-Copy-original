import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/media/widgets/editor/filter/chat_media_filter_preview.dart';
import 'package:wrytte/ui/media/widgets/editor/filter/chat_media_filter_session.dart';

class ChatMediaFilterBottomBar extends StatelessWidget {
  const ChatMediaFilterBottomBar({
    super.key,
    required this.editor,
    required this.session,
  });

  // ==========================================================================
  // OLD APPROVED FILTER GEOMETRY
  // ==========================================================================

  static const double contentHeight = 168;

  /// Exact old approved background:
  ///
  /// #23262C at 50% opacity.
  ///
  /// This panel intentionally does NOT use blur/glass.
  static const Color _background = Color(0x8023262C);

  /// About 5.4 filter items should fit across the viewport.
  ///
  /// The sixth item deliberately peeks in from the right.
  static const double _visibleItemCount = 5.4;

  static const double _horizontalPadding = 10;
  static const double _itemSpacing = 8;

  static const double _previewMinWidth = 46;

  final FilterEditorState editor;
  final ChatMediaFilterSession session;

  @override
  Widget build(BuildContext context) {
    final filters = session.availableFilters(editor);

    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: SizedBox(
        height: contentHeight,
        child: ColoredBox(
          color: _background,

          child: SizedBox(
            height: contentHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (filters.isEmpty) {
                  return const Center(
                    child: Text(
                      'No filters available',
                      style: TextStyle(
                        color: WrytteColors.textMuted,
                        fontFamily: WrytteTypography.primaryFontFamily,
                        fontSize: 14,
                      ),
                    ),
                  );
                }

                // ============================================================
                // EXACT OLD WIDTH CALCULATION
                // ============================================================
                //
                // The old implementation assumed roughly 6 visible spacing
                // positions while fitting ~5.4 cards.
                //
                // Do not center the row and do not spread items evenly.
                // The scroll view itself owns the horizontal positioning.

                final totalSpacing = _itemSpacing * 5;

                final availableItemsWidth =
                    constraints.maxWidth -
                    (_horizontalPadding * 2) -
                    totalSpacing;

                final itemWidth = math
                    .max(1.0, availableItemsWidth / _visibleItemCount)
                    .toDouble();

                // Old code allowed the preview itself up to 64px.
                //
                // This is important. The newer 58px cap made the cards look
                // narrower and caused the alignment to feel different.
                final previewWidth = (itemWidth - 4)
                    .clamp(_previewMinWidth, 64.0)
                    .toDouble();

                // Portrait 9:16 thumbnails.
                final previewHeight = previewWidth * 16 / 9;

                return ListView.separated(
                  scrollDirection: Axis.horizontal,

                  physics: const BouncingScrollPhysics(),

                  padding: const EdgeInsets.symmetric(
                    horizontal: _horizontalPadding,
                    vertical: 12,
                  ),

                  itemCount: filters.length,

                  separatorBuilder: (context, index) {
                    return const SizedBox(width: _itemSpacing);
                  },

                  itemBuilder: (context, index) {
                    final filter = filters[index];

                    final selected = session.sameFilter(
                      editor.selectedFilter,
                      filter,
                    );

                    final rawName = filter.name.trim();

                    final isFirstFilter = index == 0;

                    final label =
                        isFirstFilter && rawName.toLowerCase() == 'no filter'
                        ? 'Original'
                        : rawName;

                    return _FilterPreviewButton(
                      filter: filter,

                      label: label,

                      selected: selected,

                      itemWidth: itemWidth,

                      previewWidth: previewWidth,

                      previewHeight: previewHeight,

                      editorImage: editor.editorImage,

                      onTap: () {
                        unawaited(HapticFeedback.selectionClick());

                        editor.setFilter(filter);
                      },
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// FILTER ITEM
// =============================================================================

class _FilterPreviewButton extends StatelessWidget {
  const _FilterPreviewButton({
    required this.filter,
    required this.label,
    required this.selected,
    required this.itemWidth,
    required this.previewWidth,
    required this.previewHeight,
    required this.editorImage,
    required this.onTap,
  });

  final FilterModel filter;

  final String label;

  final bool selected;

  final double itemWidth;
  final double previewWidth;
  final double previewHeight;

  final EditorImage? editorImage;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,

      selected: selected,

      label: label,

      child: GestureDetector(
        behavior: HitTestBehavior.opaque,

        onTap: onTap,

        child: SizedBox(
          width: itemWidth,

          // IMPORTANT:
          //
          // Everything is top-aligned exactly like the old implementation.
          //
          // Don't center the entire card vertically inside the 168px panel.
          child: Column(
            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.center,

            children: [
              // =============================================================
              // FILTER NAME
              // =============================================================
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 150),

                curve: Curves.easeOutCubic,

                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: .72),

                  fontFamily: WrytteTypography.primaryFontFamily,

                  fontSize: 10,

                  height: 1,

                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                ),

                child: Text(
                  label,

                  maxLines: 1,

                  overflow: TextOverflow.ellipsis,

                  textAlign: TextAlign.center,
                ),
              ),

              // Exact old gap.
              const SizedBox(height: 9),

              // =============================================================
              // 9:16 FILTER PREVIEW
              // =============================================================
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),

                curve: Curves.easeOutCubic,

                width: previewWidth,

                height: previewHeight,

                // Selected card gets a stronger white edge.
                padding: EdgeInsets.all(selected ? 2 : 1),

                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: .16),

                  borderRadius: BorderRadius.circular(12),
                ),

                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),

                  child: SizedBox(
                    width: previewWidth,

                    height: previewHeight,

                    child: buildChatMediaFilteredPreview(
                      filter: filter,

                      editorImage: editorImage,
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
}
