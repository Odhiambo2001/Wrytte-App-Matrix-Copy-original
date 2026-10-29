import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_action_menu.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_focus_bubble.dart';
import 'package:wrytte/ui/chat/widgets/message_actions/message_reaction_bar.dart';

class MessageActionOverlay extends StatefulWidget {
  const MessageActionOverlay({
    super.key,
    required this.targetRect,
    required this.overlaySize,
    required this.snapshot,
    required this.config,
    required this.onOpened,
    required this.onClosing,
    required this.onDismissed,
    this.blurSigma = 5.5,
    this.edgePadding = 12,
  });

  final Rect targetRect;
  final Size overlaySize;
  final ui.Image snapshot;
  final MessageActionConfig config;

  final VoidCallback onOpened;
  final VoidCallback onClosing;
  final VoidCallback onDismissed;

  final double blurSigma;
  final double edgePadding;

  @override
  State<MessageActionOverlay> createState() =>
      _MessageActionOverlayState();
}

class _MessageActionOverlayState extends State<MessageActionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _motion;
  late final Animation<double> _panelOpacity;
  late final Animation<double> _panelScale;

  bool _started = false;
  bool _closing = false;
  bool _openedNotified = false;

  late List<MessageAction> _visibleActions;
  late List<String> _visibleReactions;

  bool _showingSecondaryReactions = false;

  @override
  void initState() {
    super.initState();

    _visibleActions = widget.config.actions;
    _visibleReactions = widget.config.reactions;

    // Fast but settled long-press transition.
    //
    // The complete reaction + bubble + menu cluster shares this one timeline.
    // The 160ms return deliberately matches ChatMessageSelectionRow so Select
    // can carry the lifted bubble, emojis, connector, and menu home together
    // without the source row finishing after the overlay disappears.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      reverseDuration: const Duration(milliseconds: 160),
    );

    // ONE motion curve drives the whole floating cluster.
    _motion = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      // During reverse the controller value decreases; easeInCubic here gives
      // the visible return an ease-out arrival at the source position.
      reverseCurve: Curves.easeInCubic,
    );

    // Bring the reaction/menu surfaces in earlier inside the shorter motion.
    // They are already travelling with the bubble, so an early fade feels fast
    // without making them look detached.
    _panelOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(
        .02,
        .72,
        curve: Curves.easeOutCubic,
      ),
      reverseCurve: const Interval(
        .02,
        .88,
        curve: Curves.easeOutCubic,
      ),
    );

    // Keep scale extremely subtle. The speed should come from motion timing,
    // not from a visible pop that makes the menu feel separate from the bubble.
    _panelScale = Tween<double>(
      begin: .992,
      end: 1,
    ).animate(_panelOpacity);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_started) {
      return;
    }

    _started = true;

    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
      _notifyOpened();
      return;
    }

    unawaited(
      _controller.forward().then((_) {
        if (mounted && !_closing) {
          _notifyOpened();
        }
      }),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _notifyOpened() {
    if (_openedNotified) {
      return;
    }

    _openedNotified = true;
    widget.onOpened();
  }

  Future<void> _close() async {
    if (_closing) {
      return;
    }

    _closing = true;
    widget.onClosing();

    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 0;
    } else {
      await _controller.reverse();
    }

    if (!mounted) {
      return;
    }

    widget.onDismissed();
  }

  Future<void> _handleAction(MessageAction action) async {
    if (_closing || !action.isEnabled) {
      return;
    }

    if (widget.config.usePinChoices &&
        action.type == MessageActionType.pin &&
        action.label == 'Pin') {
      setState(() {
        _visibleActions = const <MessageAction>[
          MessageAction(
            type: MessageActionType.pin,
            label: 'Pin for everyone',
          ),
          MessageAction(
            type: MessageActionType.pin,
            label: 'Pin for me',
          ),
          MessageAction(
            type: MessageActionType.pin,
            label: 'Cancel',
          ),
        ];
      });

      return;
    }

    if (widget.config.useDeleteChoices &&
        action.type == MessageActionType.delete &&
        action.label == 'Delete') {
      setState(() {
        _visibleActions = <MessageAction>[
          if (widget.config.canDeleteForEveryone)
            const MessageAction(
              type: MessageActionType.delete,
              label: 'Delete for everyone',
              isDestructive: true,
            ),
          const MessageAction(
            type: MessageActionType.delete,
            label: 'Delete for me',
            isDestructive: true,
          ),
          const MessageAction(
            type: MessageActionType.delete,
            label: 'Cancel',
          ),
        ];
      });

      return;
    }

    if (action.type == MessageActionType.pin &&
        action.label == 'Cancel') {
      await _close();
      return;
    }

    if (action.type == MessageActionType.delete &&
        action.label == 'Cancel') {
      await _close();
      return;
    }

    final MessageActionHandler? handler =
        widget.config.onActionSelected;

    if (action.type == MessageActionType.select && handler != null) {
      // Selection changes the source row's final position to make room for its
      // checkbox. Apply that layout first, while the real bubble is still
      // hidden behind this snapshot, then reverse toward the live target rect.
      // This produces one direct diagonal return instead of returning to the
      // old X-position and shifting sideways afterward.
      await Future<void>.sync(
        () => handler(action),
      );

      if (!mounted) {
        return;
      }

      await WidgetsBinding.instance.endOfFrame;

      if (!mounted) {
        return;
      }

      await _close();
      return;
    }

    await _close();

    if (handler != null) {
      await Future<void>.sync(
        () => handler(action),
      );
    }
  }

  Future<void> _handleReaction(String reaction) async {
    if (_closing) {
      return;
    }

    final MessageReactionHandler? handler =
        widget.config.onReactionSelected;

    await _close();

    if (handler != null) {
      await Future<void>.sync(
        () => handler(reaction),
      );
    }
  }

  Future<void> _handleMoreReactions() async {
    if (_closing) {
      return;
    }

    final MessageMoreReactionsHandler? handler =
        widget.config.onMoreReactions;

    if (handler == null) {
      setState(() {
        _showingSecondaryReactions =
            !_showingSecondaryReactions;

        _visibleReactions = _showingSecondaryReactions
            ? const <String>[
                '😂',
                '😮',
                '😢',
                '🎉',
                '🤔',
                '🙏',
              ]
            : widget.config.reactions;
      });

      return;
    }

    await _close();
    await Future<void>.sync(handler);
  }

  @override
  Widget build(BuildContext context) {
    final _MessageOverlayGeometry geometry =
        _calculateGeometry(context);

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (
        bool didPop,
        Object? result,
      ) {
        if (!didPop) {
          unawaited(_close());
        }
      },
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // ================================================================
            // BACKDROP
            // ================================================================

            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  unawaited(_close());
                },
                child: AnimatedBuilder(
                  animation: _motion,
                  builder: (
                    BuildContext context,
                    Widget? child,
                  ) {
                    final double progress =
                        _motion.value;

                    return ClipRect(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX:
                              widget.blurSigma *
                              progress,
                          sigmaY:
                              widget.blurSigma *
                              progress,
                        ),
                        child: ColoredBox(
                          color: Colors.black.withValues(
                            alpha: .18 * progress,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            // ================================================================
            // ONE MOVING CLUSTER
            // ================================================================
            //
            // Everything below is laid out at FINAL coordinates.
            //
            // Instead of independently moving only the selected bubble while
            // the menu/reactions already sit at their destination, the entire
            // group receives one translation:
            //
            //     reaction bar
            //          ↓
            //       connector
            //          ↓
            //       message
            //          ↓
            //         menu
            //
            // At progress 0, the final-position message is translated exactly
            // back over the real source message. At progress 1, the translation
            // is zero and the complete cluster is at its final geometry.
            //
            // Reverse animation automatically sends the same rigid cluster home.

            Positioned.fill(
              child: AnimatedBuilder(
                animation: _motion,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // ========================================================
                    // SELECTED MESSAGE SNAPSHOT
                    // ========================================================

                    Positioned(
                      left: geometry.bubbleLeft,
                      top: geometry.bubbleTop,
                      width: widget.targetRect.width,
                      height: widget.targetRect.height,
                      child: MessageFocusBubble(
                        image: widget.snapshot,
                        size: widget.targetRect.size,
                        animation: _motion,
                      ),
                    ),

                    // ========================================================
                    // REACTION CONNECTOR
                    // ========================================================

                    if (geometry.showReactions)
                      Positioned.fill(
                        child: FadeTransition(
                          opacity: _panelOpacity,
                          child: IgnorePointer(
                            child:
                                _MessageReactionConnector(
                              largeCenter: geometry
                                  .connectorLargeCenter,
                              smallCenter: geometry
                                  .connectorSmallCenter,
                            ),
                          ),
                        ),
                      ),

                    // ========================================================
                    // REACTION BAR
                    // ========================================================

                    if (geometry.showReactions)
                      Positioned(
                        left: geometry.reactionLeft,

                        // Keep your current visual 5dp drop.
                        // Connector geometry already includes the same offset.
                        top: geometry.reactionTop + 5,

                        width: geometry.reactionWidth,
                        child: FadeTransition(
                          opacity: _panelOpacity,
                          child: ScaleTransition(
                            scale: _panelScale,
                            alignment:
                                geometry.isRightBubble
                                ? Alignment.bottomLeft
                                : Alignment.bottomRight,
                            child: MessageReactionBar(
                              reactions:
                                  _visibleReactions,
                              onReactionSelected:
                                  _handleReaction,
                              onMoreReactions:
                                  _handleMoreReactions,
                            ),
                          ),
                        ),
                      ),

                    // ========================================================
                    // ACTION MENU
                    // ========================================================

                    if (geometry.showMenu)
                      Positioned(
                        left: geometry.menuLeft,
                        top: geometry.menuTop,
                        width: geometry.menuWidth,
                        child: FadeTransition(
                          opacity: _panelOpacity,
                          child: ScaleTransition(
                            scale: _panelScale,
                            alignment:
                                geometry.isRightBubble
                                ? Alignment.topRight
                                : Alignment.topLeft,
                            child: MessageActionMenu(
                              actions:
                                  _visibleActions,
                              maxHeight: geometry
                                  .menuMaxHeight,
                              onSelected:
                                  _handleAction,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                builder: (
                  BuildContext context,
                  Widget? child,
                ) {
                  final double progress =
                      _motion.value;

                  final Offset startOffset = Offset(
                    widget.targetRect.left -
                        geometry.bubbleLeft,
                    widget.targetRect.top -
                        geometry.bubbleTop,
                  );

                  final Offset clusterOffset =
                      Offset(
                    ui.lerpDouble(
                      startOffset.dx,
                      0,
                      progress,
                    )!,
                    ui.lerpDouble(
                      startOffset.dy,
                      0,
                      progress,
                    )!,
                  );

                  return Transform.translate(
                    offset: clusterOffset,
                    transformHitTests: true,
                    child: child,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  _MessageOverlayGeometry _calculateGeometry(
    BuildContext context,
  ) {
    // This geometry is deliberately screen-based rather than IME-based.
    // Opening the keyboard must not change where a long-pressed message,
    // reactions, or action menu settle.
    final MediaQueryData media =
        MediaQuery.of(context);

    final double overlayWidth =
        widget.overlaySize.width;

    final double overlayHeight =
        widget.overlaySize.height;

    final double edge =
        widget.edgePadding;

    // ========================================================================
    // SAFE VIEWPORT
    // ========================================================================

    // IMPORTANT:
    //
    // Message actions intentionally ignore the software keyboard.
    //
    // The chat keeps its IME open while the user long-presses a message, but
    // the reaction/message/menu geometry must remain identical to the normal
    // full-screen layout. Using viewInsets.bottom here would treat the keyboard
    // as a hard wall and compress the complete action cluster into the upper
    // half of the screen.
    //
    // viewPadding is stable while the IME is open, so it preserves only the
    // real physical safe areas (status/navigation/system gesture regions).
    final double safeTop =
        media.viewPadding.top + edge;

    final double safeBottom =
        overlayHeight -
        media.viewPadding.bottom -
        edge;

    final double availableHeight =
        math.max(
      0,
      safeBottom - safeTop,
    );

    final double availableWidth =
        math.max(
      0,
      overlayWidth - (edge * 2),
    );

    // ========================================================================
    // CONTENT
    // ========================================================================

    final bool showReactions =
        widget.config.reactions.isNotEmpty ||
        widget.config.onMoreReactions != null;

    // Keep the focused bubble/menu anchor stable while Pin/Delete submenu rows
    // replace the main action rows.
    final bool wantsMenu =
        widget.config.actions.isNotEmpty;

    final double reactionHeight =
        MessageReactionBar.height;

    // emoji bar
    // connector
    // message
    const double reactionToBubbleGap = 20;

    const double menuGap = 8;

    final double reactionBlockHeight =
        showReactions
        ? reactionHeight +
            reactionToBubbleGap
        : 0;

    final double bubbleHeight =
        widget.targetRect.height;

    // ========================================================================
    // MENU HEIGHT
    // ========================================================================

    // Deliberately based on ORIGINAL actions rather than _visibleActions.
    // That keeps the selected bubble and menu anchor stable when a submenu
    // replaces the main rows.
    final double naturalMenuHeight =
        MessageActionMenu.naturalHeightFor(
      widget.config.actions.length,
    );

    final double maximumMenuBudget =
        math.max(
      0,
      availableHeight -
          reactionBlockHeight -
          bubbleHeight -
          menuGap,
    );

    final double menuMaxHeight =
        wantsMenu
        ? math.min(
            naturalMenuHeight,
            maximumMenuBudget,
          )
        : 0;

    final bool showMenu =
        wantsMenu &&
        menuMaxHeight >=
            MessageActionMenu
                .minimumUsableHeight;

    final double effectiveMenuHeight =
        showMenu
        ? menuMaxHeight
        : 0;

    final double effectiveMenuGap =
        showMenu
        ? menuGap
        : 0;

    // ========================================================================
    // VERTICAL CLUSTER
    // ========================================================================

    final double totalClusterHeight =
        reactionBlockHeight +
        bubbleHeight +
        effectiveMenuGap +
        effectiveMenuHeight;

    final double preferredTop =
        widget.targetRect.top -
        reactionBlockHeight;

    final double latestAllowedTop =
        math.max(
      safeTop,
      safeBottom -
          totalClusterHeight,
    );

    final double groupTop =
        preferredTop
            .clamp(
              safeTop,
              latestAllowedTop,
            )
            .toDouble();

    final double bubbleTop =
        groupTop +
        reactionBlockHeight;

    final double menuTop =
        bubbleTop +
        bubbleHeight +
        effectiveMenuGap;

    // ========================================================================
    // MESSAGE POSITION
    // ========================================================================

    final double bubbleLeft =
        widget.targetRect.left
            .clamp(
              edge,
              math.max(
                edge,
                overlayWidth -
                    edge -
                    widget.targetRect.width,
              ),
            )
            .toDouble();

    final double bubbleWidth =
        widget.targetRect.width;

    final double bubbleRight =
        bubbleLeft +
        bubbleWidth;

    final double distanceToLeft =
        bubbleLeft;

    final double distanceToRight =
        overlayWidth -
        bubbleRight;

    // true  = outgoing / sent / blue
    // false = incoming / received / dark
    final bool isRightBubble = widget.config.alignMenuRight ??
        (distanceToRight < distanceToLeft);

    // ========================================================================
    // MENU WIDTH
    // ========================================================================

    // Also deliberately based on the ORIGINAL action set so submenu swaps do
    // not make the complete floating cluster change width/anchor.
    final double menuWidth =
        wantsMenu
        ? MessageActionMenu.widthFor(
            context,
            actions:
                widget.config.actions,
            availableWidth:
                availableWidth,
          )
        : 0;

    // ========================================================================
    // REACTION WIDTH
    // ========================================================================

    final bool hasMore =
        widget.config.reactions.isNotEmpty;

    final double naturalReactionWidth =
        MessageReactionBar.naturalWidthFor(
      reactionCount:
          widget.config.reactions.length,
      hasMore: hasMore,
    );

    final double reactionWidth =
        showReactions
        ? math.min(
            naturalReactionWidth,
            availableWidth,
          )
        : 0;

    // ========================================================================
    // REACTION BAR POSITION
    // ========================================================================
    //
    // Outgoing:
    // align emoji bar with message top-left.
    //
    // Incoming:
    // align emoji bar with message top-right.

    final double desiredReactionLeft =
        isRightBubble
        ? bubbleLeft
        : bubbleRight -
            reactionWidth;

    final double maximumReactionLeft =
        math.max(
      edge,
      overlayWidth -
          edge -
          reactionWidth,
    );

    final double reactionLeft =
        desiredReactionLeft
            .clamp(
              edge,
              maximumReactionLeft,
            )
            .toDouble();

    final double reactionRight =
        reactionLeft +
        reactionWidth;

    // ========================================================================
    // CONNECTOR GEOMETRY
    // ========================================================================
    //
    // Incoming is the exact horizontal mirror of outgoing.

    final double connectorHeadInset =
        (bubbleWidth * .085)
            .clamp(
              24.0,
              30.0,
            )
            .toDouble();

    const double connectorDiagonal = 11;

    late final double smallX;
    late final double largeX;

    if (isRightBubble) {
      // outgoing / blue
      smallX =
          (bubbleLeft +
                  connectorHeadInset)
              .clamp(
                edge + 4,
                overlayWidth -
                    edge -
                    4,
              )
              .toDouble();

      largeX =
          (smallX -
                  connectorDiagonal)
              .clamp(
                reactionLeft + 14,
                reactionRight - 14,
              )
              .toDouble();
    } else {
      // incoming / dark
      smallX =
          (bubbleRight -
                  connectorHeadInset)
              .clamp(
                edge + 4,
                overlayWidth -
                    edge -
                    4,
              )
              .toDouble();

      largeX =
          (smallX +
                  connectorDiagonal)
              .clamp(
                reactionLeft + 14,
                reactionRight - 14,
              )
              .toDouble();
    }

    // ========================================================================
    // CONNECTOR Y POSITION
    // ========================================================================

    // The reaction bar itself is painted at reactionTop + 5, so use the same
    // visual offset for connector placement.
    const double reactionBarVisualOffset = 5;

    final double reactionVisualBottom =
        groupTop +
        reactionBarVisualOffset +
        reactionHeight;

    final Offset largeCenter =
        Offset(
      largeX,
      reactionVisualBottom - 1.5,
    );

    final Offset smallCenter =
        Offset(
      smallX,
      reactionVisualBottom + 9.5,
    );

    // ========================================================================
    // MENU POSITION
    // ========================================================================

    final double menuLeft =
        showMenu
        ? _anchoredMenuLeft(
            width: menuWidth,
            overlayWidth:
                overlayWidth,
            edge: edge,
            alignRight:
                isRightBubble,
            bubbleLeft:
                bubbleLeft,
          )
        : edge;

    return _MessageOverlayGeometry(
      bubbleLeft: bubbleLeft,
      bubbleTop: bubbleTop,
      reactionLeft: reactionLeft,
      reactionTop: groupTop,
      reactionWidth: reactionWidth,
      menuLeft: menuLeft,
      menuTop: menuTop,
      menuWidth: menuWidth,
      menuMaxHeight:
          effectiveMenuHeight,
      connectorLargeCenter:
          largeCenter,
      connectorSmallCenter:
          smallCenter,
      showReactions:
          showReactions,
      showMenu: showMenu,
      isRightBubble:
          isRightBubble,
    );
  }

  double _anchoredMenuLeft({
    required double width,
    required double overlayWidth,
    required double edge,
    required bool alignRight,
    required double bubbleLeft,
  }) {
    final double bubbleRight =
        bubbleLeft +
        widget.targetRect.width;

    final double desiredLeft =
        alignRight
        ? bubbleRight - width
        : edge;

    final double maximumLeft =
        math.max(
      edge,
      overlayWidth -
          edge -
          width,
    );

    return desiredLeft
        .clamp(
          edge,
          maximumLeft,
        )
        .toDouble();
  }
}

// ============================================================================
// REACTION CONNECTOR
// ============================================================================

class _MessageReactionConnector
    extends StatelessWidget {
  const _MessageReactionConnector({
    required this.largeCenter,
    required this.smallCenter,
  });

  final Offset largeCenter;
  final Offset smallCenter;

  // Exact same sizes for both incoming/outgoing.
  static const double _largeSize = 13.5;
  static const double _smallSize = 6.5;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _ConnectorBubble(
          center: largeCenter,
          size: _largeSize,
          shadowOpacity: .09,
        ),
        _ConnectorBubble(
          center: smallCenter,
          size: _smallSize,
          shadowOpacity: .055,
        ),
      ],
    );
  }
}

// ============================================================================
// SINGLE CONNECTOR BUBBLE
// ============================================================================

class _ConnectorBubble extends StatelessWidget {
  const _ConnectorBubble({
    required this.center,
    required this.size,
    required this.shadowOpacity,
  });

  final Offset center;
  final double size;
  final double shadowOpacity;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: center.dx - (size / 2),
      top: center.dy - (size / 2),
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: shadowOpacity,
              ),
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipOval(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX:
                  MessageReactionBar
                      .blurSigma,
              sigmaY:
                  MessageReactionBar
                      .blurSigma,
              tileMode: TileMode.clamp,
            ),
            child: ColoredBox(
              color:
                  MessageReactionBar
                      .surfaceColor,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// OVERLAY GEOMETRY
// ============================================================================

class _MessageOverlayGeometry {
  const _MessageOverlayGeometry({
    required this.bubbleLeft,
    required this.bubbleTop,
    required this.reactionLeft,
    required this.reactionTop,
    required this.reactionWidth,
    required this.menuLeft,
    required this.menuTop,
    required this.menuWidth,
    required this.menuMaxHeight,
    required this.connectorLargeCenter,
    required this.connectorSmallCenter,
    required this.showReactions,
    required this.showMenu,
    required this.isRightBubble,
  });

  final double bubbleLeft;
  final double bubbleTop;

  final double reactionLeft;
  final double reactionTop;
  final double reactionWidth;

  final double menuLeft;
  final double menuTop;
  final double menuWidth;
  final double menuMaxHeight;

  final Offset connectorLargeCenter;
  final Offset connectorSmallCenter;

  final bool showReactions;
  final bool showMenu;
  final bool isRightBubble;
}
