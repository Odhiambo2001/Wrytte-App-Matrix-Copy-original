import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

const _forwardDuration = Duration(milliseconds: 280);
const _reverseDuration = Duration(milliseconds: 240);

Widget _buildHorizontalTransition(
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final primaryAnimation = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  final backgroundAnimation = CurvedAnimation(
    parent: secondaryAnimation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return SlideTransition(
    position: Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-.18, 0),
    ).animate(backgroundAnimation),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(primaryAnimation),
      child: child,
    ),
  );
}

/// GoRouter page that guarantees Wrytte's horizontal transition for both
/// pushed routes and locations replaced through `go`.
class WrytteTransitionPage<T> extends CustomTransitionPage<T> {
  WrytteTransitionPage({required LocalKey super.key, required super.child})
    : super(
        transitionDuration: _forwardDuration,
        reverseTransitionDuration: _reverseDuration,
        transitionsBuilder: (_, animation, secondaryAnimation, child) =>
            _buildHorizontalTransition(animation, secondaryAnimation, child),
      );
}

/// Standard Wrytte page transition for Android.
///
/// Behavior:
/// - New page enters from the right.
/// - Current page moves slightly left underneath it.
/// - Back reverses the movement.
/// - No shadow.
/// - No fade.
/// - No scale.
/// - No zoom.
/// - No dark overlay.
/// - No Cupertino edge-swipe navigation gesture.
///
/// The small secondary movement gives the transition some depth without
/// bringing over the visual shadow used by Flutter's Cupertino transition.
class WryttePageTransitionsBuilder extends PageTransitionsBuilder {
  const WryttePageTransitionsBuilder();

  /// Quick enough to feel responsive without looking abrupt.
  @override
  Duration get transitionDuration => _forwardDuration;

  /// Back navigation is slightly quicker.
  @override
  Duration get reverseTransitionDuration => _reverseDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _buildHorizontalTransition(animation, secondaryAnimation, child);
  }
}
