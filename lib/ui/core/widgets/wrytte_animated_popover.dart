import 'package:flutter/material.dart';

/// Shared motion for small contextual surfaces such as confirmation cards,
/// mode hints, and compact menus.
class WrytteAnimatedPopover extends StatelessWidget {
  const WrytteAnimatedPopover({
    super.key,
    required this.visible,
    required this.child,
    this.alignment = Alignment.center,
    this.hiddenOffset = const Offset(0, .14),
  });

  final bool visible;
  final Widget child;
  final Alignment alignment;
  final Offset hiddenOffset;

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: disabled ? Duration.zero : const Duration(milliseconds: 210),
      reverseDuration: disabled
          ? Duration.zero
          : const Duration(milliseconds: 170),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        clipBehavior: Clip.none,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: hiddenOffset,
              end: Offset.zero,
            ).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: .9, end: 1).animate(curved),
              alignment: alignment,
              child: child,
            ),
          ),
        );
      },
      child: visible
          ? KeyedSubtree(key: const ValueKey(true), child: child)
          : const SizedBox.shrink(key: ValueKey(false)),
    );
  }
}
