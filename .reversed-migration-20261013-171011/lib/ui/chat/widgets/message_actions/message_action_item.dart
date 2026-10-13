import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class MessageActionItem extends StatelessWidget {
  const MessageActionItem({
    super.key,
    required this.action,
    required this.onPressed,
  });

  static const double height = 46;
  static const double iconWidth = 24;
  static const double iconGap = 11;
  static const double leadingPadding = 14;
  static const double trailingPadding = 13;
  static const double _iconCanvas = 21;

  static const TextStyle labelStyle = TextStyle(
    inherit: false,
    fontFamily: WrytteTypography.primaryFontFamily,
    fontSize: 15.5,
    fontWeight: FontWeight.w400,
    height: 1.15,
    letterSpacing: 0,
  );

  /// Only used when an action does not have a Wrytte SVG.
  ///
  /// Using a map instead of an exhaustive switch means adding a future
  /// MessageActionType will not break this widget.
  static const Map<MessageActionType, IconData> _fallbackIcons = {
    MessageActionType.reply: Icons.reply_rounded,
    MessageActionType.copy: Icons.content_copy_rounded,
    MessageActionType.forward: Icons.forward_rounded,
    MessageActionType.save: Icons.download_rounded,
    MessageActionType.edit: Icons.edit_rounded,
    MessageActionType.editMedia: Icons.edit_rounded,
    MessageActionType.pin: Icons.push_pin_outlined,
    MessageActionType.delete: Icons.delete_outline_rounded,
    MessageActionType.select: Icons.check_circle_outline_rounded,
  };

  final MessageAction action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color enabledColor = action.isDestructive
        ? const Color(0xFFD94B52)
        : WrytteColors.textPrimary;

    final Color color = action.isEnabled
        ? enabledColor
        : WrytteColors.textMuted.withValues(alpha: .42);

    return Semantics(
      button: true,
      enabled: action.isEnabled,
      label: action.label,
      child: SizedBox(
        height: height,
        child: InkWell(
          key: ValueKey('message-action-${action.type.name}'),
          onTap: action.isEnabled ? onPressed : null,

          // Keep the popup visually quiet.
          splashFactory: NoSplash.splashFactory,

          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              leadingPadding,
              0,
              trailingPadding,
              0,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: iconWidth,
                  child: Center(child: _buildIcon(color)),
                ),
                const SizedBox(width: iconGap),
                Expanded(
                  child: Text(
                    action.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle.copyWith(color: color),
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

    // =====================================================================
    // WRYTTE SVG
    // =====================================================================
    //
    // MessageAction owns its icon metadata.
    //
    // This is important because Select already defines:
    //
    // assets/svg/Select icon.svg
    // scale: 1.08
    //
    // We therefore don't duplicate that mapping in this widget.

    if (asset != null) {
      Widget icon = WrytteSvgIcon(
        asset: asset,
        size: _iconCanvas,
        color: color,
      );

      if (action.iconScale != 1) {
        icon = Transform.scale(scale: action.iconScale, child: icon);
      }

      if (action.mirrorSvgHorizontally) {
        icon = Transform.flip(flipX: true, child: icon);
      }

      return icon;
    }

    // =====================================================================
    // MATERIAL FALLBACK
    // =====================================================================

    return Icon(
      _fallbackIcons[action.type] ?? Icons.more_horiz_rounded,
      size: 20,
      color: color,
    );
  }
}
