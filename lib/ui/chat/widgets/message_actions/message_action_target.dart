import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_action_overlay.dart';

enum MessageActionPhase { idle, capturing, opening, open, closing }

class MessageActionTarget extends StatefulWidget {
  const MessageActionTarget({
    super.key,
    required this.child,
    required this.config,
    this.enabled = true,
  });

  final Widget child;
  final MessageActionConfig config;
  final bool enabled;

  @override
  State<MessageActionTarget> createState() => _MessageActionTargetState();
}

class _MessageActionTargetState extends State<MessageActionTarget> {
  final GlobalKey _captureKey = GlobalKey(debugLabel: 'message-action-source');

  final OverlayPortalController _overlayController = OverlayPortalController(
    debugLabel: 'message-action-overlay',
  );

  ui.Image? _snapshot;

  MessageActionPhase _phase = MessageActionPhase.idle;

  bool get _sourceHidden =>
      _phase == MessageActionPhase.opening ||
      _phase == MessageActionPhase.open ||
      _phase == MessageActionPhase.closing;

  bool get _busy => _phase != MessageActionPhase.idle;

  @override
  void dispose() {
    _snapshot?.dispose();
    _snapshot = null;
    super.dispose();
  }

  // ===========================================================================
  // Haptic
  // ===========================================================================

  Future<void> _fireHaptic() async {
    await Feedback.forLongPress(context);
  }

  // ===========================================================================
  // Open / close
  // ===========================================================================

  Future<void> _open({bool longPressFeedback = false}) async {
    if (!widget.enabled || !widget.config.hasContent || _busy || !mounted) {
      return;
    }

    setState(() {
      _phase = MessageActionPhase.capturing;
    });

    // Only an actual touch long-press should produce the haptic.
    //
    // Do not await it: the haptic and the visual transition begin together.
    // Match old Wrytte: let Flutter request the platform's native long-press
    // feedback instead of substituting a selection or custom vibration effect.
    if (longPressFeedback) {
      unawaited(_fireHaptic());
    }

    // Wait until the current frame is completely painted before taking the
    // snapshot. This prevents toImage() from racing against unfinished layout
    // or paint.
    await WidgetsBinding.instance.endOfFrame;

    if (!mounted || _phase != MessageActionPhase.capturing) {
      return;
    }

    final RenderObject? renderObject = _captureKey.currentContext
        ?.findRenderObject();

    if (renderObject is! RenderRepaintBoundary) {
      _returnToIdle();
      return;
    }

    ui.Image? capturedImage;

    try {
      final double pixelRatio = MediaQuery.devicePixelRatioOf(
        context,
      ).clamp(1.0, 3.0).toDouble();

      capturedImage = await renderObject.toImage(pixelRatio: pixelRatio);

      if (!mounted || _phase != MessageActionPhase.capturing) {
        capturedImage.dispose();
        return;
      }

      _snapshot?.dispose();
      _snapshot = capturedImage;
      capturedImage = null;

      // The source becomes invisible at the same time the overlay snapshot
      // becomes available. Its layout space remains untouched, so messages
      // around it never jump.
      setState(() {
        _phase = MessageActionPhase.opening;
      });

      _overlayController.show();
    } catch (_) {
      capturedImage?.dispose();
      _returnToIdle();
    }
  }

  void _handleOpened() {
    if (!mounted || _phase != MessageActionPhase.opening) {
      return;
    }

    setState(() {
      _phase = MessageActionPhase.open;
    });
  }

  void _handleClosing() {
    if (!mounted ||
        (_phase != MessageActionPhase.open &&
            _phase != MessageActionPhase.opening)) {
      return;
    }

    setState(() {
      _phase = MessageActionPhase.closing;
    });
  }

  void _handleDismissed() {
    if (!mounted) {
      return;
    }

    // At this point the overlay animation has returned the captured bubble to
    // its current source position. For Select this is the checkbox-cleared
    // selection position; for every other close it is the original position.
    //
    // We now hide the overlay and restore the real source bubble. This prevents:
    // - duplicate bubbles
    // - flashes
    // - collapsing list space
    // - the source appearing before the overlay gets home
    _overlayController.hide();

    final ui.Image? imageToDispose = _snapshot;
    _snapshot = null;

    setState(() {
      _phase = MessageActionPhase.idle;
    });

    // RawImage may still reference the ui.Image during the frame where the
    // overlay is being removed. Dispose it only after that frame finishes.
    if (imageToDispose != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        imageToDispose.dispose();
      });
    }
  }

  void _returnToIdle() {
    if (!mounted) {
      return;
    }

    _overlayController.hide();

    final ui.Image? imageToDispose = _snapshot;
    _snapshot = null;

    setState(() {
      _phase = MessageActionPhase.idle;
    });

    imageToDispose?.dispose();
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlayController,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder:
          (BuildContext overlayContext, OverlayChildLayoutInfo info) {
            final ui.Image? snapshot = _snapshot;

            if (snapshot == null) {
              return const SizedBox.shrink();
            }

            // Convert the real message bubble's position into the root overlay's
            // coordinate system. This gives the overlay snapshot its exact starting
            // and returning position.
            final Rect targetRect = MatrixUtils.transformRect(
              info.childPaintTransform,
              Offset.zero & info.childSize,
            );

            return MessageActionOverlay(
              targetRect: targetRect,
              overlaySize: info.overlaySize,
              snapshot: snapshot,
              config: widget.config,
              onOpened: _handleOpened,
              onClosing: _handleClosing,
              onDismissed: _handleDismissed,
            );
          },
      child: IgnorePointer(
        // Once message actions begin opening, the real message underneath should
        // no longer receive input.
        ignoring: _busy,
        child: ExcludeSemantics(
          // Accessibility should interact with the overlay copy while the
          // original source is visually hidden.
          excluding: _sourceHidden,
          child: Opacity(
            // IMPORTANT:
            //
            // Do NOT use AnimatedOpacity here.
            //
            // The overlay snapshot visually replaces this widget. Cross-fading
            // the real bubble and snapshot would create a temporary duplicate /
            // brighter bubble.
            //
            // The source remains in layout at opacity 0 so the ListView never
            // collapses its space.
            opacity: _sourceHidden ? 0 : 1,
            child: RepaintBoundary(
              key: _captureKey,
              child: GestureDetector(
                behavior: HitTestBehavior.deferToChild,

                // Mobile / touch:
                // Long press opens the menu and fires noticeable feedback.
                onLongPress: widget.enabled
                    ? () {
                        _open(longPressFeedback: true);
                      }
                    : null,

                // Desktop / mouse:
                // Right-click opens the exact same menu but does NOT vibrate.
                onSecondaryTap: widget.enabled
                    ? () {
                        _open();
                      }
                    : null,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
