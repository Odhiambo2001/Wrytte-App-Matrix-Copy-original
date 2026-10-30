import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

// Pro Image Editor ships a modified copy of emoji_picker_flutter internally.
// Import its public barrel instead of adding a second external emoji package.
import 'package:pro_image_editor/plugins/emoji_picker_flutter/emoji_picker_flutter.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_session.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaTextEmojiPanel
    extends StatelessWidget {
  const ChatMediaTextEmojiPanel({
    super.key,
    required this.editor,
    required this.session,
    required this.height,
  });

  final TextEditorState editor;
  final ChatMediaTextSession session;

  final double height;

  @override
  Widget build(
    BuildContext context,
  ) {
    return WrytteGlassSurface(
      borderRadius:
          const BorderRadius.vertical(
        top: Radius.circular(
          30,
        ),
      ),

      blur: 26,

      child: SizedBox(
        height:
            height,

        child: Column(
          children: [
            // ==========================================================
            // DRAG-HANDLE STYLE INDICATOR
            // ==========================================================

            const SizedBox(
              height: 9,
            ),

            Container(
              width: 36,
              height: 4,
              decoration:
                  BoxDecoration(
                color:
                    Colors.white
                        .withValues(
                  alpha: .75,
                ),
                borderRadius:
                    BorderRadius.circular(
                  4,
                ),
              ),
            ),

            const SizedBox(
              height: 4,
            ),

            // ==========================================================
            // KEYBOARD RETURN BUTTON
            // ==========================================================

            SizedBox(
              height: 42,
              child: Align(
                alignment:
                    AlignmentDirectional
                        .centerEnd,
                child: Padding(
                  padding:
                      const EdgeInsetsDirectional
                          .only(
                    end: 8,
                  ),

                  child: IconButton(
                    tooltip:
                        'Show keyboard',

                    visualDensity:
                        VisualDensity.compact,

                    onPressed: () {
                      session.closeEmoji(
                        editor,
                        restoreKeyboard:
                            true,
                      );
                    },

                    icon:
                        const Icon(
                      Icons
                          .keyboard_hide_rounded,

                      size: 22,

                      color:
                          WrytteColors
                              .textSecondary,
                    ),
                  ),
                ),
              ),
            ),

            // ==========================================================
            // PRO IMAGE EDITOR'S BUNDLED EMOJI PICKER
            // ==========================================================

            Expanded(
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(
                  bottom:
                      Radius.circular(
                    30,
                  ),
                ),

                child: EmojiPicker(
                  textEditingController:
                      editor.textCtrl,

                    config: Config(
                    // The parent Expanded owns the actual final size.
                    //
                    // Give the picker the remaining intended height so its
                    // internal category/search calculations also remain sane.
                    height:
                        (height - 55)
                            .clamp(
                              180.0,
                              300.0,
                            )
                            .toDouble(),

                    checkPlatformCompatibility:
                        true,

                    emojiViewConfig:
                        const EmojiViewConfig(
                      columns: 8,

                      emojiSizeMax: 30,

                      backgroundColor:
                          Colors.transparent,

                      gridPadding:
                          EdgeInsets.symmetric(
                        horizontal: 5,
                      ),
                    ),

                    categoryViewConfig:
                        const CategoryViewConfig(
                      backgroundColor:
                          Colors.transparent,

                      indicatorColor:
                          WrytteColors.primary,

                      iconColor:
                          WrytteColors.textMuted,

                      iconColorSelected:
                          WrytteColors.textPrimary,
                    ),

                    bottomActionBarConfig:
                        const BottomActionBarConfig(
                      backgroundColor:
                          Colors.transparent,

                      buttonIconColor:
                          WrytteColors.textPrimary,
                    ),

                    searchViewConfig:
                        const SearchViewConfig(
                      backgroundColor:
                          WrytteColors.surface,

                      // NOTE:
                      //
                      // Pro Image Editor's bundled emoji picker does NOT
                      // expose SearchViewConfig.buttonColor anymore.
                      //
                      // It was removed upstream because the option had no
                      // effect.

                      buttonIconColor:
                          WrytteColors.textPrimary,

                      inputTextStyle:
                          TextStyle(
                        color:
                            WrytteColors.textPrimary,

                        fontFamily:
                            WrytteTypography
                                .primaryFontFamily,

                        fontSize: 15,
                      ),

                      hintTextStyle:
                          TextStyle(
                        color:
                            WrytteColors.textMuted,

                        fontFamily:
                            WrytteTypography
                                .primaryFontFamily,

                        fontSize: 15,
                      ),
                    ),
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
