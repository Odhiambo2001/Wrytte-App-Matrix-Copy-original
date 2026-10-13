import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class MessageMetadataMetrics {
  const MessageMetadataMetrics({required this.width, required this.height});

  final double width;
  final double height;
}

/// One metadata implementation for text, media, and future message types.
///
/// Its measurement API and widget use the same typography and fixed status
/// extent, keeping text-layout decisions in sync with what is painted.
class MessageMetadata extends StatelessWidget {
  const MessageMetadata({
    super.key,
    required this.message,
    this.onMedia = false,
  });

  static const double statusGap = 3;
  static const double editedGap = 5;
  static const double pinnedGap = 3;
  static const double pinnedExtent = 12;
  static const TextStyle textStyle = TextStyle(
    fontFamily: WrytteTypography.primaryFontFamily,
    color: Color(0xBFC6C6C6),
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1,
  );

  final ChatMessagePresentation message;
  final bool onMedia;

  static double statusExtentFor(ChatDeliveryState state) => switch (state) {
    ChatDeliveryState.pending => 13,
    ChatDeliveryState.failed => 14,
    _ => 17,
  };

  static MessageMetadataMetrics measure(
    BuildContext context,
    ChatMessagePresentation message,
  ) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);

    Size measureText(String value) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: textStyle),
        textDirection: direction,
        textScaler: scaler,
        locale: locale,
        maxLines: 1,
      )..layout();
      final size = painter.size;
      painter.dispose();
      return size;
    }

    final timeSize = measureText(message.timeLabel);
    final editedSize = message.edited ? measureText('Edited') : Size.zero;
    final editedWidth = message.edited ? editedSize.width + editedGap : 0.0;
    final pinnedWidth = message.pinned ? pinnedExtent + pinnedGap : 0.0;
    final statusExtent = statusExtentFor(message.deliveryState);
    final statusWidth = message.isMine ? statusGap + statusExtent : 0.0;
    return MessageMetadataMetrics(
      width: pinnedWidth + editedWidth + timeSize.width + statusWidth,
      height: math.max(
        math.max(timeSize.height, editedSize.height),
        message.isMine ? statusExtent : 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveTextStyle = textStyle.copyWith(
      shadows: onMedia
          ? const [Shadow(color: Color(0xB3000000), blurRadius: 3)]
          : null,
    );
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (message.pinned) ...[
          WrytteSvgIcon(
            asset: 'assets/svg/Pin icon fill.svg',
            size: pinnedExtent,
            color: Colors.white.withValues(alpha: message.isMine ? .72 : .55),
          ),
          const SizedBox(width: pinnedGap),
        ],
        if (message.edited) ...[
          Text('Edited', style: effectiveTextStyle),
          const SizedBox(width: editedGap),
        ],
        Text(message.timeLabel, style: effectiveTextStyle),
        if (message.isMine) ...[
          const SizedBox(width: statusGap),
          SizedBox.square(
            dimension: statusExtentFor(message.deliveryState),
            child: Center(child: _DeliveryStatusIcon(message.deliveryState)),
          ),
        ],
      ],
    );

    return Semantics(
      label: _semanticLabel,
      container: true,
      child: ExcludeSemantics(child: content),
    );
  }

  String get _semanticLabel {
    final parts = <String>[
      if (message.edited) 'Edited',
      if (message.pinned) 'Pinned',
      message.timeLabel,
      if (message.isMine) _deliverySemanticLabel(message.deliveryState),
    ];
    return parts.join(', ');
  }
}

class _DeliveryStatusIcon extends StatelessWidget {
  const _DeliveryStatusIcon(this.state);

  final ChatDeliveryState state;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      ChatDeliveryState.pending => Icon(
        Icons.access_time_rounded,
        size: 13,
        color: Colors.white.withValues(alpha: .58),
      ),
      ChatDeliveryState.sent => _OldWrytteCheckmark(
        asset: 'assets/svg/Single checkmark.svg',
        color: WrytteColors.textPrimary,
      ),
      ChatDeliveryState.delivered => const _OldWrytteCheckmark(
        asset: 'assets/svg/Check mark delivered .svg',
        color: WrytteColors.textPrimary,
      ),
      ChatDeliveryState.read => const _OldWrytteCheckmark(
        asset: 'assets/svg/Check mark delivered .svg',
        color: Color(0xFF2978FF),
      ),
      ChatDeliveryState.failed => const Icon(
        Icons.error_outline_rounded,
        size: 14,
        color: WrytteColors.destructive,
      ),
    };
  }
}

class _OldWrytteCheckmark extends StatelessWidget {
  const _OldWrytteCheckmark({required this.asset, required this.color});

  final String asset;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, 2),
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(1.05, 1.12, 1),
        child: WrytteSvgIcon(asset: asset, size: 17, color: color),
      ),
    );
  }
}

String _deliverySemanticLabel(ChatDeliveryState state) => switch (state) {
  ChatDeliveryState.pending => 'Sending',
  ChatDeliveryState.sent => 'Sent',
  ChatDeliveryState.delivered => 'Delivered',
  ChatDeliveryState.read => 'Read',
  ChatDeliveryState.failed => 'Failed to send',
};
