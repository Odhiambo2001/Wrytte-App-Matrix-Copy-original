import 'package:flutter/material.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class MediaSelectionBadge extends StatelessWidget {
  const MediaSelectionBadge({super.key, required this.index});

  final int index;

  static const double _size = 24;

  bool get _selected => index > 0;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return SizedBox.square(
      dimension: _size,
      child: AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 160),
        reverseDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 130),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: .88, end: 1).animate(animation),
              child: child,
            ),
          );
        },
        child: _selected
            ? _SelectedBadge(key: ValueKey<int>(index), index: index)
            : const _UnselectedGlassBadge(key: ValueKey<String>('unselected')),
      ),
    );
  }
}

class _UnselectedGlassBadge extends StatelessWidget {
  const _UnselectedGlassBadge({super.key});

  @override
  Widget build(BuildContext context) {
    // Do not use BackdropFilter here. Chat galleries can have many of these
    // badges on screen at once, and recomputing one blur per moving thumbnail
    // is substantially more expensive than the equivalent composited paint.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xB31B1E24),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: .09),
          width: .8,
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: WrytteColors.primary,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          '$index',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontFamily: WrytteTypography.primaryFontFamily,
            fontSize: 13,
            height: 1,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
