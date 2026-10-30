import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

Future<void> openChatMediaEmojiSheet({
  required BuildContext context,
  required ProImageEditorState editor,
}) async {
  if (!editor.mounted) {
    return;
  }

  unawaited(
    HapticFeedback.selectionClick(),
  );

  // The main PIE editor listens for keyboard input itself.
  //
  // Temporarily remove that listener while our emoji sheet / search field
  // owns keyboard focus.
  editor.removeKeyEventListener();

  try {
    final layer =
        await showModalBottomSheet<Layer>(
      context: context,

      useRootNavigator: true,

      isScrollControlled: true,

      useSafeArea: false,

      enableDrag: true,

      showDragHandle: false,

      backgroundColor: Colors.transparent,

      barrierColor:
          Colors.black.withValues(
        alpha: .16,
      ),

      clipBehavior: Clip.none,

      builder: (
        sheetContext,
      ) {
        return _ChatMediaEmojiSheet(
          editor: editor,
        );
      },
    );

    if (layer == null ||
        !editor.mounted) {
      return;
    }

    if (layer is! WidgetLayer) {
      layer.scale =
          editor
              .configs
              .emojiEditor
              .initScale;
    }

    // The selected emoji becomes a real PIE layer.
    //
    // Undo / redo / drag / rotate / scale / export all continue to work.
    editor.addLayer(
      layer,
    );

    unawaited(
      HapticFeedback.lightImpact(),
    );
  } finally {
    if (editor.mounted) {
      editor.initKeyEventListener();
    }
  }
}

class _ChatMediaEmojiSheet
    extends StatefulWidget {
  const _ChatMediaEmojiSheet({
    required this.editor,
  });

  final ProImageEditorState editor;

  @override
  State<_ChatMediaEmojiSheet>
      createState() =>
          _ChatMediaEmojiSheetState();
}

class _ChatMediaEmojiSheetState
    extends State<_ChatMediaEmojiSheet> {
  static const BorderRadius _panelRadius =
      BorderRadius.vertical(
    top: Radius.circular(
      30,
    ),
  );

  final GlobalKey<EmojiEditorState>
      _emojiEditorKey =
      GlobalKey<EmojiEditorState>();

  final TextEditingController
      _searchController =
      TextEditingController();

  final FocusNode _searchFocusNode =
      FocusNode();

  bool _searchHasText = false;

  // ==========================================================================
  // SEARCH
  // ==========================================================================

  void _search(
    String value,
  ) {
    final hasText =
        value.trim().isNotEmpty;

    if (_searchHasText != hasText) {
      setState(() {
        _searchHasText = hasText;
      });
    }

    // PIE 14.3 exposes this specifically for external/custom search fields.
    _emojiEditorKey.currentState
        ?.externSearch(
      value,
    );
  }

  void _clearSearch() {
    if (_searchController.text.isEmpty) {
      return;
    }

    unawaited(
      HapticFeedback.selectionClick(),
    );

    _searchController.clear();

    _search(
      '',
    );

    _searchFocusNode.requestFocus();
  }

  void _close() {
    unawaited(
      HapticFeedback.selectionClick(),
    );

    Navigator.of(
      context,
    ).maybePop();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();

    super.dispose();
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final media =
        MediaQuery.of(
      context,
    );

    final keyboardInset =
        media.viewInsets.bottom;

    final keyboardVisible =
        keyboardInset > 0;

    final bottomSafeInset =
        keyboardVisible
            ? 0.0
            : media.viewPadding.bottom;

    // ------------------------------------------------------------------------
    // PANEL HEIGHT
    // ------------------------------------------------------------------------
    //
    // Responsive to:
    //
    // - normal portrait phones
    // - short phones
    // - landscape
    // - search keyboard
    //
    // The photo always remains visible above the sheet.

    final availableHeight =
        math.max(
      1.0,
      media.size.height -
          media.viewPadding.top -
          keyboardInset -
          10,
    );

    final preferredHeight =
        media.size.height * .62;

    final maximumHeight =
        math.min(
      590.0,
      availableHeight,
    );

    final minimumHeight =
        math.min(
      320.0,
      maximumHeight,
    );

    final panelHeight =
        preferredHeight
            .clamp(
              minimumHeight,
              maximumHeight,
            )
            .toDouble();

    return AnimatedPadding(
      duration: const Duration(
        milliseconds: 220,
      ),

      curve:
          Curves.easeOutCubic,

      padding:
          EdgeInsets.only(
        bottom:
            keyboardInset,
      ),

      child: Align(
        alignment:
            Alignment.bottomCenter,

        child: SizedBox(
          width:
              double.infinity,

          height:
              panelHeight,

          child:
              WrytteGlassSurface(
            borderRadius:
                _panelRadius,

            // Larger panel => slightly stronger blur than toolbar pills.
            blur:
                30,

            child:
                ClipRRect(
              borderRadius:
                  _panelRadius,

              child:
                  Material(
                type:
                    MaterialType
                        .transparency,

                child:
                    Column(
                  children: [
                    // ======================================================
                    // DRAG HANDLE
                    // ======================================================

                    const SizedBox(
                      height:
                          10,
                    ),

                    Container(
                      width:
                          38,

                      height:
                          4,

                      decoration:
                          BoxDecoration(
                        color:
                            Colors.white
                                .withValues(
                          alpha:
                              .65,
                        ),

                        borderRadius:
                            BorderRadius.circular(
                          4,
                        ),
                      ),
                    ),

                    const SizedBox(
                      height:
                          5,
                    ),

                    // ======================================================
                    // HEADER
                    // ======================================================

                    SizedBox(
                      height:
                          42,

                      child:
                          Padding(
                        padding:
                            const EdgeInsetsDirectional
                                .only(
                          start:
                              18,
                          end:
                              8,
                        ),

                        child:
                            Row(
                          children: [
                            const Expanded(
                              child:
                                  Text(
                                'Emoji',

                                maxLines:
                                    1,

                                overflow:
                                    TextOverflow
                                        .ellipsis,

                                style:
                                    TextStyle(
                                  color:
                                      WrytteColors
                                          .textPrimary,

                                  fontFamily:
                                      WrytteTypography
                                          .primaryFontFamily,

                                  fontSize:
                                      17,

                                  fontWeight:
                                      FontWeight
                                          .w600,

                                  height:
                                      1,
                                ),
                              ),
                            ),

                            Semantics(
                              button:
                                  true,

                              label:
                                  'Close emoji picker',

                              child:
                                  InkResponse(
                                onTap:
                                    _close,

                                containedInkWell:
                                    true,

                                highlightShape:
                                    BoxShape
                                        .circle,

                                radius:
                                    20,

                                splashColor:
                                    Colors
                                        .transparent,

                                highlightColor:
                                    Colors.white
                                        .withValues(
                                  alpha:
                                      .05,
                                ),

                                child:
                                    const SizedBox.square(
                                  dimension:
                                      38,

                                  child:
                                      Icon(
                                    Icons
                                        .close_rounded,

                                    size:
                                        23,

                                    color:
                                        WrytteColors
                                            .textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ======================================================
                    // PERMANENT WRYTTE SEARCH BAR
                    // ======================================================
                    //
                    // Unlike the previous version this is always visible.
                    //
                    // It does NOT fake filtering. Every character is passed
                    // directly into PIE's real emoji search engine through
                    // EmojiEditorState.externSearch().

                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(
                        12,
                        3,
                        12,
                        10,
                      ),

                      child:
                          SizedBox(
                        height:
                            46,

                        child:
                            WrytteGlassSurface(
                          borderRadius:
                              BorderRadius.circular(
                            23,
                          ),

                          blur:
                              18,

                          color:
                              const Color(
                            0x8A111318,
                          ),

                          child:
                              Material(
                            type:
                                MaterialType
                                    .transparency,

                            child:
                                TextField(
                              controller:
                                  _searchController,

                              focusNode:
                                  _searchFocusNode,

                              onChanged:
                                  _search,

                              autocorrect:
                                  false,

                              enableSuggestions:
                                  false,

                              textInputAction:
                                  TextInputAction
                                      .search,

                              keyboardType:
                                  TextInputType
                                      .text,

                              cursorColor:
                                  WrytteColors
                                      .primary,

                              style:
                                  const TextStyle(
                                color:
                                    WrytteColors
                                        .textPrimary,

                                fontFamily:
                                    WrytteTypography
                                        .primaryFontFamily,

                                fontSize:
                                    15,

                                fontWeight:
                                    FontWeight
                                        .w400,

                                height:
                                    1.2,
                              ),

                              decoration:
                                  InputDecoration(
                                hintText:
                                    'Search emoji',

                                hintStyle:
                                    const TextStyle(
                                  color:
                                      WrytteColors
                                          .textMuted,

                                  fontFamily:
                                      WrytteTypography
                                          .primaryFontFamily,

                                  fontSize:
                                      15,

                                  fontWeight:
                                      FontWeight
                                          .w400,
                                ),

                                border:
                                    InputBorder
                                        .none,

                                enabledBorder:
                                    InputBorder
                                        .none,

                                focusedBorder:
                                    InputBorder
                                        .none,

                                isDense:
                                    true,

                                contentPadding:
                                    const EdgeInsets.symmetric(
                                  vertical:
                                      13,
                                ),

                                prefixIcon:
                                    const Icon(
                                  Icons
                                      .search_rounded,

                                  size:
                                      21,

                                  color:
                                      WrytteColors
                                          .textMuted,
                                ),

                                prefixIconConstraints:
                                    const BoxConstraints(
                                  minWidth:
                                      44,

                                  minHeight:
                                      44,
                                ),

                                suffixIcon:
                                    _searchHasText
                                    ? Semantics(
                                        button:
                                            true,

                                        label:
                                            'Clear search',

                                        child:
                                            IconButton(
                                          onPressed:
                                              _clearSearch,

                                          visualDensity:
                                              VisualDensity
                                                  .compact,

                                          splashColor:
                                              Colors
                                                  .transparent,

                                          highlightColor:
                                              Colors.white
                                                  .withValues(
                                            alpha:
                                                .04,
                                          ),

                                          icon:
                                              const Icon(
                                            Icons
                                                .close_rounded,

                                            size:
                                                19,

                                            color:
                                                WrytteColors
                                                    .textSecondary,
                                          ),
                                        ),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ======================================================
                    // REAL PIE EMOJI EDITOR
                    // ======================================================

                    Expanded(
                        child: EmojiEditor(
                          key:
                              _emojiEditorKey,

                          configs:
                              widget
                                  .editor
                                  .configs,

                          callbacks:
                              widget
                                  .editor
                                  .callbacks,
                      ),
                    ),

                    // ======================================================
                    // PHONE SAFE AREA
                    // ======================================================

                    SizedBox(
                      height:
                          bottomSafeInset,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
