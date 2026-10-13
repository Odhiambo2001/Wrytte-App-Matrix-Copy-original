import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatForwardHeader extends StatelessWidget {
  const ChatForwardHeader({
    super.key,
    required this.selectedCount,
    required this.searchActive,
    required this.searchQuery,
    required this.searchController,
    required this.searchFocusNode,
    required this.expansionProgress,
    required this.scrollProgress,
    required this.onClose,
    required this.onSearchPressed,
    required this.onSearchClosed,
    required this.onSearchChanged,
    required this.onSearchCleared,
    required this.onVerticalDragStart,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
    required this.onVerticalDragCancel,
  });

  final int selectedCount;
  final bool searchActive;
  final String searchQuery;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final double expansionProgress;
  final double scrollProgress;
  final VoidCallback onClose;
  final VoidCallback onSearchPressed;
  final VoidCallback onSearchClosed;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchCleared;
  final GestureDragStartCallback onVerticalDragStart;
  final GestureDragUpdateCallback onVerticalDragUpdate;
  final GestureDragEndCallback onVerticalDragEnd;
  final GestureDragCancelCallback onVerticalDragCancel;

  static const Duration _switchDuration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final widthProgress =
        ((MediaQuery.sizeOf(context).shortestSide - 320) / 152)
            .clamp(0.0, 1.0)
            .toDouble();

    final scale = .90 + (.10 * widthProgress);
    final controlSize = 42 + (2 * widthProgress);
    final horizontalPadding = 8 + (2 * widthProgress);
    final headerHeight = 60 + (6 * widthProgress);
    final overlayHeight = 84 + (6 * widthProgress);

    // Keep the exact same compact -> expanded header treatment used by the
    // normal attachment sheet.
    final expansion = expansionProgress.clamp(0.0, 1.0).toDouble();
    final contentScroll = scrollProgress.clamp(0.0, 1.0).toDouble();
    final transitionInput = ((expansion - .48) / .40).clamp(0.0, 1.0).toDouble();
    final backgroundTransition = Curves.easeInOutCubic.transform(
      transitionInput,
    );
    final glassStrength =
        backgroundTransition > contentScroll ? backgroundTransition : contentScroll;
    final expansionBlur = .25 * expansion;
    final blurStrength =
        expansionBlur > glassStrength ? expansionBlur : glassStrength;

    final transitionDuration = reduceMotion ? Duration.zero : _switchDuration;

    return SizedBox(
      height: overlayHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // -----------------------------------------------------------------
          // HEADER BLUR — same behavior as AttachmentSheetHeader.
          // -----------------------------------------------------------------
          Positioned.fill(
            child: IgnorePointer(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) {
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, .44, .56, .68, .78, .85, 1],
                    colors: [
                      Colors.white.withValues(alpha: blurStrength),
                      Colors.white.withValues(alpha: blurStrength),
                      Colors.white.withValues(alpha: .82 * blurStrength),
                      Colors.white.withValues(alpha: .43 * blurStrength),
                      Colors.white.withValues(alpha: .12 * blurStrength),
                      Colors.transparent,
                      Colors.transparent,
                    ],
                  ).createShader(bounds);
                },
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 32,
                    sigmaY: 32,
                    tileMode: TileMode.clamp,
                  ),
                  blendMode: BlendMode.srcOver,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),

          // -----------------------------------------------------------------
          // HEADER BACKGROUND — fades in only as the sheet expands/scrolls.
          // -----------------------------------------------------------------
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: glassStrength,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, .22, .44, .62, .76, .88, 1],
                      colors: [
                        Color.fromRGBO(2, 3, 5, .985),
                        Color.fromRGBO(3, 4, 7, .960),
                        Color.fromRGBO(5, 7, 10, .870),
                        Color.fromRGBO(6, 8, 12, .650),
                        Color.fromRGBO(6, 8, 12, .400),
                        Color.fromRGBO(6, 8, 12, .120),
                        Color.fromRGBO(6, 8, 12, 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // -----------------------------------------------------------------
          // INTERACTIVE HEADER.
          // -----------------------------------------------------------------
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: headerHeight,
            child: GestureDetector(
              key: const ValueKey('forward-drag-header'),
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: onVerticalDragStart,
              onVerticalDragUpdate: onVerticalDragUpdate,
              onVerticalDragEnd: onVerticalDragEnd,
              onVerticalDragCancel: onVerticalDragCancel,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: WrytteColors.surfaceRaised.withValues(
                    alpha: 1 - backgroundTransition,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: .30 * glassStrength,
                      ),
                      blurRadius: 20 * glassStrength,
                      spreadRadius: 1.5 * glassStrength,
                      offset: Offset(0, 7 * glassStrength),
                    ),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    10 * scale,
                    horizontalPadding,
                    6 * scale,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        top: -1,
                        child: Container(
                          width: 56 * scale,
                          height: 4 * scale,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: .36 + (.12 * expansion),
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),

                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _HeaderCircleButton(
                          size: controlSize,
                          scale: scale,
                          tooltip: 'Close forwarding',
                          icon: Icons.close_rounded,
                          onPressed: onClose,
                        ),
                      ),

                      PositionedDirectional(
                        start: controlSize + 12,
                        end: controlSize + 12,
                        top: 3,
                        bottom: 0,
                        child: AnimatedSwitcher(
                          duration: transitionDuration,
                          reverseDuration: transitionDuration,
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          layoutBuilder: (currentChild, previousChildren) => Stack(
                            alignment: Alignment.center,
                            children: [
                              ...previousChildren,
                              if (currentChild != null) currentChild,
                            ],
                          ),
                          transitionBuilder: (child, animation) {
                            final isSearch =
                                child.key == const ValueKey<String>('search');
                            final offset = Tween<Offset>(
                              begin: Offset(isSearch ? .045 : -.03, 0),
                              end: Offset.zero,
                            ).animate(animation);
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: offset,
                                child: child,
                              ),
                            );
                          },
                          child: searchActive
                              ? _HeaderSearchField(
                                  key: const ValueKey<String>('search'),
                                  controller: searchController,
                                  focusNode: searchFocusNode,
                                  query: searchQuery,
                                  onChanged: onSearchChanged,
                                  onClear: onSearchCleared,
                                )
                              : const _ForwardTitle(
                                  key: ValueKey<String>('title'),
                                ),
                        ),
                      ),

                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!searchActive && selectedCount > 0) ...[
                              AnimatedSwitcher(
                                duration: reduceMotion
                                    ? Duration.zero
                                    : const Duration(milliseconds: 180),
                                child: Container(
                                  key: ValueKey<int>(selectedCount),
                                  width: 32 * scale,
                                  height: 32 * scale,
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(
                                    color: WrytteColors.primary,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    '$selectedCount',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontFamily:
                                          WrytteTypography.primaryFontFamily,
                                      fontSize: 15,
                                      height: 1,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(width: 10 * scale),
                            ],
                            _HeaderCircleButton(
                              size: controlSize,
                              scale: scale,
                              tooltip: searchActive
                                  ? 'Close contact search'
                                  : 'Search contacts',
                              icon: searchActive
                                  ? Icons.close_rounded
                                  : Icons.search_rounded,
                              onPressed: () {
                                unawaited(HapticFeedback.selectionClick());
                                if (searchActive) {
                                  onSearchClosed();
                                } else {
                                  onSearchPressed();
                                }
                              },
                            ),
                          ],
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

class _ForwardTitle extends StatelessWidget {
  const _ForwardTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Forward',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: WrytteColors.textPrimary,
          fontFamily: WrytteTypography.primaryFontFamily,
          fontSize: 16,
          height: 1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _HeaderSearchField extends StatelessWidget {
  const _HeaderSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: WrytteGlassSurface(
        borderRadius: BorderRadius.circular(20),
        blur: 20,
        color: WrytteColors.surfaceRaised.withValues(alpha: .76),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          keyboardAppearance: Brightness.dark,
          cursorColor: WrytteColors.primary,
          cursorWidth: 1.5,
          textAlignVertical: TextAlignVertical.center,
          style: const TextStyle(
            color: WrytteColors.textPrimary,
            fontFamily: WrytteTypography.primaryFontFamily,
            fontSize: 14.5,
            height: 1.05,
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search contacts',
            hintStyle: const TextStyle(
              color: WrytteColors.textMuted,
              fontFamily: WrytteTypography.primaryFontFamily,
              fontSize: 14.5,
              height: 1.05,
              fontWeight: FontWeight.w500,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 19,
              color: WrytteColors.textPrimary.withValues(alpha: .70),
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 40,
            ),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    visualDensity: VisualDensity.compact,
                    onPressed: onClear,
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: WrytteColors.textPrimary.withValues(alpha: .68),
                    ),
                  ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsetsDirectional.only(
              top: 10,
              bottom: 10,
              end: 3,
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderCircleButton extends StatelessWidget {
  const _HeaderCircleButton({
    required this.size,
    required this.scale,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final double size;
  final double scale;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              splashFactory: NoSplash.splashFactory,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF17191E).withValues(alpha: .88),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .08),
                    width: .8,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 24 * scale,
                  color: WrytteColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
