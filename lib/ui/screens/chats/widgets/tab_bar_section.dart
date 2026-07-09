import 'dart:ui';
import 'package:flutter/material.dart';

class TabBarSection extends StatelessWidget {
  final TabController? controller;

  const TabBarSection({super.key, this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              // ✅ Same glass color + opacity as BottomNavBar
              color: const Color(0xFF23262C).withOpacity(0.30),
              borderRadius: BorderRadius.circular(22),
              // ✅ Same thin solid outline as BottomNavBar
              border: Border.all(color: const Color(0xFF23262C), width: 1.0),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: TabBar(
              controller: controller,
              isScrollable: false,
              padding: EdgeInsets.zero,
              labelPadding: EdgeInsets.zero,
              indicator: _InsetTabIndicator(
                color: const Color(0xFF23262C),
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
              tabs: const [
                Tab(text: 'Chats'),
                Tab(text: 'Channels'),
                Tab(text: 'Groups'),
              ],
            ),
          ),
        ),
      ),
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

    final paint = Paint()..color = color;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      paint,
    );
  }
}
