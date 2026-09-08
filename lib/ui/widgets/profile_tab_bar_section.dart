import 'dart:ui';
import 'package:flutter/material.dart';

/// Shared glass tab bar used on profile screens.
/// [tabs] is a list of tab labels — supports any number of tabs.
/// Width auto-sizes: ≤2 tabs uses 60% screen width (centred),
/// ≥3 tabs stretches full width with horizontal padding.
class ProfileTabBarSection extends StatelessWidget {
  final TabController controller;
  final List<String> tabs;

  const ProfileTabBarSection({
    super.key,
    required this.controller,
    required this.tabs,
  });

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;

    // For 2 tabs centre at 60% width; for 3+ stretch full width
    final bool centred = tabs.length <= 2;
    final double containerWidth = centred ? screenWidth * 0.6 : screenWidth;
    final EdgeInsets padding =
        centred
            ? const EdgeInsets.symmetric(vertical: 6)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 6);

    Widget tabBar = ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF23262C), width: 1.0),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: TabBar(
            controller: controller,
            isScrollable: false, // always false — fills available width evenly
            padding: EdgeInsets.zero,
            labelPadding: EdgeInsets.zero,
            tabAlignment:
                TabAlignment.fill, // evenly distributed, no trailing space
            indicator: const _InsetTabIndicator(
              color: Color(0xFF23262C),
              radius: 18,
              verticalInset: 0,
              horizontalInset: 2,
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.grey,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            unselectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 14,
            ),
            tabs: tabs.map((t) => Tab(text: t)).toList(),
          ),
        ),
      ),
    );

    return Container(
      color: Colors.transparent,
      padding: padding,
      child:
          centred
              ? Center(child: SizedBox(width: containerWidth, child: tabBar))
              : tabBar,
    );
  }
}

class _InsetTabIndicator extends Decoration {
  final Color color;
  final double radius;
  final double verticalInset;
  final double horizontalInset;

  const _InsetTabIndicator({
    required this.color,
    required this.radius,
    this.verticalInset = 4,
    this.horizontalInset = 4,
  });

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return _InsetTabPainter(
      color: color,
      radius: radius,
      verticalInset: verticalInset,
      horizontalInset: horizontalInset,
    );
  }
}

class _InsetTabPainter extends BoxPainter {
  final Color color;
  final double radius;
  final double verticalInset;
  final double horizontalInset;

  _InsetTabPainter({
    required this.color,
    required this.radius,
    required this.verticalInset,
    required this.horizontalInset,
  });

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = Rect.fromLTWH(
      offset.dx + horizontalInset,
      offset.dy + verticalInset,
      (configuration.size?.width ?? 0) - horizontalInset * 2,
      (configuration.size?.height ?? 0) - verticalInset * 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()..color = color,
    );
  }
}
