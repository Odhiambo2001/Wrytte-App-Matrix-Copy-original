import 'package:flutter/widgets.dart';

class ExpandingSurfaceOrigin {
  const ExpandingSurfaceOrigin({
    required this.rect,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
  });

  final Rect rect;
  final BorderRadius borderRadius;

  static ExpandingSurfaceOrigin? fromKey(
    GlobalKey key, {
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(24)),
  }) => fromContext(key.currentContext, borderRadius: borderRadius);

  static ExpandingSurfaceOrigin? fromContext(
    BuildContext? context, {
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(24)),
  }) {
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return ExpandingSurfaceOrigin(
      rect: renderObject.localToGlobal(Offset.zero) & renderObject.size,
      borderRadius: borderRadius,
    );
  }
}
