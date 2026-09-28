import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:wrytte/ui/core/platform/keyboard_motion_bridge.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

/// Shared bottom action for auth scaffolds.
///
/// In footer-only mode this behaves like the original auth action and may own
/// its own bottom SafeArea.
///
/// When [child] and [focusNodes] are supplied, this widget owns the complete
/// auth keyboard motion too. The page content and Next button move as one unit:
/// - opening is a direct, zero-lag binding to the LIVE reported keyboard inset
///   every time it changes — no tween, no cached/native pre-jump. The button's
///   offset is always exactly `reportedInset - stableSystemBottom` for that
///   frame, so it can never move before or after the real keyboard;
/// - closing takes 200 ms (smooth, no sync requirement in that direction);
/// - the native IME target is recorded for diagnostics only and never used to
///   move the button ahead of the actually-measured inset.
class AuthBottomAction extends StatefulWidget {
  const AuthBottomAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.child,
    this.focusNodes = const <FocusNode>[],
    this.compact = false,
    this.busy = false,
    this.useBottomSafeArea = true,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Optional auth page content placed above the bottom action.
  final Widget? child;

  /// Text-field focus nodes that participate in this keyboard motion.
  final List<FocusNode> focusNodes;

  /// A quieter welcome action.
  final bool compact;

  final bool busy;

  /// Used only in footer-only mode.
  final bool useBottomSafeArea;

  @override
  State<AuthBottomAction> createState() => _AuthBottomActionState();
}

class _AuthBottomActionState extends State<AuthBottomAction>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const Duration _keyboardCloseDuration = Duration(milliseconds: 200);

  late final AnimationController _keyboardMotionController;

  bool _motionActive = false;
  bool _keyboardOpening = false;
  bool _keyboardClosing = false;
  bool _systemKeyboardCloseStarted = false;

  double _lastReportedInset = 0;

  // Kept for diagnostics / potential future use only — NOT used to move
  // the button ahead of the live reported inset.
  double? _cachedKeyboardInset;

  StreamSubscription<KeyboardMotionTarget>? _keyboardMotionTargetSubscription;

  // ── DIAGNOSTIC TIMERS ───────────────────────────────────────────
  Stopwatch? _diagFocusStopwatch;
  int? _diagFirstMotionMs;
  int? _diagFirstKeyboardMs;
  // ────────────────────────────────────────────────────────────────

  bool get _combinedKeyboardMode =>
      widget.child != null && widget.focusNodes.isNotEmpty;

  bool get _hasInputFocus {
    for (final node in widget.focusNodes) {
      if (node.hasFocus) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();

    _keyboardMotionController = AnimationController.unbounded(
      vsync: this,
      value: 0,
    );

    WidgetsBinding.instance.addObserver(this);
    _attachFocusListeners(widget.focusNodes);

    _keyboardMotionTargetSubscription =
        KeyboardMotionBridge.instance.targets.listen(
      _handleNativeKeyboardMotionTarget,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_combinedKeyboardMode) return;

      _lastReportedInset = _reportedKeyboardInset();
      _syncMotionWithFocus();
    });
  }

  @override
  void didUpdateWidget(AuthBottomAction oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!_sameFocusNodes(oldWidget.focusNodes, widget.focusNodes)) {
      _detachFocusListeners(oldWidget.focusNodes);
      _attachFocusListeners(widget.focusNodes);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_combinedKeyboardMode) return;
        _syncMotionWithFocus();
      });
    }
  }

  @override
  void dispose() {
    _keyboardMotionTargetSubscription?.cancel();

    _detachFocusListeners(widget.focusNodes);
    WidgetsBinding.instance.removeObserver(this);

    _keyboardMotionController.dispose();

    super.dispose();
  }

  bool _sameFocusNodes(List<FocusNode> a, List<FocusNode> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;

    for (var index = 0; index < a.length; index++) {
      if (!identical(a[index], b[index])) return false;
    }

    return true;
  }

  void _attachFocusListeners(List<FocusNode> nodes) {
    for (final node in nodes) {
      node.addListener(_handleFocusChange);
    }
  }

  void _detachFocusListeners(List<FocusNode> nodes) {
    for (final node in nodes) {
      node.removeListener(_handleFocusChange);
    }
  }

  void _handleFocusChange() {
    if (!mounted || !_combinedKeyboardMode) return;

    if (_hasInputFocus) {
      _systemKeyboardCloseStarted = false;

      if (!_motionActive || _keyboardClosing) {
        _beginOpenMotion();
      }
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_combinedKeyboardMode || _hasInputFocus) return;
      _beginCloseMotion();
    });
  }

  void _syncMotionWithFocus() {
    if (_hasInputFocus) {
      _systemKeyboardCloseStarted = false;
      _beginOpenMotion();
    } else {
      _beginCloseMotion();
    }
  }

  double _reportedKeyboardInset() {
    final view = View.of(context);
    final devicePixelRatio =
        view.devicePixelRatio == 0 ? 1.0 : view.devicePixelRatio;

    return view.viewInsets.bottom / devicePixelRatio;
  }

  double _stableSystemBottomInset() {
    final view = View.of(context);
    final devicePixelRatio =
        view.devicePixelRatio == 0 ? 1.0 : view.devicePixelRatio;

    return view.viewPadding.bottom / devicePixelRatio;
  }

  void _beginOpenMotion() {
    if (!mounted || !_combinedKeyboardMode || !_hasInputFocus) return;

    // ── DIAG ───────────────────────────────────────────────────────
    _diagFocusStopwatch = Stopwatch()..start();
    _diagFirstMotionMs = null;
    _diagFirstKeyboardMs = null;
    debugPrint('🟢 [KB] FOCUS gained  t=0ms');
    // ───────────────────────────────────────────────────────────────

    _keyboardMotionController.stop();

    _keyboardClosing = false;
    _motionActive = true;
    _keyboardOpening = true;

    // Only ever bind to what's *currently, actually* reported right now.
    // No cached/native value is used to pre-empt this — if the keyboard
    // happens to already be visible at focus time, this is still live data,
    // not a stale jump-ahead.
    final currentlyReported = _reportedKeyboardInset();
    if (currentlyReported > 1.0) {
      _setOpeningOffset(
        math.max(0.0, currentlyReported - _stableSystemBottomInset()),
      );
    }
    // Otherwise: wait for didChangeMetrics to report real movement — no
    // early jump of any kind.
  }

  /// Directly sets the button's travel offset to match the LIVE reported
  /// keyboard inset for this exact frame — no animation, no duration, no
  /// cached/native pre-jump. Called only from the same didChangeMetrics
  /// call that just measured the new inset, so the button's value updates
  /// in that same frame the keyboard's inset changed. That identity is what
  /// guarantees zero lag in both directions.
  void _setOpeningOffset(double travel) {
    if (!mounted ||
        !_combinedKeyboardMode ||
        !_hasInputFocus ||
        !_motionActive ||
        !_keyboardOpening) {
      return;
    }

    final target = math.max(0.0, travel);

    if ((_keyboardMotionController.value - target).abs() < .01) {
      return;
    }

    // ── DIAG ───────────────────────────────────────────────────────
    if (_diagFirstMotionMs == null && target > 1.0) {
      _diagFirstMotionMs = _diagFocusStopwatch?.elapsedMilliseconds ?? 0;
      debugPrint(
          '🔵 [KB] NEXT BUTTON starts rising  t=${_diagFirstMotionMs}ms   target=$target');
    }
    // ───────────────────────────────────────────────────────────────

    _keyboardMotionController.stop();
    // Set the value immediately — same frame, no tween, no lookahead.
    _keyboardMotionController.value = target;
  }

  void _beginCloseMotion() {
    if (!mounted || _keyboardClosing) return;

    if (!_motionActive &&
        !_keyboardOpening &&
        _keyboardMotionController.value <= .5) {
      _keyboardMotionController.value = 0;
      return;
    }

    _keyboardOpening = false;
    _motionActive = false;
    _keyboardClosing = true;

    _keyboardMotionController.stop();

    if (MediaQuery.disableAnimationsOf(context) ||
        _keyboardMotionController.value <= .5) {
      _keyboardMotionController.value = 0;
      _keyboardClosing = false;
      return;
    }

    _keyboardMotionController
        .animateTo(
          0,
          duration: _keyboardCloseDuration,
          curve: Curves.easeInCubic,
        )
        .whenComplete(() {
          if (mounted) {
            _keyboardClosing = false;
          }
        });
  }

  void _dismissTrackedFocus() {
    for (final node in widget.focusNodes) {
      if (node.hasFocus) node.unfocus();
    }
  }

  void _beginSystemKeyboardClose() {
    if (!mounted || _systemKeyboardCloseStarted) return;

    _systemKeyboardCloseStarted = true;

    _beginCloseMotion();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dismissTrackedFocus();
    });
  }

  /// Diagnostics/reference only. This value is NEVER used to move the
  /// button — it arrives well before the real keyboard visibly rises, and
  /// using it to jump the button early was the exact cause of the button
  /// moving 30–90ms ahead of the keyboard.
  void _handleNativeKeyboardMotionTarget(KeyboardMotionTarget target) {
    if (!mounted || !_combinedKeyboardMode || !target.visible) {
      return;
    }

    final view = View.of(context);
    final devicePixelRatio =
        view.devicePixelRatio == 0 ? 1.0 : view.devicePixelRatio;

    final logicalInset = switch (target.unit) {
      KeyboardMotionInsetUnit.physicalPixels =>
        target.inset / devicePixelRatio,
      KeyboardMotionInsetUnit.logicalPixels => target.inset,
    };

    if (logicalInset > 1.0) {
      // ── DIAG ─────────────────────────────────────────────────────
      final t = _diagFocusStopwatch?.elapsedMilliseconds ?? 0;
      debugPrint(
          '🟣 [KB] NATIVE target received  t=${t}ms   inset=$logicalInset');
      // ─────────────────────────────────────────────────────────────

      _cachedKeyboardInset = logicalInset;
    }
    // Deliberately does nothing else — no flag set, no offset applied.
  }

  @override
  void didChangeMetrics() {
    if (!mounted || !_combinedKeyboardMode) return;

    final reportedInset = _reportedKeyboardInset();
    final previousInset = _lastReportedInset;

    _lastReportedInset = reportedInset;

    // ── DIAG ───────────────────────────────────────────────────────
    if (_diagFirstKeyboardMs == null &&
        reportedInset > previousInset + 5.0 &&
        reportedInset > 30.0) {
      _diagFirstKeyboardMs = _diagFocusStopwatch?.elapsedMilliseconds ?? 0;
      debugPrint(
          '🟡 [KB] REAL KEYBOARD starts rising  t=${_diagFirstKeyboardMs}ms   inset=$reportedInset');

      final motion = _diagFirstMotionMs;
      final keyboard = _diagFirstKeyboardMs;
      if (motion != null && keyboard != null) {
        final delta = keyboard - motion;
        if (delta > 0) {
          debugPrint('🔴 [KB] RESULT: Next button moved FIRST by ${delta}ms');
        } else if (delta < 0) {
          debugPrint('🔴 [KB] RESULT: Keyboard moved FIRST by ${-delta}ms');
        } else {
          debugPrint('🟢 [KB] RESULT: Simultaneous (Δ=0ms)');
        }
      }
    }
    // ───────────────────────────────────────────────────────────────

    final keyboardVisible = reportedInset > 1.0;
    final keyboardJustClosed = previousInset > 1.0 && !keyboardVisible;

    final keyboardStartedClosing = _motionActive &&
        _hasInputFocus &&
        previousInset > 1.0 &&
        reportedInset < previousInset - 1.0;

    if (keyboardVisible && _hasInputFocus && _keyboardOpening) {
      // Bind directly to whatever was just measured — every single call,
      // no exceptions, no cached/native override. This is the only path
      // that ever sets the button's opening offset.
      _setOpeningOffset(
        math.max(0.0, reportedInset - _stableSystemBottomInset()),
      );
    }

    if ((keyboardStartedClosing || keyboardJustClosed) &&
        _hasInputFocus &&
        !_systemKeyboardCloseStarted) {
      _beginSystemKeyboardClose();
    }
  }

  Widget _buildActionContent() {
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: FilledButton(
                  onPressed: widget.busy ? null : widget.onPressed,
                  style: FilledButton.styleFrom(
                    backgroundColor: WrytteColors.primary,
                    foregroundColor: WrytteColors.onPrimary,
                    disabledBackgroundColor: WrytteColors.surfaceRaised,
                    elevation: 0,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    textStyle: widget.compact
                        ? WrytteTypography.authCompactButtonLabel
                        : WrytteTypography.authButtonLabel,
                  ),
                  child: widget.busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: WrytteColors.onPrimary,
                          ),
                        )
                      : Text(
                          widget.label,
                          textAlign: TextAlign.center,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final action = _buildActionContent();

    if (!_combinedKeyboardMode) {
      if (!widget.useBottomSafeArea) return action;

      return SafeArea(
        top: false,
        child: action,
      );
    }

    final stableSystemBottom = _stableSystemBottomInset();

    return AnimatedBuilder(
      animation: _keyboardMotionController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: widget.child!),
          action,
        ],
      ),
      builder: (context, child) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: stableSystemBottom +
                math.max(0.0, _keyboardMotionController.value),
          ),
          child: child,
        );
      },
    );
  }
}
