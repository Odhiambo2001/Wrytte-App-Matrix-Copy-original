import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class ChatAttachmentSendBar extends StatefulWidget {
  const ChatAttachmentSendBar({
    super.key,
    required this.count,
    required this.onSend,
    this.captionController,
  });

  /// Still useful for accessibility and enabling Send.
  ///
  /// It is intentionally NOT displayed inside the composer because the
  /// selected count now belongs in the attachment header.
  final int count;

  final TextEditingController? captionController;
  final VoidCallback onSend;

  @override
  State<ChatAttachmentSendBar> createState() =>
      _ChatAttachmentSendBarState();
}

class _ChatAttachmentSendBarState
    extends State<ChatAttachmentSendBar> {
  final FocusNode _captionFocusNode =
      FocusNode();

  bool _pressed = false;

  @override
  void dispose() {
    _captionFocusNode.dispose();

    super.dispose();
  }

  void _send() {
    if (widget.count <= 0) {
      return;
    }

    unawaited(
      HapticFeedback.lightImpact(),
    );

    _captionFocusNode.unfocus();

    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final media =
        MediaQuery.of(context);

    final keyboardInset =
        media.viewInsets.bottom;

    final widthProgress =
        ((media.size.shortestSide - 320) / 152)
            .clamp(
              0.0,
              1.0,
            )
            .toDouble();

    final scale =
        .90 +
        (.10 * widthProgress);

    final controlSize =
        52 +
        (2 * widthProgress);

    final horizontalInset =
        14 +
        (2 * widthProgress);

    final fontSize =
        16 +
        widthProgress;

    final hasCaption =
        widget.captionController != null;

    return AnimatedPadding(
      duration:
          media.disableAnimations
          ? Duration.zero
          : const Duration(
              milliseconds: 220,
            ),

      curve:
          Curves.easeOutCubic,

      padding:
          EdgeInsets.only(
        bottom:
            keyboardInset,
      ),

      child: SafeArea(
        top: false,
        left: false,
        right: false,

        maintainBottomViewPadding:
            true,

        minimum:
            EdgeInsets.only(
          bottom:
              10 * scale,
        ),

        child: Padding(
          padding:
              EdgeInsets.fromLTRB(
            horizontalInset,
            8 * scale,
            horizontalInset,
            0,
          ),

          child: Row(
            children: [
              // ============================================================
              // CAPTION
              // ============================================================

              if (hasCaption)
                Expanded(
                  child:
                      ClipRRect(
                    borderRadius:
                        BorderRadius.circular(
                      controlSize / 2,
                    ),

                    child:
                        BackdropFilter(
                      filter:
                          ImageFilter.blur(
                        sigmaX: 30,
                        sigmaY: 30,
                      ),

                      child:
                          DecoratedBox(
                        decoration:
                            BoxDecoration(
                          gradient:
                              const LinearGradient(
                            begin:
                                Alignment
                                    .topCenter,

                            end:
                                Alignment
                                    .bottomCenter,

                            stops: [
                              0,
                              .48,
                              1,
                            ],

                            colors: [
                              Color.fromRGBO(
                                30,
                                33,
                                41,
                                .62,
                              ),

                              Color.fromRGBO(
                                17,
                                20,
                                27,
                                .52,
                              ),

                              Color.fromRGBO(
                                8,
                                10,
                                15,
                                .46,
                              ),
                            ],
                          ),

                          borderRadius:
                              BorderRadius.circular(
                            controlSize / 2,
                          ),

                          border:
                              Border.all(
                            color:
                                Colors.white
                                    .withValues(
                              alpha: .11,
                            ),

                            width: .8,
                          ),

                          boxShadow: [
                            BoxShadow(
                              color:
                                  Colors.black
                                      .withValues(
                                alpha: .34,
                              ),

                              blurRadius: 18,

                              offset:
                                  const Offset(
                                0,
                                6,
                              ),
                            ),

                            BoxShadow(
                              color:
                                  Colors.white
                                      .withValues(
                                alpha: .035,
                              ),

                              blurRadius: 1,

                              offset:
                                  const Offset(
                                0,
                                1,
                              ),
                            ),
                          ],
                        ),

                        child:
                            SizedBox(
                          height:
                              controlSize,

                          child:
                              TextField(
                            controller:
                                widget
                                    .captionController,

                            focusNode:
                                _captionFocusNode,

                            expands:
                                true,

                            minLines:
                                null,

                            maxLines:
                                null,

                            textInputAction:
                                TextInputAction
                                    .done,

                            textAlignVertical:
                                TextAlignVertical
                                    .center,

                            onSubmitted:
                                (_) {
                              _send();
                            },

                            cursorColor:
                                WrytteColors
                                    .primary,

                            cursorWidth:
                                1.5,

                            style:
                                TextStyle(
                              color:
                                  WrytteColors
                                      .textPrimary,

                              fontFamily:
                                  WrytteTypography
                                      .primaryFontFamily,

                              fontSize:
                                  fontSize,

                              height: 1,

                              fontWeight:
                                  FontWeight
                                      .w400,
                            ),

                            decoration:
                                InputDecoration(
                              isDense:
                                  true,

                              border:
                                  InputBorder
                                      .none,

                              enabledBorder:
                                  InputBorder
                                      .none,

                              focusedBorder:
                                  InputBorder
                                      .none,

                              hintText:
                                  'Add a caption...',

                              hintStyle:
                                  TextStyle(
                                color:
                                    WrytteColors
                                        .textSecondary
                                        .withValues(
                                  alpha: .72,
                                ),

                                fontFamily:
                                    WrytteTypography
                                        .primaryFontFamily,

                                fontSize:
                                    fontSize,

                                height: 1,

                                fontWeight:
                                    FontWeight
                                        .w400,
                              ),

                              contentPadding:
                                  EdgeInsets.symmetric(
                                horizontal:
                                    14 +
                                    (3 *
                                        widthProgress),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              if (hasCaption)
                SizedBox(
                  width:
                      9 * scale,
                ),

              if (!hasCaption)
                const Spacer(),

              // ============================================================
              // SEND
              // ============================================================
              //
              // EXACTLY as requested:
              //
              // NO SHADOW.
              //
              // Just the clean Wrytte blue circular control like the old
              // attachment composer.

              Semantics(
                button:
                    true,

                label:
                    widget.count == 1
                    ? 'Send selected item'
                    : 'Send ${widget.count} selected items',

                child:
                    GestureDetector(
                  behavior:
                      HitTestBehavior
                          .opaque,

                  onTapDown:
                      (_) {
                    if (!mounted) {
                      return;
                    }

                    setState(() {
                      _pressed =
                          true;
                    });
                  },

                  onTapCancel:
                      () {
                    if (!mounted) {
                      return;
                    }

                    setState(() {
                      _pressed =
                          false;
                    });
                  },

                  onTapUp:
                      (_) {
                    if (!mounted) {
                      return;
                    }

                    setState(() {
                      _pressed =
                          false;
                    });
                  },

                  onTap:
                      widget.count > 0
                      ? _send
                      : null,

                  child:
                      AnimatedScale(
                    scale:
                        _pressed
                        ? .94
                        : 1,

                    duration:
                        const Duration(
                      milliseconds:
                          110,
                    ),

                    curve:
                        Curves.easeOutCubic,

                    child:
                        AnimatedContainer(
                      duration:
                          const Duration(
                        milliseconds:
                            180,
                      ),

                      curve:
                          Curves.easeOutCubic,

                      width:
                          controlSize,

                      height:
                          controlSize,

                      alignment:
                          Alignment.center,

                      decoration:
                          BoxDecoration(
                        color:
                            WrytteColors
                                .primary
                                .withValues(
                          alpha:
                              widget.count > 0
                              ? 1
                              : .58,
                        ),

                        shape:
                            BoxShape.circle,

                        // Deliberately NO boxShadow.
                      ),

                      child:
                          Transform.translate(
                        offset:
                            const Offset(
                          -1.5,
                          0,
                        ),

                        child:
                            Transform.rotate(
                          angle:
                              math.pi /
                              4,

                          child:
                              Transform.scale(
                            scale:
                                1.12,

                            child:
                                WrytteSvgIcon(
                              asset:
                                  'assets/svg/Send icon .svg',

                              size:
                                  28 *
                                  scale,

                              color:
                                  Colors.white,
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
        ),
      ),
    );
  }
}