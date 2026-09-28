import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_bottom_bar.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_color_picker.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_emoji_panel.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_session.dart';

class ChatMediaTextChrome extends StatelessWidget {
  const ChatMediaTextChrome({
    super.key,
    required this.editor,
    required this.session,
  });

  final TextEditorState editor;
  final ChatMediaTextSession session;

  @override
  Widget build(
    BuildContext context,
  ) {
    return LayoutBuilder(
      builder: (
        context,
        constraints,
      ) {
        final availableHeight =
            constraints.maxHeight;

        final topSafe =
            MediaQuery.viewPaddingOf(
          context,
        ).top;

        // --------------------------------------------------------------
        // EMOJI PANEL HEIGHT
        // --------------------------------------------------------------
        //
        // Keep the Telegram-like panel large on normal portrait phones,
        // but allow it to contract when the available text-editor viewport
        // becomes smaller.

        final emojiHeight = math
            .min(
              342.0,
              availableHeight * .43,
            )
            .clamp(
              250.0,
              342.0,
            )
            .toDouble();

        // --------------------------------------------------------------
        // COLOR PICKER
        // --------------------------------------------------------------

        final pickerTop =
            topSafe + 76;

        final availablePickerHeight =
            availableHeight -
            pickerTop -
            88;

        final pickerHeight = math
            .min(
              174.0,
              availablePickerHeight,
            )
            .clamp(
              100.0,
              174.0,
            )
            .toDouble();

        return AnimatedBuilder(
          animation: session,
          builder: (
            context,
            child,
          ) {
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // ======================================================
                // COLOR RAIL
                // ======================================================
                //
                // On very short layouts we prefer usable text space over
                // forcing every editor control onto the screen.

                if (availablePickerHeight >= 100)
                  PositionedDirectional(
                    top: pickerTop,
                    end: 7,
                    child:
                        ChatMediaTextColorPicker(
                      height:
                          pickerHeight,
                      onColorChanged: (
                        color,
                      ) {
                        session.setColor(
                          editor,
                          color,
                        );
                      },
                    ),
                  ),

                // ======================================================
                // TEXT BOTTOM TOOLBAR
                // ======================================================
                //
                // IMPORTANT:
                //
                // We do NOT add MediaQuery.viewInsets.bottom here.
                //
                // TextEditorConfigs.resizeToAvoidBottomInset is enabled.
                // Therefore this entire Text editor body has already been
                // resized ABOVE the system keyboard.
                //
                // bottom: 0 is now exactly where it should be.

                AnimatedPositioned(
                  duration:
                      const Duration(
                    milliseconds: 220,
                  ),
                  curve:
                      Curves.easeOutCubic,

                  left: 0,
                  right: 0,

                  bottom:
                      session.emojiVisible
                      ? emojiHeight
                      : 0,

                  child:
                      ChatMediaTextBottomBar(
                    editor:
                        editor,
                    session:
                        session,
                  ),
                ),

                // ======================================================
                // CUSTOM EMOJI PANEL
                // ======================================================

                AnimatedPositioned(
                  duration:
                      const Duration(
                    milliseconds: 220,
                  ),
                  curve:
                      Curves.easeOutCubic,

                  left: 0,
                  right: 0,

                  bottom:
                      session.emojiVisible
                      ? 0
                      : -emojiHeight,

                  height:
                      emojiHeight,

                  child:
                      IgnorePointer(
                    ignoring:
                        !session
                            .emojiVisible,

                    child:
                        AnimatedOpacity(
                      duration:
                          const Duration(
                        milliseconds: 160,
                      ),

                      opacity:
                          session
                                  .emojiVisible
                              ? 1
                              : 0,

                      child:
                          ChatMediaTextEmojiPanel(
                        editor:
                            editor,
                        session:
                            session,
                        height:
                            emojiHeight,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}