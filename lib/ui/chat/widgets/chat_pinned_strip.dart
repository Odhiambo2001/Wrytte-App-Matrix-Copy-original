import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatPinnedStrip extends StatefulWidget {
  const ChatPinnedStrip({
    super.key,
    required this.messages,
    required this.onMessageSelected,
    required this.onOpenList,
    required this.onDismiss,
  });

  /// The exact vertical space ChatView reserves while this strip is visible.
  ///
  /// 3 top + 50 surface + 3 bottom = 56dp.
  static const double extent = 56;

  final List<ChatMessagePresentation> messages;

  /// Called from BODY taps only.
  ///
  /// This never opens the pinned-message screen. ChatView uses it to scroll to
  /// the chosen pinned message and briefly highlight that message row.
  final ValueChanged<ChatMessagePresentation> onMessageSelected;

  /// Reserved for the explicit menu icon when multiple messages are pinned.
  final VoidCallback onOpenList;

  final VoidCallback onDismiss;

  @override
  State<ChatPinnedStrip> createState() => _ChatPinnedStripState();
}

class _ChatPinnedStripState extends State<ChatPinnedStrip> {
  static const double _surfaceHeight = 50;
  static const double _surfaceRadius = 25;

  // Slightly shorter than before so the white rail has a little more breathing
  // room above and below while the container height itself remains unchanged.
  static const double _markerHeight = 29;
  static const double _markerWidth = 3;

  int _selectedIndex = 0;

  @override
  void didUpdateWidget(covariant ChatPinnedStrip oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.messages.isEmpty) {
      _selectedIndex = 0;
      return;
    }

    final previousId = oldWidget.messages.isEmpty
        ? null
        : oldWidget
              .messages[
                _selectedIndex.clamp(
                  0,
                  oldWidget.messages.length - 1,
                )
              ]
              .id;

    final retained = previousId == null
        ? -1
        : widget.messages.indexWhere(
            (message) => message.id == previousId,
          );

    _selectedIndex = retained < 0 ? 0 : retained;
  }

  ChatMessagePresentation get _selected =>
      widget.messages[_selectedIndex];

  String _preview(ChatMessagePresentation message) {
    final text = message.text
        ?.trim()
        .replaceAll(
          RegExp(r'\s+'),
          ' ',
        );

    if (text?.isNotEmpty == true) {
      return text!;
    }

    final file = message.fileName?.trim();

    if (file?.isNotEmpty == true) {
      return file!;
    }

    return switch (message.kind) {
      ChatMessageKind.image => 'Photo',
      ChatMessageKind.video =>
        message.isVideoNote ? 'Video message' : 'Video',
      ChatMessageKind.audio => 'Voice message',
      ChatMessageKind.file => 'File',
      ChatMessageKind.contact =>
        message.contactName ?? 'Contact',
      ChatMessageKind.text => 'Message',
    };
  }

  void _handleBodyTap() {
    if (widget.messages.isEmpty) {
      return;
    }

    if (widget.messages.length > 1) {
      setState(() {
        _selectedIndex =
            (_selectedIndex + 1) %
            widget.messages.length;
      });
    }

    widget.onMessageSelected(_selected);
  }

  Widget _markerRail() {
    final count = widget.messages.length;

    final gap = count <= 6
        ? 2.0
        : count <= 12
        ? 1.0
        : _markerHeight / (count * 3);

    final segmentHeight =
        (_markerHeight - (gap * (count - 1))) /
        count;

    return SizedBox(
      width: _markerWidth,
      height: _markerHeight,
      child: Column(
        children: List.generate(
          count,
          (index) => Padding(
            padding: EdgeInsets.only(
              bottom:
                  index == count - 1
                  ? 0
                  : gap,
            ),
            child: AnimatedContainer(
              duration:
                  const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              width: _markerWidth,
              height: segmentHeight,
              decoration: BoxDecoration(
                color:
                    const Color(0xFFF2F2F2)
                        .withValues(
                          alpha:
                              index == _selectedIndex
                              ? 1
                              : .48,
                        ),
                borderRadius:
                    BorderRadius.circular(
                      _markerWidth,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _singleMarker() {
    return Container(
      width: _markerWidth,
      height: _markerHeight,
      decoration: BoxDecoration(
        color: WrytteColors.textPrimary,
        borderRadius:
            BorderRadius.circular(
              _markerWidth,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return const SizedBox.shrink();
    }

    if (_selectedIndex >=
        widget.messages.length) {
      _selectedIndex = 0;
    }

    final multiple =
        widget.messages.length > 1;

    return SizedBox(
      height: ChatPinnedStrip.extent,
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(
              9,
              3,
              9,
              3,
            ),
        child: WrytteGlassSurface(
          borderRadius:
              BorderRadius.circular(
                _surfaceRadius,
              ),
          blur: 10,
          child: Material(
            color: Colors.transparent,
            borderRadius:
                BorderRadius.circular(
                  _surfaceRadius,
                ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius:
                  BorderRadius.circular(
                    _surfaceRadius,
                  ),
              onTap: _handleBodyTap,
              splashFactory:
                  NoSplash.splashFactory,
              overlayColor:
                  const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
              child: SizedBox(
                height: _surfaceHeight,
                child: Padding(
                  padding:
                      const EdgeInsetsDirectional.only(
                        start: 14,
                        end: 6,
                      ),
                  child: Row(
                    children: [
                      multiple
                          ? _markerRail()
                          : _singleMarker(),

                      const SizedBox(width: 10),

                      Expanded(
                        child: AnimatedSwitcher(
                          duration:
                              const Duration(
                                milliseconds: 175,
                              ),
                          reverseDuration:
                              const Duration(
                                milliseconds: 145,
                              ),
                          switchInCurve:
                              Curves.easeOutCubic,
                          switchOutCurve:
                              Curves.easeInCubic,

                          // AnimatedSwitcher's default layout centers its
                          // transitioning child. That is why the first
                          // screenshot could show "Pinned message" in the
                          // middle even though _PinnedStripText itself used
                          // CrossAxisAlignment.start.
                          //
                          // Force every old/current child to the leading edge.
                          layoutBuilder: (
                            currentChild,
                            previousChildren,
                          ) {
                            return Stack(
                              alignment:
                                  AlignmentDirectional
                                      .centerStart,
                              children: [
                                ...previousChildren,
                                if (currentChild !=
                                    null)
                                  currentChild,
                              ],
                            );
                          },

                          transitionBuilder:
                              (child, animation) {
                                return FadeTransition(
                                  opacity:
                                      animation,
                                  child:
                                      SlideTransition(
                                        position:
                                            Tween<Offset>(
                                              begin:
                                                  const Offset(
                                                    .025,
                                                    0,
                                                  ),
                                              end:
                                                  Offset
                                                      .zero,
                                            ).animate(
                                              animation,
                                            ),
                                        child:
                                            child,
                                      ),
                                );
                              },

                          // Full available width is important. It removes any
                          // intrinsic-width centering during AnimatedSwitcher
                          // transitions and guarantees left alignment.
                          child: SizedBox(
                            key: ValueKey<String>(
                              _selected.id,
                            ),
                            width:
                                double.infinity,
                            child:
                                _PinnedStripText(
                                  title: multiple
                                      ? 'Pinned messages'
                                      : 'Pinned message',
                                  preview:
                                      _preview(
                                        _selected,
                                      ),
                                ),
                          ),
                        ),
                      ),

                      const SizedBox(width: 3),

                      InkResponse(
                        radius: 18,
                        onTap: multiple
                            ? widget.onOpenList
                            : widget.onDismiss,
                        splashFactory:
                            NoSplash
                                .splashFactory,
                        overlayColor:
                            const WidgetStatePropertyAll(
                              Colors.transparent,
                            ),
                        child:
                            SizedBox.square(
                              dimension: 34,
                              child: Icon(
                                multiple
                                    ? Icons
                                          .menu_rounded
                                    : Icons
                                          .close_rounded,
                                size:
                                    multiple
                                    ? 18
                                    : 21,
                                color:
                                    WrytteColors
                                        .textPrimary,
                              ),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinnedStripText extends StatelessWidget {
  const _PinnedStripText({
    required this.title,
    required this.preview,
  });

  final String title;
  final String preview;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment:
          MainAxisAlignment.center,
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow:
              TextOverflow.ellipsis,
          textAlign: TextAlign.start,
          style: const TextStyle(
            color:
                WrytteColors.textPrimary,
            fontSize: 13,
            height: 1.08,
            fontWeight:
                FontWeight.w600,
          ),
        ),

        const SizedBox(height: 3),

        Text(
          preview,
          maxLines: 1,
          overflow:
              TextOverflow.ellipsis,
          textAlign: TextAlign.start,
          style: const TextStyle(
            color: Color(0xFF9B9DA3),
            fontSize: 13,
            height: 1.08,
          ),
        ),
      ],
    );
  }
}
