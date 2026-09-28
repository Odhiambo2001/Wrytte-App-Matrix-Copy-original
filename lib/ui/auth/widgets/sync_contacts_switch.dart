import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class SyncContactsSwitch extends StatelessWidget {
  const SyncContactsSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);

    return Semantics(
      label: 'Sync contacts',
      button: true,
      toggled: value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: AnimatedContainer(
              key: const ValueKey('sync-contacts-switch'),
              duration: duration,
              curve: Curves.easeOut,
              width: 48,
              height: 26,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: value
                    ? WrytteColors.primary
                    : WrytteColors.surfaceRaised,
                borderRadius: BorderRadius.circular(13),
              ),
              child: AnimatedAlign(
                duration: duration,
                curve: Curves.easeOut,
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: const SizedBox.square(
                  key: ValueKey('sync-contacts-thumb'),
                  dimension: 22,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: WrytteColors.textPrimary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
