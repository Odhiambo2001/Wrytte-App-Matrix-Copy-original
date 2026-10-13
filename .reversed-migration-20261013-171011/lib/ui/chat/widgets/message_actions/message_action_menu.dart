import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class MessageActionMenu extends StatelessWidget {
  const MessageActionMenu({
    super.key,
    required this.actions,
    required this.maxHeight,
    required this.onSelected,
  });

  // ---------------------------------------------------------------------------
  // Menu geometry
  // ---------------------------------------------------------------------------
  //
  // Keep the squircle profile that matched the latest screenshot.
  //
  // IMPORTANT:
  // The corner size is derived from MENU WIDTH, not menu height.
  //
  // That means:
  // - the normal action menu keeps the exact squircle you approved;
  // - Pin/Delete submenus can become shorter without changing into a different
  //   rounded shape;
  // - AnimatedSize may change height, but the shoulder profile stays stable.

  static const double _viewportWidthFraction = .638;

  static const double _minimumWidth = 228;
  static const double _maximumWidth = 262;

  // Approved squircle strength from the latest version.
  static const double _squircleCornerFraction = .19;

  // Slightly more vertical breathing room so the first and last actions sit
  // comfortably inside the continuous squircle shoulders.
  static const double _verticalPadding = 12;

  static const double _rowHeight = 42;

  static const double _horizontalPadding = 22;
  static const double _iconSlotSize = 20;
  static const double _iconTextGap = 9;
  static const double _iconSize = 19;

  static const double minimumUsableHeight =
      _rowHeight + (_verticalPadding * 2);

  final List<MessageAction> actions;
  final double maxHeight;
  final ValueChanged<MessageAction> onSelected;

  static double naturalHeightFor(int actionCount) {
    if (actionCount <= 0) {
      return 0;
    }

    return (_verticalPadding * 2) + (_rowHeight * actionCount);
  }

  static double widthFor(
    BuildContext context, {
    required List<MessageAction> actions,
    required double availableWidth,
  }) {
    if (availableWidth <= 0) {
      return 0;
    }

    final viewportWidth = MediaQuery.sizeOf(context).width;

    final measuredTargetWidth = (viewportWidth * _viewportWidthFraction)
        .clamp(
          _minimumWidth,
          _maximumWidth,
        )
        .toDouble();

    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);

    var width = math.min(
      measuredTargetWidth,
      availableWidth,
    );

    for (final action in actions) {
      final painter = TextPainter(
        text: TextSpan(
          text: action.label,
          style: const TextStyle(
            fontFamily: WrytteTypography.primaryFontFamily,
            fontSize: 15,
            height: 1,
            fontWeight: FontWeight.w500,
          ),
        ),
        maxLines: 1,
        textDirection: textDirection,
        textScaler: textScaler,
        locale: locale,
      )..layout();

      final iconReserve = _showsIcon(action)
          ? _iconSlotSize + _iconTextGap
          : 0.0;

      final candidate =
          (_horizontalPadding * 2) +
          iconReserve +
          painter.width;

      width = math.max(
        width,
        candidate,
      );

      painter.dispose();
    }

    return width
        .clamp(
          0.0,
          math.min(
            _maximumWidth,
            availableWidth,
          ),
        )
        .toDouble();
  }

  static bool _showsIcon(MessageAction action) =>
      action.svgAsset != null ||
      (action.label != 'Pin for everyone' &&
          action.label != 'Pin for me' &&
          action.label != 'Delete for everyone' &&
          action.label != 'Delete for me' &&
          action.label != 'Cancel');

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty || maxHeight <= 0) {
      return const SizedBox.shrink();
    }

    final naturalHeight = naturalHeightFor(actions.length);
    final height = math.min(maxHeight, naturalHeight);

    return AnimatedSize(
      duration: const Duration(milliseconds: 170),
      reverseDuration: const Duration(milliseconds: 130),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: height,
        child: _MessageActionSquircleGlassSurface(
          cornerFraction: _squircleCornerFraction,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 170),
            reverseDuration: const Duration(milliseconds: 130),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(.035, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: ListView.builder(
              key: ValueKey<String>(
                actions.map((action) => action.label).join('\u0000'),
              ),
              padding: const EdgeInsets.symmetric(
                vertical: _verticalPadding,
              ),
              physics: naturalHeight > maxHeight
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              itemCount: actions.length,
              itemBuilder: (context, index) {
                final action = actions[index];

                return _MessageActionRow(
                  action: action,
                  onSelected: onSelected,
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
// Squircle + original Wrytte glass
// =============================================================================
//
// This restores the WrytteGlassSurface background/blur that the menu used
// before the temporary custom squircle gradient.
//
// There is one important detail:
//
// WrytteGlassSurface still understands ordinary BorderRadius/RRect geometry.
// We therefore give it BorderRadius.zero and let this outer native Flutter
// RoundedSuperellipseBorder be the ONE authoritative silhouette.
//
// The outer ClipPath cuts the existing Wrytte glass into the squircle.
// The transparent Material receives the exact same shape so InkWell highlights
// and child clipping agree with the outer surface.
//
// Corner radius is based on WIDTH only. This keeps exactly the same squircle
// shoulder when AnimatedSwitcher changes from the main actions to Pin/Delete
// choices and AnimatedSize makes the menu shorter.

class _MessageActionSquircleGlassSurface extends StatelessWidget {
  const _MessageActionSquircleGlassSurface({
    required this.cornerFraction,
    required this.child,
  });

  final double cornerFraction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MessageActionMenu._minimumWidth;

        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : width;

        // Keep this radius stable as menu height changes.
        final requestedRadius = width * cornerFraction;

        // Safety only for an unusually tiny menu. Main menu and the normal
        // 3-row Pin/Delete submenus stay on requestedRadius.
        final maximumSafeRadius = height * .44;

        final cornerRadius = math.min(
          requestedRadius,
          maximumSafeRadius,
        );

        final borderRadius = BorderRadius.circular(
          cornerRadius,
        );

        final shape = RoundedSuperellipseBorder(
          borderRadius: borderRadius,
        );

        return ClipPath.shape(
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: WrytteGlassSurface(
            // Do not let an inner RRect change the squircle silhouette.
            borderRadius: BorderRadius.zero,
            blur: 18,
            child: Material(
              type: MaterialType.transparency,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _MessageActionRow extends StatelessWidget {
  const _MessageActionRow({
    required this.action,
    required this.onSelected,
  });

  static const double _rowHeight =
      MessageActionMenu._rowHeight;

  final MessageAction action;
  final ValueChanged<MessageAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final enabled = action.isEnabled;

    final baseColor = action.isDestructive
        ? WrytteColors.destructive
        : WrytteColors.textPrimary;

    final color = enabled
        ? baseColor
        : baseColor.withValues(alpha: .36);

    return Semantics(
      button: true,
      enabled: enabled,
      label: action.label,
      child: InkWell(
        onTap: enabled ? () => onSelected(action) : null,
        splashColor: Colors.transparent,
        highlightColor: Colors.white.withValues(alpha: .035),
        child: SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              MessageActionMenu._horizontalPadding,
              0,
              MessageActionMenu._horizontalPadding,
              0,
            ),
            child: Row(
              children: [
                if (MessageActionMenu._showsIcon(action)) ...[
                  SizedBox.square(
                    dimension: MessageActionMenu._iconSlotSize,
                    child: Center(
                      child: _buildIcon(color),
                    ),
                  ),
                  const SizedBox(
                    width: MessageActionMenu._iconTextGap,
                  ),
                ],
                Expanded(
                  child: Text(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontFamily:
                          WrytteTypography.primaryFontFamily,
                      fontSize: 15,
                      height: 1,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(Color color) {
    final asset = action.svgAsset;

    Widget icon;

    if (asset != null) {
      icon = WrytteSvgIcon(
        asset: asset,
        size:
            MessageActionMenu._iconSize *
            action.iconScale,
        color: color,
      );
    } else {
      icon = Icon(
        _fallbackIcon(action.type),
        size: MessageActionMenu._iconSize,
        color: color,
      );
    }

    if (action.mirrorSvgHorizontally) {
      icon = Transform.flip(
        flipX: true,
        child: icon,
      );
    }

    return icon;
  }

  IconData _fallbackIcon(
    MessageActionType type,
  ) {
    return switch (type) {
      MessageActionType.reply =>
        Icons.reply_rounded,

      MessageActionType.copy =>
        Icons.content_copy_rounded,

      MessageActionType.forward =>
        Icons.forward_rounded,

      MessageActionType.save =>
        Icons.download_rounded,

      MessageActionType.edit =>
        Icons.edit_rounded,

      MessageActionType.editMedia =>
        Icons.edit_rounded,

      MessageActionType.pin =>
        Icons.push_pin_outlined,

      MessageActionType.delete =>
        Icons.delete_outline_rounded,

      MessageActionType.select =>
        Icons.check_circle_outline_rounded,
    };
  }
}
