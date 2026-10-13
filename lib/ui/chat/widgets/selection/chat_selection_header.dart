import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/widgets/chat_layout_metrics.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_icon_button.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class ChatSelectionHeader extends StatelessWidget {
  const ChatSelectionHeader({
    super.key,
    required this.selectedCount,
    required this.onClose,
    required this.onPin,
    this.onCopy,
    this.onForward,
    this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onClose;
  final VoidCallback? onPin;
  final VoidCallback? onCopy;
  final VoidCallback? onForward;
  final VoidCallback? onDelete;

  static double actionPillWidth(BuildContext context) {
    final metrics = ChatLayoutMetrics.of(context);
    final naturalPillWidth = (6 + 43 + (4 * 43) + 8) * metrics.scale;
    final availablePillWidth =
        MediaQuery.sizeOf(context).width -
        (metrics.horizontalPadding * 2) -
        metrics.controlSize -
        metrics.controlGap;

    return naturalPillWidth
        .clamp(metrics.controlSize, availablePillWidth)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ChatLayoutMetrics.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    // Selection always exposes the same four actions for every message kind.
    const actionCount = 4;

    final countSlotWidth = 43 * metrics.scale;
    final actionSlotWidth = 43 * metrics.scale;
    final leadingInset = 6 * metrics.scale;
    final trailingInset = 8 * metrics.scale;

    final naturalPillWidth =
        leadingInset +
        countSlotWidth +
        (actionCount * actionSlotWidth) +
        trailingInset;

    final availablePillWidth =
        MediaQuery.sizeOf(context).width -
        (metrics.horizontalPadding * 2) -
        metrics.controlSize -
        metrics.controlGap;

    final pillWidth = actionPillWidth(context);

    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: metrics.headerHeight,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: metrics.horizontalPadding,
          ),
          child: Row(
            children: [
              WrytteGlassIconButton(
                semanticLabel: 'Exit message selection',
                onPressed: onClose,
                size: metrics.controlSize,
                child: Icon(
                  Icons.close_rounded,
                  size: 27 * metrics.scale,
                  color: WrytteColors.textPrimary,
                ),
              ),

              SizedBox(width: metrics.controlGap),

              // Do not Expanded() this control. Its width is intentionally
              // derived from the number of visible action icons, keeping the
              // pill immediately beside the close button instead of stretching
              // across the rest of the header.
              AnimatedSize(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 190),
                curve: Curves.easeOutCubic,
                alignment: AlignmentDirectional.centerStart,
                child: SizedBox(
                  width: pillWidth,
                  height: metrics.controlSize,
                  child: WrytteGlassSurface(
                    borderRadius: BorderRadius.circular(
                      metrics.controlSize / 2,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        metrics.controlSize / 2,
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: naturalPillWidth > availablePillWidth
                            ? const ClampingScrollPhysics()
                            : const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: naturalPillWidth,
                          height: metrics.controlSize,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(width: leadingInset),

                              SizedBox(
                                width: countSlotWidth,
                                child: Center(
                                  child: AnimatedSwitcher(
                                    duration: reduceMotion
                                        ? Duration.zero
                                        : const Duration(milliseconds: 170),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    child: Text(
                                      '$selectedCount',
                                      key: ValueKey<int>(selectedCount),
                                      style: TextStyle(
                                        color: WrytteColors.textPrimary,
                                        fontFamily:
                                            WrytteTypography.primaryFontFamily,
                                        fontSize: 17 * metrics.scale,
                                        fontWeight: FontWeight.w600,
                                        height: 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              _SelectionHeaderAction(
                                label: 'Pin',
                                assetPath: 'assets/svg/Pin icon .svg',
                                iconScale: 1.0,
                                scale: metrics.scale,
                                onTap: onPin,
                              ),

                              _SelectionHeaderAction(
                                label: 'Copy',
                                assetPath: 'assets/svg/Copy icon.svg',
                                iconScale: .96,
                                scale: metrics.scale,
                                onTap: onCopy,
                              ),

                              _SelectionHeaderAction(
                                label: 'Forward',
                                assetPath: 'assets/svg/Forward Icon.svg',
                                iconScale: 1.05,
                                scale: metrics.scale,
                                color: Colors.white,
                                onTap: onForward,
                              ),

                              _SelectionHeaderAction(
                                label: 'Delete',
                                assetPath: 'assets/svg/Delete icon.svg',
                                iconScale: .98,
                                scale: metrics.scale,
                                color: WrytteColors.destructive,
                                onTap: onDelete,
                              ),

                              SizedBox(width: trailingInset),
                            ],
                          ),
                        ),
                      ),
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

class _SelectionHeaderAction extends StatelessWidget {
  const _SelectionHeaderAction({
    required this.label,
    required this.assetPath,
    required this.iconScale,
    required this.scale,
    required this.onTap,
    this.mirrorHorizontally = false,
    this.color = WrytteColors.textPrimary,
  });

  final String label;
  final String assetPath;
  final double iconScale;
  final double scale;
  final VoidCallback? onTap;
  final bool mirrorHorizontally;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    Widget icon = WrytteSvgIcon(
      asset: assetPath,
      size: 24 * scale * iconScale,
      color: enabled
          ? color
          : color.withValues(alpha: .36),
    );

    if (mirrorHorizontally) {
      icon = Transform.flip(
        flipX: true,
        child: icon,
      );
    }

    return SizedBox(
      width: 43 * scale,
      height: double.infinity,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: Tooltip(
          message: label,
          child: InkResponse(
            onTap: onTap,
            radius: 23 * scale,
            containedInkWell: true,
            highlightShape: BoxShape.circle,
            splashColor: Colors.transparent,
            highlightColor: Colors.white.withValues(alpha: .045),
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}
