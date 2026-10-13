import 'package:flutter/material.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMessageSelectionBadge extends StatelessWidget {
  const ChatMessageSelectionBadge({
    super.key,
    required this.selected,
  });

  static const double size = 24;

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 160);

    return Semantics(
      selected: selected,
      label: selected ? 'Message selected' : 'Message not selected',
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: .82, end: 1).animate(animation),
              child: child,
            ),
          );
        },
        child: selected
            ? const SizedBox.square(
                key: ValueKey<String>('message-selection-selected'),
                dimension: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: WrytteColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      Icons.check_rounded,
                      size: 17,
                      color: Colors.white,
                    ),
                  ),
                ),
              )
            : SizedBox.square(
                key: const ValueKey<String>('message-selection-unselected'),
                dimension: size,
                child: WrytteGlassSurface(
                  borderRadius: BorderRadius.circular(size / 2),
                  blur: 18,
                  color: const Color(0xB31B1E24),
                  child: const SizedBox.expand(),
                ),
              ),
      ),
    );
  }
}
