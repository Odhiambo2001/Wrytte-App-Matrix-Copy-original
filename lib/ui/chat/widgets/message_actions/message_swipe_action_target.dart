import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/gestures.dart';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';

import 'package:flutter/physics.dart';

import 'package:flutter/rendering.dart';

import 'package:flutter/services.dart';

import 'package:vibration/vibration.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';

import 'package:wrytte/ui/chat/widgets/chat_layout_metrics.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

/// Horizontal swipe actions for a Wrytte chat message.

///

/// Gesture:

/// - swipe right -> Reply

/// - swipe left  -> Forward

///

/// Visual behaviour:

/// - the bubble starts moving first;

/// - after a small amount of movement, the 30px action begins tiny/faint in

///   whatever clean space actually exists;

/// - its scale is physically limited by the opening between the screen edge

///   and the translated bubble, so it never appears through the bubble;

/// - the action becomes fully visible at the SAME point the swipe becomes

///   actionable;

/// - release before the threshold -> immediate spring home;

/// - release at/after the threshold -> Reply / Forward, then spring home.

///

/// There is deliberately no parked, latched or delayed "tap peek" state. A

/// transient swipe affordance should never remain stranded beside a message.

class MessageSwipeActionTarget extends StatefulWidget {

  const MessageSwipeActionTarget({

    super.key,

    required this.child,

    required this.config,

    this.enabled = true,

  });

  final Widget child;

  final MessageActionConfig config;

  final bool enabled;

  // Pointer IDs that began on an actual message swipe target.

  //

  // ChatView uses this to distinguish a real bubble interaction from a tap on

  // empty conversation space. Raw-pointer tracking does not join the gesture

  // arena, so it does not interfere with media taps, long-press, or swipe.

  static final Set<int> _activeBubblePointers = <int>{};

  static bool ownsPointer(int pointer) =>

      _activeBubblePointers.contains(pointer);

  @override

  State<MessageSwipeActionTarget> createState() =>

      _MessageSwipeActionTargetState();

}

class _MessageSwipeActionTargetState extends State<MessageSwipeActionTarget>

    with SingleTickerProviderStateMixin {

  /// Only one mounted message may own an active/revealed swipe at a time.

  static _MessageSwipeActionTargetState? _activeOwner;

  final OverlayPortalController _actionOverlayController =

      OverlayPortalController(

        debugLabel: 'message-swipe-action-overlay',

      );

  late final AnimationController _gestureController;

  bool _dragging = false;

  bool _armed = false;

  bool _overlayVisible = false;

  bool _dispatching = false;

  final Set<int> _ownedBubblePointers = <int>{};

  // Fires the threshold click only once for each finger-down swipe gesture.

  bool _thresholdHapticPlayed = false;

  // Shared capability cache. Every message bubble uses this widget, so query

  // Android only once instead of making platform-channel calls per bubble.

  static _SwipeHapticCapabilities? _hapticCapabilities;

  static Future<void>? _hapticWarmup;

  // ===========================================================================

  // Swipe commitment

  // ===========================================================================

  static const double _minimumFlickFraction = .58;

  static const double _flickVelocity = 950;

  // ===========================================================================

  // Old Wrytte action geometry

  // ===========================================================================

  static const double _actionDiameter = 30;

  static const double _actionIconSize = 17;

  static const double _actionEdgeInset = 12;

  static const double _actionBubbleInset = 3;

  static const double _actionMovementFactor = .45;

  // Start sooner than the old implementation, but start MUCH smaller.

  //

  // The physical-space limiter below is still the final authority, so an

  // action can never draw through the bubble simply because this starts early.

  static const double _actionRevealVisualDistance = 9;

  static const double _actionHideVisualDistance = 6;

  static const double _actionOpacityStartDistance = 8;

  @override

  void initState() {

    super.initState();

    _gestureController = AnimationController.unbounded(vsync: this)

      ..addListener(_handleGestureTick);

    // Warm the shared Android vibration capability cache before the user reaches

    // the swipe threshold. This keeps the click immediate instead of doing two

    // platform-channel capability checks at the exact threshold frame.

    unawaited(_warmHapticCapabilities());

  }

  @override

  void didUpdateWidget(MessageSwipeActionTarget oldWidget) {

    super.didUpdateWidget(oldWidget);

    if (!widget.enabled && oldWidget.enabled) {

      _returnHome();

    }

  }

  @override

  void dispose() {

    if (identical(_activeOwner, this)) {

      _activeOwner = null;

    }

    MessageSwipeActionTarget._activeBubblePointers

        .removeAll(_ownedBubblePointers);

    _ownedBubblePointers.clear();

    _gestureController

      ..removeListener(_handleGestureTick)

      ..dispose();

    super.dispose();

  }

  // ===========================================================================

  // Actions

  // ===========================================================================

  MessageAction? _actionOfType(MessageActionType type) {

    for (final action in widget.config.actions) {

      if (action.type == type && action.isEnabled) {

        return action;

      }

    }

    return null;

  }

  MessageAction? get _replyAction =>

      _actionOfType(MessageActionType.reply);

  MessageAction? get _forwardAction =>

      _actionOfType(MessageActionType.forward);

  bool get _canReply =>

      widget.enabled &&

      !_dispatching &&

      widget.config.onActionSelected != null &&

      _replyAction != null;

  bool get _canForward =>

      widget.enabled &&

      !_dispatching &&

      widget.config.onActionSelected != null &&

      _forwardAction != null;

  bool get _canSwipe => _canReply || _canForward;

  bool _directionAllowed(double value) {

    if (value > 0) {

      return _canReply;

    }

    if (value < 0) {

      return _canForward;

    }

    return true;

  }

  MessageAction? _actionForOffset(double value) {

    if (value > 0) {

      return _replyAction;

    }

    if (value < 0) {

      return _forwardAction;

    }

    return null;

  }

  // ===========================================================================

  // Bubble movement

  // ===========================================================================

  double _triggerDistance(BuildContext context) {

    final metrics = ChatLayoutMetrics.of(context);

    return (metrics.controlSize + (16 * metrics.scale))

        .clamp(58.0, 66.0)

        .toDouble();

  }

  /// Keep the bubble movement that already tested well:

  /// direct through the threshold, then a small rubber-band over-pull.

  double _bubblePaintOffset(

    double gestureOffset,

    BuildContext context,

  ) {

    if (gestureOffset == 0) {

      return 0;

    }

    final sign = gestureOffset.sign;

    final magnitude = gestureOffset.abs();

    final trigger = _triggerDistance(context);

    if (magnitude <= trigger) {

      return gestureOffset;

    }

    final extra = magnitude - trigger;

    final maximumExtra = trigger * .40;

    final responseLength = trigger * .40;

    final resistedExtra =

        maximumExtra *

        (1 -

            math.exp(

              -extra / math.max(1.0, responseLength),

            ));

    return sign * (trigger + resistedExtra);

  }

  // ===========================================================================

  // Action reveal math

  // ===========================================================================

  double _actionPopScale(

    double visualDistance,

    double triggerDistance,

  ) {

    final progress =

        ((visualDistance - _actionRevealVisualDistance) /

                math.max(

                  1.0,

                  triggerDistance - _actionRevealVisualDistance,

                ))

            .clamp(0.0, 1.0)

            .toDouble();

    if (progress <= 0) {

      return 0;

    }

    // Monotonic by design:

    //

    // tiny -> growing -> exactly 1.0 at the action threshold.

    //

    // The indicator never looks "fully ready" while the swipe is still

    // functionally below the trigger.

    return Curves.easeOutCubic.transform(

      progress,

    );

  }

  double _actionOpacity(

    double visualDistance,

    double triggerDistance,

  ) {

    final progress =

        ((visualDistance - _actionOpacityStartDistance) /

                math.max(

                  1.0,

                  triggerDistance - _actionOpacityStartDistance,

                ))

            .clamp(0.0, 1.0)

            .toDouble();

    return Curves.easeOutCubic.transform(

      progress,

    );

  }

  /// Final safety rule: the circle may only become as large as the ACTUAL

  /// physical opening allows.

  double _maximumActionScaleForPhysicalSpace(

    double physicalOpening,

  ) {

    final availableWidth =

        physicalOpening -

        _actionEdgeInset -

        _actionBubbleInset;

    if (availableWidth <= 0) {

      return 0;

    }

    return (availableWidth / _actionDiameter)

        .clamp(

          0.0,

          1.0,

        )

        .toDouble();

  }

  double _actionCenterFromEdge({

    required double createdVisualDistance,

    required double physicalOpening,

    required double scale,

  }) {

    final scaledRadius =

        (_actionDiameter * scale) / 2;

    final minimumCenter =

        _actionEdgeInset + scaledRadius;

    final maximumCenter =

        physicalOpening -

        _actionBubbleInset -

        scaledRadius;

    if (maximumCenter <= minimumCenter) {

      return minimumCenter;

    }

    final movementAfterReveal =

        math.max(

          0.0,

          createdVisualDistance -

              _actionRevealVisualDistance,

        );

    final baseCenter =

        _actionEdgeInset +

        (_actionDiameter / 2);

    final desiredCenter =

        baseCenter +

        (movementAfterReveal *

            _actionMovementFactor);

    return desiredCenter

        .clamp(

          minimumCenter,

          maximumCenter,

        )

        .toDouble();

  }

  // ===========================================================================

  // Overlay visibility

  // ===========================================================================

  void _showActionOverlay() {

    if (_overlayVisible || !mounted) {

      return;

    }

    _overlayVisible = true;

    _actionOverlayController.show();

  }

  void _hideActionOverlay() {

    if (!_overlayVisible) {

      return;

    }

    _overlayVisible = false;

    _actionOverlayController.hide();

  }

  void _handleGestureTick() {

    if (mounted) {

      setState(() {});

    }

  }

  // ===========================================================================

  // Threshold haptic

  // ===========================================================================

  static Future<void> _warmHapticCapabilities() {

    return _hapticWarmup ??= _loadHapticCapabilities();

  }

  static Future<void> _loadHapticCapabilities() async {

    // Keep Apple platforms on Flutter's native haptic APIs. The direct

    // vibration path below is specifically for the Android swipe click.

    if (defaultTargetPlatform != TargetPlatform.android) {

      _hapticCapabilities = const _SwipeHapticCapabilities(

        hasVibrator: false,

        hasAmplitudeControl: false,

      );

      return;

    }

    try {

      final hasVibrator = await Vibration.hasVibrator();

      final hasAmplitudeControl =

          hasVibrator && await Vibration.hasAmplitudeControl();

      _hapticCapabilities = _SwipeHapticCapabilities(

        hasVibrator: hasVibrator,

        hasAmplitudeControl: hasAmplitudeControl,

      );

    } catch (_) {

      // If the plugin cannot report capabilities, the threshold handler falls

      // back to Flutter's system haptic instead of blocking the swipe.

      _hapticCapabilities = const _SwipeHapticCapabilities(

        hasVibrator: false,

        hasAmplitudeControl: false,

      );

    }

  }

  Future<void> _fireHaptic() async {

    // Flutter's native selection haptic is the better semantic choice outside

    // Android, and it also acts as our no-plugin/no-motor fallback.

    if (defaultTargetPlatform != TargetPlatform.android) {

      await HapticFeedback.selectionClick();

      return;

    }

    final capabilities = _hapticCapabilities;

    // Do not wait for capability probing at the exact swipe threshold. If the

    // one-time warm-up has not completed yet, fire the system haptic now.

    if (capabilities == null || !capabilities.hasVibrator) {

      await HapticFeedback.selectionClick();

      return;

    }

    try {

      await Vibration.vibrate(

        duration: 10,

        amplitude: capabilities.hasAmplitudeControl ? 40 : -1,

      );

    } catch (_) {

      await HapticFeedback.selectionClick();

    }

  }

  void _handleBubblePointerDown(PointerDownEvent event) {

    _ownedBubblePointers.add(event.pointer);

    MessageSwipeActionTarget._activeBubblePointers.add(event.pointer);

  }

  void _handleBubblePointerEnd(PointerEvent event) {

    _ownedBubblePointers.remove(event.pointer);

    MessageSwipeActionTarget._activeBubblePointers.remove(event.pointer);

  }

  // ===========================================================================

  // Gesture

  // ===========================================================================

  void _handleDragStart(DragStartDetails details) {

    if (!_canSwipe) {

      return;

    }

    final previousOwner = _activeOwner;

    if (previousOwner != null &&

        !identical(previousOwner, this)) {

      previousOwner._returnHome(

        hideOverlayImmediately: true,

      );

    }

    _activeOwner = this;

    _gestureController.stop();

    _dragging = true;

    final trigger = _triggerDistance(context);

    _armed =

        _directionAllowed(_gestureController.value) &&

        _gestureController.value.abs() >= trigger;

    // A re-grab while the spring is still beyond the threshold should not

    // immediately produce a second click. A normal fresh swipe starts false.

    _thresholdHapticPlayed = _armed;

  }

  void _handleDragUpdate(DragUpdateDetails details) {

    if (!_dragging || !_canSwipe) {

      return;

    }

    var nextValue =

        _gestureController.value +

        details.delta.dx;

    if (!_directionAllowed(nextValue)) {

      nextValue = 0;

    }

    _gestureController.value = nextValue;

    final visualDistance =

        _bubblePaintOffset(

          nextValue,

          context,

        ).abs();

    if (!_overlayVisible &&

        visualDistance >= _actionHideVisualDistance) {

      _showActionOverlay();

    } else if (_overlayVisible &&

        visualDistance < _actionHideVisualDistance) {

      _hideActionOverlay();

    }

    final trigger = _triggerDistance(context);

    final nowArmed =

        _directionAllowed(nextValue) &&

        nextValue.abs() >= trigger;

    // Fire exactly once when this finger-down gesture first crosses the action

    // threshold. Moving back and forth around the boundary must not buzz again.

    if (nowArmed && !_thresholdHapticPlayed) {

      _thresholdHapticPlayed = true;

      unawaited(_fireHaptic());

    }

    _armed = nowArmed;

  }

  void _handleDragEnd(DragEndDetails details) {

    if (!_dragging) {

      return;

    }

    _dragging = false;

    final value = _gestureController.value;

    final magnitude = value.abs();

    final trigger = _triggerDistance(context);

    final velocity =

        details.primaryVelocity ?? 0;

    final sameDirectionVelocity =

        value == 0 ||

        velocity == 0 ||

        velocity.sign == value.sign;

    final committedByDistance =

        magnitude >= trigger;

    final committedByFlick =

        sameDirectionVelocity &&

        magnitude >=

            trigger * _minimumFlickFraction &&

        velocity.abs() >= _flickVelocity;

    final action = _actionForOffset(value);

    if (action != null &&

        (committedByDistance ||

            committedByFlick)) {

      unawaited(

        _commitAction(

          action,

          releaseVelocity: velocity,

        ),

      );

      return;

    }

    // No intermediate resting state. If the swipe was not committed, the

    // message begins returning on this exact release frame.

    _returnHome(

      releaseVelocity: velocity,

    );

  }

  void _handleDragCancel() {

    if (!_dragging) {

      return;

    }

    _dragging = false;

    _returnHome();

  }

  // ===========================================================================

  // Dispatch

  // ===========================================================================

  Future<void> _commitAction(

    MessageAction action, {

    double releaseVelocity = 0,

  }) async {

    if (_dispatching || !mounted) {

      return;

    }

    final handler =

        widget.config.onActionSelected;

    if (handler == null ||

        !action.isEnabled) {

      _returnHome(

        releaseVelocity: releaseVelocity,

      );

      return;

    }

    _dispatching = true;

    _armed = false;

    _returnHome(

      releaseVelocity: releaseVelocity,

    );

    try {

      await Future<void>.sync(

        () => handler(action),

      );

    } finally {

      if (mounted) {

        setState(() {

          _dispatching = false;

        });

      }

    }

  }

  // ===========================================================================

  // Spring home

  // ===========================================================================

  void _returnHome({

    double releaseVelocity = 0,

    bool hideOverlayImmediately = false,

  }) {

    if (!mounted) {

      return;

    }

    _dragging = false;

    _armed = false;

    if (hideOverlayImmediately) {

      _hideActionOverlay();

    }

    final current =

        _gestureController.value;

    if (current.abs() <= .01) {

      _gestureController.value = 0;

      _hideActionOverlay();

      if (identical(_activeOwner, this)) {

        _activeOwner = null;

      }

      return;

    }

    if (MediaQuery.disableAnimationsOf(context)) {

      _gestureController.value = 0;

      _hideActionOverlay();

      if (identical(_activeOwner, this)) {

        _activeOwner = null;

      }

      return;

    }

    const spring = SpringDescription(

      mass: 1,

      stiffness: 520,

      damping: 46,

    );

    // Preserve release velocity only when the finger was already travelling

    // back toward zero. If it was still travelling outward, starting the home

    // spring with that outward velocity creates a visible hesitation/overshoot.

    final velocityTowardHome =

        releaseVelocity != 0 &&

        releaseVelocity.sign == -current.sign

        ? releaseVelocity

              .clamp(-2200.0, 2200.0)

              .toDouble()

        : 0.0;

    final simulation = SpringSimulation(

      spring,

      current,

      0,

      velocityTowardHome,

      snapToEnd: true,

    );

    unawaited(

      _gestureController

          .animateWith(simulation)

          .whenComplete(() {

        if (!mounted) {

          return;

        }

        _gestureController.value = 0;

        _hideActionOverlay();

        if (identical(_activeOwner, this)) {

          _activeOwner = null;

        }

      }),

    );

  }

  // ===========================================================================

  // Old Wrytte Reply / Forward visual

  // ===========================================================================

  Widget _buildOldWrytteActionIcon({

    required bool reply,

  }) {

    Widget icon = const WrytteSvgIcon(

      asset:

          'assets/svg/Forward and Reply icon fill.svg',

      size: _actionIconSize,

      color: Colors.white,

    );

    if (reply) {

      icon = Transform.flip(

        flipX: true,

        child: icon,

      );

    }

    return icon;

  }

  Widget _buildActionCircle({

    required bool reply,

  }) {

    return Container(

      width: _actionDiameter,

      height: _actionDiameter,

      decoration: BoxDecoration(

        color: WrytteColors.surfaceRaised,

        shape: BoxShape.circle,

        boxShadow: [

          BoxShadow(

            color:

                Colors.black.withValues(

              alpha: .14,

            ),

            blurRadius: 6,

            offset: const Offset(0, 2),

          ),

        ],

      ),

      child: Center(

        child: _buildOldWrytteActionIcon(

          reply: reply,

        ),

      ),

    );

  }

  // ===========================================================================

  // Action overlay

  // ===========================================================================

  Widget _buildActionOverlay(

    BuildContext overlayContext,

    OverlayChildLayoutInfo info,

  ) {

    final gestureValue =

        _gestureController.value;

    if (gestureValue == 0) {

      return const SizedBox.shrink();

    }

    final action =

        _actionForOffset(gestureValue);

    if (action == null) {

      return const SizedBox.shrink();

    }

    final reply = gestureValue > 0;

    final bubbleOffset =

        _bubblePaintOffset(

          gestureValue,

          overlayContext,

        );

    final createdVisualDistance =

        bubbleOffset.abs();

    if (createdVisualDistance <

        _actionRevealVisualDistance) {

      return const SizedBox.shrink();

    }

    final sourceRect =

        MatrixUtils.transformRect(

          info.childPaintTransform,

          Offset.zero & info.childSize,

        );

    final translatedRect =

        sourceRect.shift(

          Offset(bubbleOffset, 0),

        );

    final viewPadding =

        MediaQuery.viewPaddingOf(

          overlayContext,

        );

    final physicalScreenLeft =

        viewPadding.left;

    final physicalScreenRight =

        info.overlaySize.width -

        viewPadding.right;

    final physicalOpening = reply

        ? translatedRect.left -

            physicalScreenLeft

        : physicalScreenRight -

            translatedRect.right;

    final trigger =

        _triggerDistance(overlayContext);

    final desiredScale =

        _actionPopScale(

          createdVisualDistance,

          trigger,

        );

    final spaceLimitedScale =

        _maximumActionScaleForPhysicalSpace(

          physicalOpening,

        );

    final scale = math.min(

      desiredScale,

      spaceLimitedScale,

    );

    // This is the key "never from behind the bubble" rule.

    if (scale <= .01) {

      return const SizedBox.shrink();

    }

    final centerFromEdge =

        _actionCenterFromEdge(

          createdVisualDistance:

              createdVisualDistance,

          physicalOpening:

              physicalOpening,

          scale: scale,

        );

    final centerX = reply

        ? physicalScreenLeft +

            centerFromEdge

        : physicalScreenRight -

            centerFromEdge;

    final visualLeft =

        centerX - (_actionDiameter / 2);

    final visualTop =

        (sourceRect.center.dy -

                (_actionDiameter / 2))

            .clamp(

              0.0,

              math.max(

                0.0,

                info.overlaySize.height -

                    _actionDiameter,

              ),

            )

            .toDouble();

    final opacity =

        _actionOpacity(

          createdVisualDistance,

          trigger,

        );

    if (opacity <= .01) {

      return const SizedBox.shrink();

    }

    return SizedBox.fromSize(

      size: info.overlaySize,

      child: Stack(

        clipBehavior: Clip.none,

        children: [

          Positioned(

            left: visualLeft,

            top: visualTop,

            width: _actionDiameter,

            height: _actionDiameter,

            child: IgnorePointer(

              // Swipe actions commit on release. Keeping this indicator

              // non-interactive avoids introducing a second gesture lifecycle

              // or a parked state beside the message.

              child: Opacity(

                opacity: opacity,

                child: Transform.scale(

                  scale: scale,

                  alignment: Alignment.center,

                  child: _buildActionCircle(

                    reply: reply,

                  ),

                ),

              ),

            ),

          ),

        ],

      ),

    );

  }

  // ===========================================================================

  // Build

  // ===========================================================================

  @override

  Widget build(BuildContext context) {

    final canSwipe = _canSwipe;

    final bubbleOffset =

        _bubblePaintOffset(

          _gestureController.value,

          context,

        );

    return OverlayPortal.overlayChildLayoutBuilder(

      controller:

          _actionOverlayController,

      overlayLocation:

          OverlayChildLocation.rootOverlay,

      overlayChildBuilder:

          _buildActionOverlay,

      child: Listener(

        behavior: HitTestBehavior.translucent,

        onPointerDown: _handleBubblePointerDown,

        onPointerUp: _handleBubblePointerEnd,

        onPointerCancel: _handleBubblePointerEnd,

        child: GestureDetector(

          behavior:

              HitTestBehavior.deferToChild,

        // Deliberately no ordinary onTap here.

        //

        // This keeps existing video/audio/file/contact/text taps in their

        // current widgets instead of adding a competing recognizer.

        dragStartBehavior:

            DragStartBehavior.start,

        onHorizontalDragStart: canSwipe

            ? _handleDragStart

            : null,

        onHorizontalDragUpdate: canSwipe

            ? _handleDragUpdate

            : null,

        onHorizontalDragEnd: canSwipe

            ? _handleDragEnd

            : null,

        onHorizontalDragCancel: canSwipe

            ? _handleDragCancel

            : null,

          child: RepaintBoundary(

            child: Transform.translate(

              offset: Offset(

                bubbleOffset,

                0,

              ),

              transformHitTests: true,

              child: widget.child,

            ),

          ),

        ),

      ),

    );

  }

}

class _SwipeHapticCapabilities {

  const _SwipeHapticCapabilities({

    required this.hasVibrator,

    required this.hasAmplitudeControl,

  });

  final bool hasVibrator;

  final bool hasAmplitudeControl;

}
