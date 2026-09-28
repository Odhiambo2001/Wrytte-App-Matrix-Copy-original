import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';

typedef ExpandingSurfaceBuilder =
    Widget Function(BuildContext context, Animation<double> animation);

/// A reusable source-rect-to-full-screen route used by media surfaces.
class ExpandingSurfaceRoute<T> extends PageRoute<T> {
  ExpandingSurfaceRoute({
    required this.builder,
    required this.animationsDisabled,
    this.origin,
    this.openDuration = const Duration(milliseconds: 285),
    this.closeDuration = const Duration(milliseconds: 245),
    this.keepUnderlyingVisible = false,
  });

  final ExpandingSurfaceBuilder builder;
  final ExpandingSurfaceOrigin? origin;
  final bool animationsDisabled;
  final Duration openDuration;
  final Duration closeDuration;
  final bool keepUnderlyingVisible;
  bool _fullyOpaque = false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool get opaque =>
      !keepUnderlyingVisible &&
      (origin == null || animationsDisabled || _fullyOpaque);

  @override
  Duration get transitionDuration =>
      animationsDisabled ? Duration.zero : openDuration;

  @override
  Duration get reverseTransitionDuration =>
      animationsDisabled ? Duration.zero : closeDuration;

  @override
  void install() {
    super.install();
    animation?.addStatusListener(_handleAnimationStatus);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    final next = status == AnimationStatus.completed;
    if (next == _fullyOpaque) return;
    _fullyOpaque = next;
    changedInternalState();
  }

  @override
  void dispose() {
    animation?.removeStatusListener(_handleAnimationStatus);
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context, animation);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final source = origin;
    if (animationsDisabled) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    if (source == null) {
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          alignment: Alignment.center,
          scale: Tween<double>(begin: .985, end: 1).animate(curved),
          child: child,
        ),
      );
    }
    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final screenSize = MediaQuery.sizeOf(context);
        final destination = Offset.zero & screenSize;
        final rect = Rect.lerp(source.rect, destination, curved.value)!;
        final radius = BorderRadius.lerp(
          source.borderRadius,
          BorderRadius.zero,
          curved.value,
        )!;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black.withValues(alpha: curved.value)),
            Positioned.fromRect(
              rect: rect,
              child: Opacity(
                opacity: const Interval(
                  0,
                  .18,
                  curve: Curves.easeOut,
                ).transform(curved.value),
                child: ClipRRect(
                  borderRadius: radius,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: screenSize.width,
                      height: screenSize.height,
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
