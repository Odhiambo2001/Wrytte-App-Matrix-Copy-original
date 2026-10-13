import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class ChatDateHeader extends StatelessWidget {
  const ChatDateHeader({
    super.key,
    required this.label,
    required this.visibility,
  });

  final String label;
  final ValueListenable<bool> visibility;

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _ChatDateHeaderDelegate(label: label, visibility: visibility),
    );
  }
}

class _ChatDateHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _ChatDateHeaderDelegate({
    required this.label,
    required this.visibility,
  });

  final String label;
  final ValueListenable<bool> visibility;

  static const double _extent = 35;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ValueListenableBuilder<bool>(
      valueListenable: visibility,
      builder: (context, visible, child) {
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        return IgnorePointer(
          child: ExcludeSemantics(
            excluding: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: reduceMotion
                  ? Duration.zero
                  : Duration(milliseconds: visible ? 110 : 150),
              curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
              child: child,
            ),
          ),
        );
      },
      child: Center(
        child: Semantics(
          header: true,
          label: label,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: 12,
                sigmaY: 12,
                tileMode: TileMode.clamp,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF1C222C).withValues(alpha: .70),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .055),
                    width: .7,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .64),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1,
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

  @override
  bool shouldRebuild(covariant _ChatDateHeaderDelegate oldDelegate) {
    return oldDelegate.label != label || oldDelegate.visibility != visibility;
  }
}
