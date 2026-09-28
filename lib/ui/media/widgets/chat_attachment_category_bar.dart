import 'package:flutter/material.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/media/models/chat_attachment_tab.dart';

class ChatAttachmentCategoryBar extends StatelessWidget {
  const ChatAttachmentCategoryBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final ChatAttachmentTab selected;
  final ValueChanged<ChatAttachmentTab> onSelected;

  // ============================================================
  // SIZE
  // ============================================================

  static const double _barHeight = 66;

  static const double _horizontalMargin = 10;
  static const double _topSpacing = 8;
  static const double _bottomSpacing = 10;

  // Same tight geometry as the old bar.
  static const double _pillHorizontalInset = 2;
  static const double _pillVerticalInset = 3;

  static const double _baseIconSize = 23;
  static const double _baseLabelSize = 10.5;

  // ============================================================
  // ANIMATION
  // ============================================================

  static const Duration _indicatorDuration =
      Duration(milliseconds: 420);

  static const Duration _itemDuration =
      Duration(milliseconds: 280);

  static const Duration _iconInDuration =
      Duration(milliseconds: 260);

  static const Duration _iconOutDuration =
      Duration(milliseconds: 210);

  static const Curve _indicatorCurve = Cubic(
    0.22,
    1,
    0.36,
    1,
  );

  // ============================================================
  // ICONS
  // ============================================================

  static const Map<
    ChatAttachmentTab,
    ({String normal, String selected})
  > _icons = {
    ChatAttachmentTab.gallery: (
      normal: 'assets/svg/Gallery icon.svg',
      selected: 'assets/svg/Galley icon tapped.svg',
    ),
    ChatAttachmentTab.file: (
      normal: 'assets/svg/File icon.svg',
      selected: 'assets/svg/File icon tapped.svg',
    ),
    ChatAttachmentTab.location: (
      normal: 'assets/svg/Location icon.svg',
      selected: 'assets/svg/Location icon tapped.svg',
    ),
    ChatAttachmentTab.poll: (
      normal: 'assets/svg/Poll icon.svg',
      selected: 'assets/svg/Poll icon tapped.svg',
    ),
    ChatAttachmentTab.contact: (
      normal: 'assets/svg/Contact icon.svg',
      selected: 'assets/svg/Contact icon tapped.svg',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.disableAnimationsOf(context);

    return SafeArea(
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(
        bottom: _bottomSpacing,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          _horizontalMargin,
          _topSpacing,
          _horizontalMargin,
          0,
        ),
        child: LayoutBuilder(
          builder: (
            BuildContext context,
            BoxConstraints constraints,
          ) {
            final List<ChatAttachmentTab> tabs =
                ChatAttachmentTab.values;

            final double availableWidth =
                constraints.maxWidth;

            final double itemWidth =
                availableWidth / tabs.length;

            // Keep your intended size on normal phones.
            // Only shrink slightly on narrow layouts.
            final double responsiveScale =
                (itemWidth / 68)
                    .clamp(
                      .88,
                      1.0,
                    )
                    .toDouble();

            final double iconSize =
                _baseIconSize * responsiveScale;

            final double labelSize =
                _baseLabelSize * responsiveScale;

            final int selectedIndex =
                tabs.indexOf(selected);

            // Fully rounded category bar.
            final double outerRadius =
                _barHeight / 2;

            final double pillHeight =
                _barHeight -
                (_pillVerticalInset * 2);

            final double pillRadius =
                pillHeight / 2;

            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  outerRadius,
                ),
                boxShadow: [
                  BoxShadow(
                    color: WrytteColors.background
                        .withValues(
                      alpha: .72,
                    ),
                    blurRadius: 18,
                    offset: const Offset(
                      0,
                      6,
                    ),
                  ),
                ],
              ),

              // =================================================
              // CATEGORY BAR GLASS
              // =================================================

              child: WrytteGlassSurface(
                borderRadius: BorderRadius.circular(
                  outerRadius,
                ),

                blur: 24,

                // Same color family as active pill.
                // Slightly softer so active tab remains visible.
                color:
                    WrytteColors.surfaceRaised.withValues(
                  alpha: .68,
                ),

                child: SizedBox(
                  height: _barHeight,
                  child: Stack(
                    children: [
                      // =========================================
                      // ACTIVE TAB PILL
                      // =========================================

                      AnimatedPositioned(
                        duration: reduceMotion
                            ? Duration.zero
                            : _indicatorDuration,

                        curve: _indicatorCurve,

                        left:
                            (selectedIndex * itemWidth) +
                            _pillHorizontalInset,

                        top: _pillVerticalInset,
                        bottom: _pillVerticalInset,

                        width:
                            itemWidth -
                            (_pillHorizontalInset * 2),

                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(
                                pillRadius,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      WrytteColors.background
                                          .withValues(
                                    alpha: .60,
                                  ),
                                  blurRadius: 12,
                                  offset:
                                      const Offset(
                                    0,
                                    3,
                                  ),
                                ),
                              ],
                            ),

                            // Same WrytteGlassSurface.
                            // Stronger opacity creates active state.
                            child: WrytteGlassSurface(
                              borderRadius:
                                  BorderRadius.circular(
                                pillRadius,
                              ),
                              blur: 22,
                              color: WrytteColors
                                  .surfaceRaised
                                  .withValues(
                                alpha: .78,
                              ),
                              child:
                                  const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),

                      // =========================================
                      // CATEGORY ITEMS
                      // =========================================

                      Row(
                        children: [
                          for (final ChatAttachmentTab tab
                              in tabs)
                            Expanded(
                              child:
                                  _AttachmentCategoryItem(
                                tab: tab,
                                icons:
                                    _icons[tab]!,
                                selected:
                                    tab == selected,
                                iconSize:
                                    iconSize,
                                labelSize:
                                    labelSize,
                                reduceMotion:
                                    reduceMotion,
                                onTap: () {
                                  if (tab == selected) {
                                    return;
                                  }

                                  onSelected(tab);
                                },
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// CATEGORY ITEM
// ============================================================================

class _AttachmentCategoryItem
    extends StatelessWidget {
  const _AttachmentCategoryItem({
    required this.tab,
    required this.icons,
    required this.selected,
    required this.iconSize,
    required this.labelSize,
    required this.reduceMotion,
    required this.onTap,
  });

  final ChatAttachmentTab tab;

  final ({
    String normal,
    String selected,
  }) icons;

  final bool selected;

  final double iconSize;
  final double labelSize;

  final bool reduceMotion;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Duration itemDuration =
        reduceMotion
            ? Duration.zero
            : ChatAttachmentCategoryBar
                ._itemDuration;

    final Duration iconInDuration =
        reduceMotion
            ? Duration.zero
            : ChatAttachmentCategoryBar
                ._iconInDuration;

    final Duration iconOutDuration =
        reduceMotion
            ? Duration.zero
            : ChatAttachmentCategoryBar
                ._iconOutDuration;

    final Color iconColor =
        selected
            ? WrytteColors.textPrimary
            : WrytteColors.textPrimary.withValues(
                alpha: .70,
              );

    final Color labelColor =
        selected
            ? WrytteColors.textPrimary
            : WrytteColors.textMuted;

    return Semantics(
      button: true,
      selected: selected,
      label: '${tab.label} attachments',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          splashFactory:
              NoSplash.splashFactory,
          highlightColor:
              Colors.transparent,
          borderRadius:
              BorderRadius.circular(
            20,
          ),
          child:
              MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.15,
            child: Center(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(
                  vertical: 4,
                ),
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  crossAxisAlignment:
                      CrossAxisAlignment.center,
                  children: [
                    // ==========================================
                    // ICON
                    // ==========================================

                    SizedBox(
                      height: iconSize + 2,
                      child: AnimatedScale(
                        scale:
                            selected
                            ? 1.04
                            : 1,
                        duration:
                            itemDuration,
                        curve:
                            Curves.easeInOutCubic,
                        child: AnimatedSwitcher(
                          duration:
                              iconInDuration,
                          reverseDuration:
                              iconOutDuration,
                          switchInCurve:
                              Curves.easeOutCubic,
                          switchOutCurve:
                              Curves.easeInCubic,
                          transitionBuilder: (
                            Widget child,
                            Animation<double>
                                animation,
                          ) {
                            return FadeTransition(
                              opacity:
                                  animation,
                              child:
                                  ScaleTransition(
                                scale:
                                    Tween<double>(
                                  begin: .92,
                                  end: 1,
                                ).animate(
                                  animation,
                                ),
                                child:
                                    child,
                              ),
                            );
                          },
                          child: KeyedSubtree(
                            key:
                                ValueKey<bool>(
                              selected,
                            ),
                            child:
                                WrytteSvgIcon(
                              asset:
                                  selected
                                  ? icons.selected
                                  : icons.normal,
                              size:
                                  iconSize,
                              color:
                                  iconColor,
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 5,
                    ),

                    // ==========================================
                    // LABEL
                    // ==========================================

                    AnimatedDefaultTextStyle(
                      duration:
                          itemDuration,
                      curve:
                          Curves.easeInOutCubic,
                      style:
                          TextStyle(
                        color:
                            labelColor,
                        fontFamily:
                            WrytteTypography
                                .primaryFontFamily,
                        fontSize:
                            labelSize,
                        height:
                            1,
                        fontWeight:
                            selected
                            ? FontWeight
                                .w600
                            : FontWeight
                                .w500,
                      ),
                      child:
                          FittedBox(
                        fit:
                            BoxFit.scaleDown,
                        child:
                            Text(
                          tab.label,
                          maxLines:
                              1,
                          softWrap:
                              false,
                          textAlign:
                              TextAlign.center,
                        ),
                      ),
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