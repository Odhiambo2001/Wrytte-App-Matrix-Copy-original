import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';
import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/chat/view_models/chat_audio_playback_view_model.dart';
import 'package:wrytte/ui/chat/view_models/chat_video_playback_view_model.dart';
import 'package:wrytte/ui/chat/widgets/chat_layout_metrics.dart';
import 'package:wrytte/ui/chat/widgets/chat_message_bubble.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_icon_button.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class PinnedMessagesView extends StatefulWidget {
  const PinnedMessagesView({
    super.key,
    required this.messages,
    required this.audioPlayback,
    required this.videoPlayback,
    required this.onActionSelected,
    required this.onUnpinAll,
    this.onBeforeVideoPlay,
    this.onReactionSelected,
  });

  final List<ChatMessagePresentation> messages;
  final ChatAudioPlaybackViewModel audioPlayback;
  final ChatVideoPlaybackViewModel videoPlayback;
  final ChatMessageActionCallback onActionSelected;
  final FutureOr<void> Function() onUnpinAll;
  final Future<void> Function()? onBeforeVideoPlay;
  final ChatMessageReactionCallback? onReactionSelected;

  @override
  State<PinnedMessagesView> createState() => _PinnedMessagesViewState();
}

class _PinnedMessagesViewState extends State<PinnedMessagesView> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  late final List<ChatMessagePresentation> _messages =
      List.of(widget.messages);

  bool _searching = false;
  bool _unpinning = false;

  List<ChatMessagePresentation> get _visibleMessages {
    final query = _searchController.text.trim().toLowerCase();

    if (query.isEmpty) {
      return _messages;
    }

    return _messages
        .where((message) {
          final content = <String>[
            message.text ?? '',
            message.fileName ?? '',
            message.senderName ?? '',
            message.contactName ?? '',
            message.contactPhone ?? '',
          ].join(' ').toLowerCase();

          return content.contains(query);
        })
        .toList(growable: false);
  }

  static const _actions = <MessageAction>[
    MessageAction.copy(),
    MessageAction.unpin(),
    MessageAction.forward(),
    MessageAction.delete(),
  ];

  Future<void> _handleAction(
    ChatMessagePresentation message,
    MessageAction action,
  ) async {
    await widget.onActionSelected(
      message,
      action,
    );

    if (!mounted) {
      return;
    }

    if (action.type == MessageActionType.pin ||
        action.type == MessageActionType.delete) {
      setState(
        () => _messages.removeWhere(
          (item) => item.id == message.id,
        ),
      );
    }
  }

  void _toggleSearch() {
    if (!_searching) {
      setState(() => _searching = true);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _searchFocusNode.requestFocus();
        }
      });

      return;
    }

    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
      setState(() {});
      return;
    }

    _searchFocusNode.unfocus();

    setState(() => _searching = false);
  }

  Future<void> _unpinAll() async {
    if (_unpinning) {
      return;
    }

    setState(() => _unpinning = true);

    await widget.onUnpinAll();

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ChatLayoutMetrics.of(context);
    final media = MediaQuery.of(context);

    final messages = _visibleMessages;
    final count = _messages.length;

    final countLabel =
        '$count pinned ${count == 1 ? 'message' : 'messages'}';

    final bottomSafeInset = media.viewPadding.bottom;

    // Same physical header placement model as ChatHeader:
    //
    // SafeArea top + ChatLayoutMetrics.headerHeight.
    //
    // The message list itself still fills the entire viewport. This value is
    // only the INITIAL top resting space. Once the list scrolls, messages move
    // behind the header instead of being clipped below it.
    final headerExtent =
        media.viewPadding.top +
        metrics.headerHeight;

    return Scaffold(
      backgroundColor: WrytteColors.background,

      // Full-screen pinned view.
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ===================================================================
          // FULL-SCREEN PINNED MESSAGE TIMELINE
          // ===================================================================
          //
          // This is deliberately behind the header. Top padding merely places
          // the first message below the header at rest; scrolling is free to
          // carry messages underneath the glass/blur layer.
          if (messages.isEmpty)
            Padding(
              padding: EdgeInsets.only(
                top: headerExtent,
                bottom: 76 + bottomSafeInset,
              ),
              child: Center(
                child: Text(
                  _searching
                      ? 'No pinned messages found'
                      : 'Pinned messages are unavailable',
                  style: const TextStyle(
                    color: Color(0xFF777A82),
                    fontSize: 14,
                  ),
                ),
              ),
            )
          else
            ListView.separated(
              padding: EdgeInsets.fromLTRB(
                12,
                headerExtent + 18,
                12,
                92 + bottomSafeInset,
              ),
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              itemCount: messages.length,
              separatorBuilder: (_, index) => SizedBox(
                height:
                    messages[index].isMine !=
                        messages[index + 1].isMine
                    ? 10
                    : 4,
              ),
              itemBuilder: (context, index) {
                final message = messages[index];

                final showDate =
                    index == 0 ||
                    messages[index - 1].dayLabel !=
                        message.dayLabel;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showDate)
                      _DateChip(
                        message.dayLabel,
                      ),

                    ChatMessageBubble(
                      key: ValueKey(
                        'pinned-message-${message.id}',
                      ),
                      message: message,
                      isPinned: true,
                      showTail: true,
                      actions: _actions,
                      audioPlayback:
                          widget.audioPlayback,
                      videoPlayback:
                          widget.videoPlayback,
                      onBeforeVideoPlay:
                          widget.onBeforeVideoPlay,
                      onActionSelected:
                          _handleAction,
                      onReactionSelected:
                          widget.onReactionSelected,
                    ),
                  ],
                );
              },
            ),

          // ===================================================================
          // DARK BLURRED HEADER BACKDROP
          // ===================================================================
          //
          // Messages remain visible as they pass underneath, but they are
          // softened with backdrop blur and a dark overlay exactly where the
          // controls live.
          PositionedDirectional(
            top: 0,
            start: 0,
            end: 0,
            child: _PinnedMessagesHeaderBackdrop(
              child: _PinnedMessagesHeader(
                countLabel: countLabel,
                searching: _searching,
                searchController:
                    _searchController,
                searchFocusNode:
                    _searchFocusNode,
                onBack: () =>
                    Navigator.of(context).pop(),
                onSearchPressed:
                    _toggleSearch,
                onSearchChanged: (_) {
                  setState(() {});
                },
              ),
            ),
          ),

          // ===================================================================
          // UNPIN ALL
          // ===================================================================
          //
          // Container geometry stays exactly the same as before.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,

              // Keep the same visual 12dp breathing room above the system
              // navigation area instead of positioning the button at a hard
              // screen coordinate.
              maintainBottomViewPadding: true,
              minimum: const EdgeInsets.only(
                bottom: 12,
              ),
              child: Center(
                child: WrytteGlassSurface(
                  borderRadius:
                      BorderRadius.circular(22),
                  blur: 10,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius:
                          BorderRadius.circular(22),
                      onTap:
                          _unpinning ||
                              _messages.isEmpty
                          ? null
                          : _unpinAll,
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                        child: _unpinning
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: WrytteColors
                                          .textPrimary,
                                    ),
                              )
                            : const Text(
                                'Unpin all messages',
                                style: TextStyle(
                                  color: WrytteColors
                                      .textPrimary,
                                  fontSize: 15,
                                  height: 1,
                                  fontWeight:
                                      FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PINNED HEADER BACKDROP
// =============================================================================
//
// The main difference from the old pinned-message view is that the header does
// NOT own physical layout space.
//
// The message ListView fills the entire screen and paints behind this widget.
// BackdropFilter therefore receives the real message pixels underneath it.
//
// ShaderMask softly fades the backdrop treatment out below the controls so the
// header does not end in a harsh horizontal blur cutoff.

class _PinnedMessagesHeaderBackdrop extends StatelessWidget {
  const _PinnedMessagesHeaderBackdrop({
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final metrics = ChatLayoutMetrics.of(context);
    final safeTop =
        MediaQuery.viewPaddingOf(context).top;

    final headerBottom =
        safeTop + metrics.headerHeight;

    // Extra fade region beneath the actual pill controls.
    final overlayHeight =
        headerBottom + (18 * metrics.scale);

    return SizedBox(
      height: overlayHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) {
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [
                      0,
                      .58,
                      .76,
                      .90,
                      1,
                    ],
                    colors: [
                      Colors.white,
                      Colors.white,
                      Color(0xE6FFFFFF),
                      Color(0x66FFFFFF),
                      Colors.transparent,
                    ],
                  ).createShader(bounds);
                },
                child: ClipRect(
                  child: BackdropFilter(
                    filter:
                        ui.ImageFilter.blur(
                          sigmaX: 16,
                          sigmaY: 16,
                        ),
                    child: ColoredBox(
                      color: WrytteColors
                          .background
                          .withValues(
                            alpha: .70,
                          ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          Align(
            alignment: Alignment.topCenter,
            child: child,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PINNED HEADER
// =============================================================================
//
// Uses the same geometry language as ChatHeader:
// - SafeArea
// - ChatLayoutMetrics
// - circular WrytteGlassIconButton controls
// - center glass pill
// - attachment-style rounded X close control
//
// Search reuses the center pill rather than introducing another toolbar.

class _PinnedMessagesHeader extends StatelessWidget {
  const _PinnedMessagesHeader({
    required this.countLabel,
    required this.searching,
    required this.searchController,
    required this.searchFocusNode,
    required this.onBack,
    required this.onSearchPressed,
    required this.onSearchChanged,
  });

  final String countLabel;
  final bool searching;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final VoidCallback onBack;
  final VoidCallback onSearchPressed;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    final metrics = ChatLayoutMetrics.of(context);

    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: metrics.headerHeight,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal:
                metrics.horizontalPadding,
          ),
          child: Row(
            children: [
              // ---------------------------------------------------------------
              // Back
              // ---------------------------------------------------------------
              WrytteGlassIconButton(
                semanticLabel:
                    'Close pinned messages',
                onPressed: onBack,
                size: metrics.controlSize,

                // Same rounded X visual used by the attachment/forwarding
                // surfaces. Button size and icon size stay unchanged.
                child: Icon(
                  Icons.close_rounded,
                  size: 26 * metrics.scale,
                  color:
                      WrytteColors.textPrimary,
                ),
              ),

              SizedBox(
                width: metrics.controlGap,
              ),

              // ---------------------------------------------------------------
              // Title / Search pill
              // ---------------------------------------------------------------
              Expanded(
                child: SizedBox(
                  height: metrics.controlSize,
                  child: WrytteGlassSurface(
                    borderRadius:
                        BorderRadius.circular(
                          metrics.controlSize / 2,
                        ),
                    blur: 10,
                    child: AnimatedSwitcher(
                      duration:
                          const Duration(
                            milliseconds: 180,
                          ),
                      switchInCurve:
                          Curves.easeOutCubic,
                      switchOutCurve:
                          Curves.easeInCubic,
                      transitionBuilder:
                          (child, animation) {
                            return FadeTransition(
                              opacity: animation,
                              child:
                                  SlideTransition(
                                    position:
                                        Tween<Offset>(
                                          begin:
                                              const Offset(
                                                .03,
                                                0,
                                              ),
                                          end:
                                              Offset.zero,
                                        ).animate(
                                          animation,
                                        ),
                                    child: child,
                                  ),
                            );
                          },
                      child: searching
                          ? Padding(
                              key:
                                  const ValueKey(
                                    'pin-search',
                                  ),
                              padding:
                                  EdgeInsets.symmetric(
                                    horizontal:
                                        16 *
                                        metrics.scale,
                                  ),
                              child: Center(
                                child: TextField(
                                  controller:
                                      searchController,
                                  focusNode:
                                      searchFocusNode,
                                  onChanged:
                                      onSearchChanged,
                                  maxLines: 1,
                                  style: TextStyle(
                                    color:
                                        WrytteColors
                                            .textPrimary,
                                    fontSize:
                                        14 *
                                        metrics.scale,
                                    height: 1,
                                  ),
                                  decoration:
                                      InputDecoration(
                                        isDense: true,
                                        border:
                                            InputBorder
                                                .none,
                                        hintText:
                                            'Search pinned messages',
                                        hintStyle:
                                            TextStyle(
                                              color:
                                                  const Color(
                                                    0xFF777A82,
                                                  ),
                                              fontSize:
                                                  14 *
                                                  metrics.scale,
                                              height: 1,
                                            ),
                                      ),
                                ),
                              ),
                            )
                          : MediaQuery
                                .withClampedTextScaling(
                                  key:
                                      const ValueKey(
                                        'pin-title',
                                      ),
                                  maxScaleFactor:
                                      1.3,
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment
                                            .center,
                                    children: [
                                      Text(
                                        'Pin',
                                        maxLines: 1,
                                        overflow:
                                            TextOverflow
                                                .ellipsis,
                                        style:
                                            TextStyle(
                                              color:
                                                  WrytteColors
                                                      .textPrimary,
                                              fontSize:
                                                  17 *
                                                  metrics.scale,
                                              height: 1,
                                              fontWeight:
                                                  FontWeight
                                                      .w700,
                                            ),
                                      ),

                                      SizedBox(
                                        height:
                                            3 *
                                            metrics.scale,
                                      ),

                                      Text(
                                        countLabel,
                                        maxLines: 1,
                                        overflow:
                                            TextOverflow
                                                .ellipsis,
                                        style:
                                            TextStyle(
                                              color:
                                                  WrytteColors
                                                      .textMuted,
                                              fontSize:
                                                  12 *
                                                  metrics.scale,
                                              height: 1,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                    ),
                  ),
                ),
              ),

              SizedBox(
                width: metrics.controlGap,
              ),

              // ---------------------------------------------------------------
              // Search
              // ---------------------------------------------------------------
              WrytteGlassIconButton(
                semanticLabel:
                    searching
                    ? 'Close pinned message search'
                    : 'Search pinned messages',
                onPressed: onSearchPressed,
                size: metrics.controlSize,
                child: WrytteSvgIcon(
                  asset:
                      'assets/svg/Search icon.svg',
                  size: 24 * metrics.scale,
                  color:
                      WrytteColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// DATE CHIP
// =============================================================================

class _DateChip extends StatelessWidget {
  const _DateChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.only(
            bottom: 10,
          ),
      child: WrytteGlassSurface(
        borderRadius:
            BorderRadius.circular(12),
        blur: 10,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 5,
              ),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFFB4B5B9),
              fontSize: 11,
              fontWeight:
                  FontWeight.w600,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
