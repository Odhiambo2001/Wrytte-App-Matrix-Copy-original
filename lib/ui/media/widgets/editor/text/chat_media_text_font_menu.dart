import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_session.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaTextFontButton
    extends StatefulWidget {
  const ChatMediaTextFontButton({
    super.key,
    required this.editor,
    required this.session,
  });

  final TextEditorState editor;
  final ChatMediaTextSession session;

  @override
  State<ChatMediaTextFontButton>
  createState() =>
      _ChatMediaTextFontButtonState();
}

class _ChatMediaTextFontButtonState
    extends State<ChatMediaTextFontButton> {
  final LayerLink _link =
      LayerLink();

  OverlayEntry? _entry;

  void _toggle() {
    if (_entry != null) {
      _close();
      return;
    }

    _open();
  }

  void _open() {
    widget.session.closeEmoji(
      widget.editor,
    );

    final overlay =
        Overlay.of(
      context,
      rootOverlay: true,
    );

    late final OverlayEntry entry;

    entry =
        OverlayEntry(
      builder: (
        overlayContext,
      ) {
        final media =
            MediaQuery.of(
          overlayContext,
        );

        final usableHeight =
            media.size.height -
            media.viewInsets.bottom -
            media.viewPadding.top -
            120;

        final menuHeight =
            usableHeight
                .clamp(
                  190.0,
                  330.0,
                )
                .toDouble();

        return Stack(
          children: [
            Positioned.fill(
              child:
                  GestureDetector(
                behavior:
                    HitTestBehavior
                        .translucent,

                onTap:
                    _close,

                child:
                    const SizedBox
                        .expand(),
              ),
            ),

            CompositedTransformFollower(
              link:
                  _link,

              showWhenUnlinked:
                  false,

              targetAnchor:
                  Alignment.topCenter,

              followerAnchor:
                  Alignment.bottomCenter,

              offset:
                  const Offset(
                0,
                -10,
              ),

              child:
                  SizedBox(
                width:
                    226,

                height:
                    menuHeight,

                child:
                    WrytteGlassSurface(
                  borderRadius:
                      BorderRadius.circular(
                    26,
                  ),

                  blur:
                      22,

                  child:
                      Material(
                    type:
                        MaterialType
                            .transparency,

                    child:
                        ListView.builder(
                      padding:
                          const EdgeInsets.symmetric(
                        vertical:
                            7,
                      ),

                      itemCount:
                          ChatMediaTextSession
                              .fontNames
                              .length,

                      itemBuilder: (
                        context,
                        index,
                      ) {
                        final selected =
                            widget
                                    .session
                                    .fontIndex ==
                                index;

                        final preset =
                            ChatMediaTextSession
                                    .fontPresets[
                                index];

                        return InkWell(
                          onTap:
                              () {
                            widget.session
                                .selectFont(
                              widget.editor,
                              index,
                            );

                            _close();
                          },

                          splashFactory:
                              NoSplash
                                  .splashFactory,

                          child:
                              SizedBox(
                            height:
                                44,

                            child:
                                Padding(
                              padding:
                                  const EdgeInsets.symmetric(
                                horizontal:
                                    17,
                              ),

                              child:
                                  Row(
                                children: [
                                  Expanded(
                                    child:
                                        Text(
                                      ChatMediaTextSession
                                              .fontNames[
                                          index],

                                      overflow:
                                          TextOverflow
                                              .ellipsis,

                                      style:
                                          preset.copyWith(
                                        color:
                                            selected
                                            ? WrytteColors
                                                .primary
                                            : WrytteColors
                                                .textPrimary,

                                        fontSize:
                                            16,
                                      ),
                                    ),
                                  ),

                                  if (selected)
                                    const Icon(
                                      Icons
                                          .check_rounded,

                                      size:
                                          18,

                                      color:
                                          WrytteColors
                                              .primary,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    _entry =
        entry;

    overlay.insert(
      entry,
    );
  }

  void _close() {
    final entry =
        _entry;

    _entry = null;

    if (entry != null &&
        entry.mounted) {
      entry.remove();
    }
  }

  @override
  void dispose() {
    _close();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Expanded(
      child:
          CompositedTransformTarget(
        link:
            _link,

        child:
            InkResponse(
          onTap:
              _toggle,

          containedInkWell:
              true,

          highlightShape:
              BoxShape.circle,

          radius:
              24,

          splashColor:
              Colors.transparent,

          child:
              const Center(
            child:
                WrytteSvgIcon(
              asset:
                  'assets/svg/Fonts type icon.svg',

              size:
                  26,

              color:
                  WrytteColors
                      .textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}