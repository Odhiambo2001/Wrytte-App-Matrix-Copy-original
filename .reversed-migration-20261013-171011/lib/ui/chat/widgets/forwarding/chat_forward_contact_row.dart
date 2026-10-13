import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/ui/chat/models/chat_forward_target.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class ChatForwardContactRow extends StatelessWidget {
  const ChatForwardContactRow({
    super.key,
    required this.target,
    required this.selected,
    required this.onTap,
  });

  final ChatForwardTarget target;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final avatarSize = (width * .125).clamp(46.0, 54.0).toDouble();
    final title = target.title.trim();
    final initial = title.isEmpty ? '?' : title.characters.first.toUpperCase();

    return Semantics(
      button: true,
      selected: selected,
      label: target.subtitle.trim().isEmpty
          ? target.title
          : '${target.title}, ${target.subtitle}',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          borderRadius: BorderRadius.circular(19),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                // The avatar deliberately never changes when selected. Selection
                // state belongs only to the control on the right.
                Container(
                  width: avatarSize,
                  height: avatarSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: WrytteColors.surfaceRaised.withValues(alpha: .92),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .055),
                      width: .8,
                    ),
                  ),
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: WrytteColors.textPrimary,
                      fontFamily: WrytteTypography.primaryFontFamily,
                      fontSize: 17,
                      height: 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        target.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: WrytteColors.textPrimary,
                          fontFamily: WrytteTypography.primaryFontFamily,
                          fontSize: 15.5,
                          height: 1.08,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (target.subtitle.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          target.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: WrytteColors.textMuted,
                            fontFamily: WrytteTypography.primaryFontFamily,
                            fontSize: 12.5,
                            height: 1,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _SelectionCheck(selected: selected),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return AnimatedContainer(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
      width: 25,
      height: 25,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? WrytteColors.primary : Colors.transparent,
        border: Border.all(
          color: selected
              ? WrytteColors.primary
              : Colors.white.withValues(alpha: .28),
          width: 1.35,
        ),
      ),
      child: AnimatedScale(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 150),
        curve: Curves.easeOutBack,
        scale: selected ? 1 : .55,
        child: AnimatedOpacity(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 120),
          opacity: selected ? 1 : 0,
          child: const Icon(
            Icons.check_rounded,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
