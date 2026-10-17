import 'dart:ui';
import 'package:flutter/material.dart';
import 'dart:math' as math;

/// Shared glass tab bar used on profile screens.
/// [tabs] is a list of tab labels — supports any number of tabs.
/// Width auto-sizes: ≤2 tabs uses a wider centred pill (~220–230 px)
/// that matches the near-oval look in the screenshot,
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

    // Wider centred pill for 1–2 tabs → produces the near-oval shape
    // seen in the screenshot (comes out further left/right).
    final bool centred = tabs.length <= 2;
    final double containerWidth = centred
        ? math.min(230.0, screenWidth * 0.58)
        : screenWidth;

    final EdgeInsets padding = centred
        ? const EdgeInsets.symmetric(vertical: 6)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 6);

    Widget tabBar = ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFF23262C), width: 1.0),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: TabBar(
            controller: controller,
            isScrollable: false,
            padding: EdgeInsets.zero,
            labelPadding: EdgeInsets.zero,
            tabAlignment: TabAlignment.fill,
            indicator: const _InsetTabIndicator(
              color: Color(0xFF23262C),
              radius: 16,
              verticalInset: 0,
              horizontalInset: 1.5,
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
      child: centred
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
