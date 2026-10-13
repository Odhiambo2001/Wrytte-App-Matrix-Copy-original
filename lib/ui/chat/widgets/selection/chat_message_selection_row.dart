import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';
import 'package:wrytte/ui/chat/widgets/chat_layout_metrics.dart';
import 'package:wrytte/ui/chat/widgets/selection/chat_message_selection_badge.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class ChatMessageSelectionRow extends StatefulWidget {
  const ChatMessageSelectionRow({
    super.key,
    required this.message,
    required this.selectionMode,
    required this.selected,
    required this.onToggle,
    required this.child,
    this.highlightPulse = 0,
  });

  final ChatMessagePresentation message;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggle;
  final Widget child;

  /// Increment this token whenever the row should briefly flash with the same
  /// Wrytte blue used by normal message selection.
  ///
  /// The token allows the SAME pinned message to be highlighted again later
  /// without turning that message into a selected message.
  final int highlightPulse;

  @override
  State<ChatMessageSelectionRow> createState() =>
      _ChatMessageSelectionRowState();
}

class _ChatMessageSelectionRowState
    extends State<ChatMessageSelectionRow>
    with SingleTickerProviderStateMixin {
  static const double _selectorStart = 2;
  static const double _incomingSelectionInset = 38;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAlpha;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration:
          const Duration(milliseconds: 560),
    );

    // The old animation had TWO peaks:
    //
    //   0 -> .13 -> .065 -> .12 -> 0
    //
    // so the row genuinely flashed twice.
    //
    // Pinned navigation now uses ONE pulse only:
    //
    //   0 -> .13 -> 0
    //
    // .13 is intentionally the same maximum opacity as the real selected-row
    // background below.
    _pulseAlpha =
        TweenSequence<double>([
          TweenSequenceItem(
            tween:
                Tween<double>(
                  begin: 0,
                  end: .13,
                ).chain(
                  CurveTween(
                    curve:
                        Curves
                            .easeOutCubic,
                  ),
                ),
            weight: 32,
          ),
          TweenSequenceItem(
            tween:
                Tween<double>(
                  begin: .13,
                  end: 0,
                ).chain(
                  CurveTween(
                    curve:
                        Curves
                            .easeInCubic,
                  ),
                ),
            weight: 68,
          ),
        ]).animate(
          _pulseController,
        );

    // If a far-away pinned message only enters Flutter's lazy list after the
    // navigation token was already incremented, start its one pulse once the
    // row is first mounted.
    if (widget.highlightPulse > 0) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) {
            if (mounted) {
              _pulseController
                  .forward(from: 0);
            }
          });
    }
  }

  @override
  void didUpdateWidget(
    covariant ChatMessageSelectionRow oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);

    if (widget.highlightPulse > 0 &&
        widget.highlightPulse !=
            oldWidget.highlightPulse) {
      // Restart from zero so one pinned-strip tap always gives exactly one
      // complete locator pulse.
      _pulseController.forward(
        from: 0,
      );
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metrics =
        ChatLayoutMetrics.of(context);

    final reduceMotion =
        MediaQuery.disableAnimationsOf(
          context,
        );

    final duration = reduceMotion
        ? Duration.zero
        : const Duration(
            milliseconds: 160,
          );

    if (reduceMotion &&
        _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 0;
    }

    return Semantics(
      container: widget.selectionMode,
      selected: widget.selectionMode
          ? widget.selected
          : null,
      button: widget.selectionMode,
      label: widget.selectionMode
          ? widget.selected
                ? 'Selected message. Tap to deselect.'
                : 'Message. Tap to select.'
          : null,
      child: GestureDetector(
        behavior:
            HitTestBehavior.opaque,
        onTap: widget.selectionMode
            ? widget.onToggle
            : null,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // ---------------------------------------------------------------
            // Real SELECT mode
            // ---------------------------------------------------------------
            //
            // Keep this exactly as the real selection system: persistent blue
            // paint plus the selection badge while selected == true.
            PositionedDirectional(
              start:
                  -metrics
                      .horizontalPadding,
              end:
                  -metrics
                      .horizontalPadding,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child:
                    AnimatedContainer(
                      duration: duration,
                      curve: Curves
                          .easeOutCubic,
                      color: widget
                              .selected
                          ? WrytteColors
                                .primary
                                .withValues(
                                  alpha:
                                      .13,
                                )
                          : Colors
                                .transparent,
                    ),
              ),
            ),

            // ---------------------------------------------------------------
            // Temporary pinned-message locator
            // ---------------------------------------------------------------
            //
            // This borrows ONLY the blue row paint from selection. It does not
            // enter selectionMode, does not show a badge, and now pulses once.
            PositionedDirectional(
              start:
                  -metrics
                      .horizontalPadding,
              end:
                  -metrics
                      .horizontalPadding,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child:
                    AnimatedBuilder(
                      animation:
                          _pulseAlpha,
                      builder:
                          (
                            context,
                            _,
                          ) {
                            final alpha =
                                reduceMotion
                                ? 0.0
                                : _pulseAlpha
                                      .value;

                            return ColoredBox(
                              color:
                                  WrytteColors
                                      .primary
                                      .withValues(
                                        alpha:
                                            alpha,
                                      ),
                            );
                          },
                    ),
              ),
            ),

            AnimatedPadding(
              duration: duration,
              curve:
                  Curves.easeOutCubic,
              padding: EdgeInsetsDirectional.only(
                start:
                    widget.selectionMode && !widget.message.isMine
                    ? _incomingSelectionInset
                    : 0,
              ),
              child: IgnorePointer(
                ignoring: widget.selectionMode,
                child: widget.child,
              ),
            ),

            if (widget.selectionMode)
              PositionedDirectional(
                start: _selectorStart,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Center(
                    child:
                        ChatMessageSelectionBadge(
                          selected:
                              widget
                                  .selected,
                        ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
