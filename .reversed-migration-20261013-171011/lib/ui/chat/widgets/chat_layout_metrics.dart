import 'package:flutter/material.dart';

@immutable
class ChatLayoutMetrics {
  const ChatLayoutMetrics._({
    required this.controlSize,
    required this.controlGap,
    required this.horizontalPadding,
  });

  factory ChatLayoutMetrics.of(BuildContext context) {
    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    final progress = ((shortestSide - 320) / (472 - 320))
        .clamp(0.0, 1.0)
        .toDouble();
    final baseHorizontalPadding = 10 + (2 * progress);
    final tabletInset = MediaQuery.sizeOf(context).width > 720
        ? (MediaQuery.sizeOf(context).width - 720) / 2
        : 0.0;
    return ChatLayoutMetrics._(
      controlSize: 44 + (4 * progress),
      controlGap: 6 + (2 * progress),
      horizontalPadding: baseHorizontalPadding + tabletInset,
    );
  }

  final double controlSize;
  final double controlGap;
  final double horizontalPadding;

  double get scale => controlSize / 48;
  double get headerHeight => controlSize + 12;
}
