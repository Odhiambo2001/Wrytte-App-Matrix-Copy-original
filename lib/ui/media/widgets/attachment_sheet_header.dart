import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/media/widgets/media_gallery_tokens.dart';

class AttachmentSheetHeader extends StatelessWidget {
  const AttachmentSheetHeader({
    super.key,
    required this.albumName,
    required this.menuOpen,
    required this.onClose,
    this.onAlbumPressed,
    required this.expansionProgress,
    required this.scrollProgress,
    required this.onVerticalDragStart,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
    required this.onVerticalDragCancel,
    this.selectedCount = 0,
    this.onMorePressed,
    this.showSend = false,
    this.onSend,
    this.sendEnabled = false,
    this.showSearch = false,
    this.onSearchPressed,
  });

  final String albumName;

  final bool menuOpen;

  final VoidCallback onClose;
  final VoidCallback? onAlbumPressed;

  final double expansionProgress;
  final double scrollProgress;

  final GestureDragStartCallback
  onVerticalDragStart;

  final GestureDragUpdateCallback
  onVerticalDragUpdate;

  final GestureDragEndCallback
  onVerticalDragEnd;

  final GestureDragCancelCallback
  onVerticalDragCancel;

  final int selectedCount;

  /// Optional future attachment-selection menu.
  ///
  /// If no action has been connected yet, the button still keeps the old
  /// interaction/haptic instead of doing something unexpected.
  final VoidCallback? onMorePressed;
  final bool showSend;
  final VoidCallback? onSend;
  final bool sendEnabled;
  final bool showSearch;
  final VoidCallback? onSearchPressed;

  @override
  Widget build(BuildContext context) {
    final widthProgress =
        ((MediaQuery.sizeOf(context).shortestSide -
                    320) /
                152)
            .clamp(
              0.0,
              1.0,
            )
            .toDouble();

    final scale =
        .90 +
        (.10 * widthProgress);

    final controlSize =
        42 +
        (2 * widthProgress);

    final horizontalPadding =
        8 +
        (2 * widthProgress);

    final headerHeight =
        60 +
        (6 * widthProgress);

    final overlayHeight =
        84 +
        (6 * widthProgress);

    final expansion =
        expansionProgress
            .clamp(
              0.0,
              1.0,
            )
            .toDouble();

    final galleryScroll =
        scrollProgress
            .clamp(
              0.0,
              1.0,
            )
            .toDouble();

    final transitionInput =
        ((expansion - .48) / .40)
            .clamp(
              0.0,
              1.0,
            )
            .toDouble();

    final backgroundTransition =
        Curves.easeInOutCubic.transform(
      transitionInput,
    );

    final glassStrength =
        backgroundTransition >
                galleryScroll
            ? backgroundTransition
            : galleryScroll;

    final expansionBlur =
        .25 * expansion;

    final blurStrength =
        expansionBlur >
                glassStrength
            ? expansionBlur
            : glassStrength;

    return SizedBox(
      height:
          overlayHeight,

      child:
          Stack(
        clipBehavior:
            Clip.none,

        children: [
          // ===============================================================
          // HEADER BLUR
          // ===============================================================

          Positioned.fill(
            child:
                IgnorePointer(
              child:
                  ShaderMask(
                blendMode:
                    BlendMode.dstIn,

                shaderCallback:
                    (bounds) {
                  return LinearGradient(
                    begin:
                        Alignment
                            .topCenter,

                    end:
                        Alignment
                            .bottomCenter,

                    stops:
                        const [
                      0,
                      .44,
                      .56,
                      .68,
                      .78,
                      .85,
                      1,
                    ],

                    colors: [
                      Colors.white
                          .withValues(
                        alpha:
                            blurStrength,
                      ),

                      Colors.white
                          .withValues(
                        alpha:
                            blurStrength,
                      ),

                      Colors.white
                          .withValues(
                        alpha:
                            .82 *
                            blurStrength,
                      ),

                      Colors.white
                          .withValues(
                        alpha:
                            .43 *
                            blurStrength,
                      ),

                      Colors.white
                          .withValues(
                        alpha:
                            .12 *
                            blurStrength,
                      ),

                      Colors.transparent,

                      Colors.transparent,
                    ],
                  ).createShader(
                    bounds,
                  );
                },

                child:
                    BackdropFilter(
                  filter:
                      ImageFilter.blur(
                    sigmaX:
                        32,

                    sigmaY:
                        32,

                    tileMode:
                        TileMode.clamp,
                  ),

                  blendMode:
                      BlendMode.srcOver,

                  child:
                      const SizedBox
                          .expand(),
                ),
              ),
            ),
          ),

          // ===============================================================
          // HEADER BACKGROUND
          // ===============================================================

          Positioned.fill(
            child:
                IgnorePointer(
              child:
                  Opacity(
                opacity:
                    glassStrength,

                child:
                    const DecoratedBox(
                  decoration:
                      BoxDecoration(
                    gradient:
                        LinearGradient(
                      begin:
                          Alignment
                              .topCenter,

                      end:
                          Alignment
                              .bottomCenter,

                      stops: [
                        0,
                        .22,
                        .44,
                        .62,
                        .76,
                        .88,
                        1,
                      ],

                      colors: [
                        Color.fromRGBO(
                          2,
                          3,
                          5,
                          .985,
                        ),

                        Color.fromRGBO(
                          3,
                          4,
                          7,
                          .960,
                        ),

                        Color.fromRGBO(
                          5,
                          7,
                          10,
                          .870,
                        ),

                        Color.fromRGBO(
                          6,
                          8,
                          12,
                          .650,
                        ),

                        Color.fromRGBO(
                          6,
                          8,
                          12,
                          .400,
                        ),

                        Color.fromRGBO(
                          6,
                          8,
                          12,
                          .120,
                        ),

                        Color.fromRGBO(
                          6,
                          8,
                          12,
                          0,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ===============================================================
          // INTERACTIVE HEADER
          // ===============================================================

          Positioned(
            top:
                0,

            left:
                0,

            right:
                0,

            height:
                headerHeight,

            child:
                GestureDetector(
              key:
                  const ValueKey(
                'attachment-drag-header',
              ),

              behavior:
                  HitTestBehavior
                      .translucent,

              onVerticalDragStart:
                  onVerticalDragStart,

              onVerticalDragUpdate:
                  onVerticalDragUpdate,

              onVerticalDragEnd:
                  onVerticalDragEnd,

              onVerticalDragCancel:
                  onVerticalDragCancel,

              child:
                  DecoratedBox(
                decoration:
                    BoxDecoration(
                  color:
                      WrytteColors
                          .surfaceRaised
                          .withValues(
                    alpha:
                        1 -
                        backgroundTransition,
                  ),

                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black
                              .withValues(
                        alpha:
                            .30 *
                            glassStrength,
                      ),

                      blurRadius:
                          20 *
                          glassStrength,

                      spreadRadius:
                          1.5 *
                          glassStrength,

                      offset:
                          Offset(
                        0,
                        7 *
                            glassStrength,
                      ),
                    ),
                  ],
                ),

                child:
                    Padding(
                  padding:
                      EdgeInsets.fromLTRB(
                    horizontalPadding,
                    10 * scale,
                    horizontalPadding,
                    6 * scale,
                  ),

                  child:
                      Stack(
                    alignment:
                        Alignment.center,

                    clipBehavior:
                        Clip.none,

                    children: [
                      // =====================================================
                      // DRAG HANDLE
                      // =====================================================

                      Positioned(
                        top:
                            -1,

                        child:
                            Container(
                          width:
                              56 *
                              scale,

                          height:
                              4 *
                              scale,

                          decoration:
                              BoxDecoration(
                            color:
                                Colors.white
                                    .withValues(
                              alpha:
                                  .36 +
                                  (.12 *
                                      expansion),
                            ),

                            borderRadius:
                                BorderRadius
                                    .circular(
                              4,
                            ),
                          ),
                        ),
                      ),

                      // =====================================================
                      // CLOSE
                      // =====================================================

                      Align(
                        alignment:
                            AlignmentDirectional
                                .centerStart,

                        child:
                            _CloseButton(
                          size:
                              controlSize,

                          scale:
                              scale,

                          onPressed:
                              onClose,
                        ),
                      ),

                      // =====================================================
                      // ALBUM
                      // =====================================================

                      Semantics(
                        button:
                            onAlbumPressed !=
                            null,

                        expanded:
                            menuOpen,

                        label:
                            'Choose album, current album $albumName',

                        child:
                            InkWell(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            22,
                          ),

                          onTap:
                              onAlbumPressed,

                          splashFactory:
                              NoSplash
                                  .splashFactory,

                          child:
                              Padding(
                            padding:
                                const EdgeInsets
                                    .symmetric(
                              horizontal:
                                  12,

                              vertical:
                                  10,
                            ),

                            child:
                                Row(
                              mainAxisSize:
                                  MainAxisSize
                                      .min,

                              children: [
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(
                                    maxWidth:
                                        190,
                                  ),

                                  child:
                                      Text(
                                    albumName,

                                    maxLines:
                                        1,

                                    overflow:
                                        TextOverflow
                                            .ellipsis,

                                    style:
                                        const TextStyle(
                                      color:
                                          WrytteColors
                                              .textPrimary,

                                      fontFamily:
                                          WrytteTypography
                                              .primaryFontFamily,

                                      fontSize:
                                          16,

                                      height:
                                          1,

                                      fontWeight:
                                          FontWeight
                                              .w600,
                                    ),
                                  ),
                                ),

                                if (onAlbumPressed !=
                                    null) ...[
                                  const SizedBox(
                                    width:
                                        6,
                                  ),

                                  AnimatedRotation(
                                    turns:
                                        menuOpen
                                        ? .5
                                        : 0,

                                    duration:
                                        MediaQuery
                                            .disableAnimationsOf(
                                              context,
                                            )
                                        ? Duration
                                            .zero
                                        : MediaGalleryTokens
                                            .menuDuration,

                                    curve:
                                        Curves
                                            .easeOutCubic,

                                    child:
                                        Icon(
                                      Icons
                                          .keyboard_arrow_down_rounded,

                                      color:
                                          Colors.white
                                              .withValues(
                                        alpha:
                                            .76,
                                      ),

                                      size:
                                          20,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),

                      // =====================================================
                      // COUNT + OLD THREE-DOT BUTTON
                      // =====================================================

                      Align(
                        alignment:
                            AlignmentDirectional
                                .centerEnd,

                        child:
                            _SelectionHeaderActions(
                          selectedCount:
                              selectedCount,

                          scale:
                              scale,

                          onMorePressed:
                              onMorePressed,
                          showSend: showSend,
                          onSend: onSend,
                          sendEnabled: sendEnabled,
                          showSearch: showSearch,
                          onSearchPressed: onSearchPressed,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SELECTION HEADER ACTIONS
// =============================================================================

class _SelectionHeaderActions
    extends StatelessWidget {
  const _SelectionHeaderActions({
    required this.selectedCount,
    required this.scale,
    required this.onMorePressed,
    this.showSend = false,
    this.onSend,
    this.sendEnabled = false,
    this.showSearch = false,
    this.onSearchPressed,
  });

  final int selectedCount;
  final double scale;

  final VoidCallback? onMorePressed;
  final bool showSend;
  final VoidCallback? onSend;
  final bool sendEnabled;
  final bool showSearch;
  final VoidCallback? onSearchPressed;

  @override
  Widget build(BuildContext context) {
    if (showSend) {
      return _HeaderSendButton(
        enabled: sendEnabled,
        onPressed: onSend,
        scale: scale,
      );
    }

    final reduceMotion =
        MediaQuery.disableAnimationsOf(
      context,
    );

    if (showSearch) {
      return _HeaderCircleButton(
        icon: Icons.search_rounded,
        scale: scale,
        onPressed: onSearchPressed,
      );
    }

    return AnimatedSwitcher(
      duration:
          reduceMotion
          ? Duration.zero
          : const Duration(
              milliseconds: 240,
            ),

      reverseDuration:
          reduceMotion
          ? Duration.zero
          : const Duration(
              milliseconds: 190,
            ),

      switchInCurve:
          Curves.easeOutCubic,

      switchOutCurve:
          Curves.easeInCubic,

      transitionBuilder: (
        child,
        animation,
      ) {
        return FadeTransition(
          opacity:
              animation,

          child:
              ScaleTransition(
            alignment:
                Alignment.centerRight,

            scale:
                Tween<double>(
              begin:
                  .82,

              end:
                  1,
            ).animate(
              animation,
            ),

            child:
                child,
          ),
        );
      },

      child:
          selectedCount <= 0
          ? const SizedBox.shrink(
              key:
                  ValueKey<String>(
                'no-selection',
              ),
            )
          : Row(
              key:
                  const ValueKey<String>(
                'selection-actions',
              ),

              mainAxisSize:
                  MainAxisSize.min,

              children: [
                // =========================================================
                // COUNT
                // =========================================================

                AnimatedSwitcher(
                  duration:
                      reduceMotion
                      ? Duration.zero
                      : const Duration(
                          milliseconds:
                              180,
                        ),

                  transitionBuilder: (
                    child,
                    animation,
                  ) {
                    return ScaleTransition(
                      scale:
                          animation,

                      child:
                          FadeTransition(
                        opacity:
                            animation,

                        child:
                            child,
                      ),
                    );
                  },

                  child:
                      Container(
                    key:
                        ValueKey<int>(
                      selectedCount,
                    ),

                    width:
                        32 *
                        scale,

                    height:
                        32 *
                        scale,

                    alignment:
                        Alignment.center,

                    decoration:
                        const BoxDecoration(
                      color:
                          WrytteColors
                              .primary,

                      shape:
                          BoxShape.circle,
                    ),

                    child:
                        Text(
                      '$selectedCount',

                      style:
                          const TextStyle(
                        color:
                            Colors.white,

                        fontFamily:
                            WrytteTypography
                                .primaryFontFamily,

                        fontSize:
                            15,

                        height:
                            1,

                        fontWeight:
                            FontWeight
                                .w600,
                      ),
                    ),
                  ),
                ),

                // Exact spacing from the old header.
                SizedBox(
                  width:
                      19 *
                      scale,
                ),

                // =========================================================
                // OLD THREE-DOT GLASS BUTTON
                // =========================================================

                Semantics(
                  button:
                      true,

                  label:
                      'More attachment options',

                  child:
                      SizedBox.square(
                    dimension:
                        40 *
                        scale,

                    child:
                        WrytteGlassSurface(
                      borderRadius:
                          BorderRadius.circular(
                        20 *
                        scale,
                      ),

                      // Same blur amount used by the old header.
                      blur:
                          18,

                      child:
                          Material(
                        type:
                            MaterialType
                                .transparency,

                        child:
                            InkResponse(
                          onTap:
                              () {
                            unawaited(
                              HapticFeedback
                                  .selectionClick(),
                            );

                            onMorePressed
                                ?.call();
                          },

                          containedInkWell:
                              true,

                          highlightShape:
                              BoxShape.circle,

                          radius:
                              20 *
                              scale,

                          splashColor:
                              Colors
                                  .transparent,

                          highlightColor:
                              Colors.white
                                  .withValues(
                            alpha:
                                .04,
                          ),

                          child:
                              Center(
                            child:
                                Icon(
                              // Exact old icon.
                              Icons
                                  .more_horiz_rounded,

                              // Exact old size relationship.
                              size:
                                  23 *
                                  scale,

                              color:
                                  WrytteColors
                                      .textPrimary,
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
  }
}

class _HeaderSendButton extends StatelessWidget {
  const _HeaderSendButton({
    required this.enabled,
    required this.onPressed,
    required this.scale,
  });

  final bool enabled;
  final VoidCallback? onPressed;
  final double scale;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF17191E).withValues(alpha: .88),
    borderRadius: BorderRadius.circular(28),
    child: InkWell(
      onTap: enabled ? onPressed : null,
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        width: 70,
        height: 58,
        child: Center(
          child: Text(
            'Send',
            style: TextStyle(
              fontFamily: WrytteTypography.primaryFontFamily,
              color: enabled
                  ? const Color(0xFFE9EBEF)
                  : const Color(0xFF5D616A),
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    ),
  );
}

// =============================================================================
// CLOSE
// =============================================================================

class _HeaderCircleButton extends StatelessWidget {
  const _HeaderCircleButton({
    required this.icon,
    required this.scale,
    required this.onPressed,
  });

  final IconData icon;
  final double scale;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF17191E).withValues(alpha: .88),
    shape: const CircleBorder(),
    child: InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: 42 + (20 * (scale - .9)),
        height: 42 + (20 * (scale - .9)),
        child: Icon(icon, color: Colors.white, size: 26 * scale),
      ),
    ),
  );
}

class _CloseButton
    extends StatelessWidget {
  const _CloseButton({
    required this.size,
    required this.scale,
    required this.onPressed,
  });

  final double size;
  final double scale;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button:
          true,

      label:
          'Close gallery',

      child:
          ClipOval(
        child:
            BackdropFilter(
          filter:
              ImageFilter.blur(
            sigmaX:
                18,

            sigmaY:
                18,
          ),

          child:
              Material(
            color:
                Colors.transparent,

            child:
                InkWell(
              onTap:
                  onPressed,

              splashFactory:
                  NoSplash
                      .splashFactory,

              child:
                  Container(
                width:
                    size,

                height:
                    size,

                alignment:
                    Alignment.center,

                decoration:
                    BoxDecoration(
                  color:
                      const Color(
                    0xFF17191E,
                  ).withValues(
                    alpha:
                        .88,
                  ),

                  shape:
                      BoxShape.circle,

                  border:
                      Border.all(
                    color:
                        Colors.white
                            .withValues(
                      alpha:
                          .08,
                    ),

                    width:
                        .8,
                  ),
                ),

                child:
                    Icon(
                  Icons
                      .close_rounded,

                  size:
                      26 *
                      scale,

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
