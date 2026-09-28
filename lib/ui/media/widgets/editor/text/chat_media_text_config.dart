import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_chrome.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_session.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_size_slider.dart';

TextEditorConfigs buildChatMediaTextEditorConfigs({
  required VoidCallback onDiscarded,
}) {
  final session = ChatMediaTextSession(onDiscarded: onDiscarded);

  return TextEditorConfigs(
    enableGesturePop: false,

    enableEdit: true,

    enableTapOutsideToSave: false,

    // ================================================================
    // KEYBOARD FIX
    // ================================================================
    //
    // This is intentionally TRUE.
    //
    // The old editor used false and then manually lifted only our toolbar.
    // That left PIE's actual text-input viewport full-height and allowed
    // parts of the editing container/text to sit underneath tall keyboards.
    //
    // Now PIE's Text editor body itself becomes:
    //
    // screen height - keyboard height
    //
    // so its internal text input and every Wrytte overlay share the same
    // usable viewport.
    resizeToAvoidBottomInset: true,

    safeArea: const EditorSafeArea.none(),

    initialPrimaryColor: Colors.black,

    initialSecondaryColor: Colors.white,

    initialBackgroundColorMode: LayerBackgroundMode.backgroundAndColor,

    initialTextAlign: TextAlign.center,

    // Slightly above dead-center feels better when typing and gives the
    // keyboard-facing side more breathing room.
    inputTextFieldAlign: const Alignment(0, -.10),

    layerFractionalOffset: const Offset(-.5, -.5),

    enableAutoOverflow: true,

    enableAutoWrapOnLayer: true,

    enableImageBoundaryTextWrap: true,

    initFontSize: 30,

    initFontScale: ChatMediaTextSession.defaultFontScale,

    minFontScale: ChatMediaTextSession.minFontScale,

    maxFontScale: ChatMediaTextSession.maxFontScale,

    showSelectFontStyleBottomBar: false,

    showTextAlignButton: false,

    showFontScaleButton: false,

    showBackgroundModeButton: false,

    customTextStyles: ChatMediaTextSession.fontPresets,

    defaultTextStyle: const TextStyle(
      color: Colors.black,

      fontFamily: WrytteTypography.primaryFontFamily,

      fontWeight: FontWeight.w400,
    ),

    style: const TextEditorStyle(
      background: Color(0x26000000),

      inputCursorColor: WrytteColors.primary,

      // We've removed PIE's actual AppBar/BottomBar, so don't retain its
      // default bottom navigation margin.
      textFieldMargin: EdgeInsets.zero,

      // Critical responsive padding.
      //
      // This sits OUTSIDE the text field's scroll area. When the keyboard
      // shrinks the Text editor, the input remains inside a usable region
      // instead of sliding under our floating bottom controls.
      textFieldPadding: EdgeInsets.fromLTRB(24, 68, 24, 86),

      inputTextFieldPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),

      textHeight: 0,
    ),

    widgets: TextEditorWidgets(
      appBar: (editor, rebuildStream) => null,

      bottomBar: (editor, rebuildStream) => null,

      colorPicker: (editor, rebuildStream, currentColor, setColor) => null,

      // ================================================================
      // MAIN TEXT CHROME
      // ================================================================
      bodyItems: (editor, rebuildStream) {
        session.attach(editor);

        return <ReactiveWidget<Widget>>[
          ReactiveWidget<Widget>(
            stream: rebuildStream,

            builder: (_) {
              return Positioned.fill(
                child: ChatMediaTextChrome(editor: editor, session: session),
              );
            },
          ),
        ];
      },

      // ================================================================
      // SIZE CONTROL ABOVE ALL TEXT CONTENT
      // ================================================================
      //
      // bodyItemsOverlay is the correct package slot here. PIE explicitly
      // provides it for widgets that must appear above every other Text-editor
      // body item.
      bodyItemsOverlay: (editor, rebuildStream) {
        session.attach(editor);

        return <ReactiveWidget<Widget>>[
          ReactiveWidget<Widget>(
            stream: rebuildStream,

            builder: (overlayContext) {
              return Positioned.fill(
                child: AnimatedBuilder(
                  animation: session,

                  builder: (context, child) {
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final height = constraints.maxHeight;

                        final top =
                            MediaQuery.viewPaddingOf(overlayContext).top + 64;

                        final emojiReserve = session.emojiVisible
                            ? math
                                  .min(342.0, height * .43)
                                  .clamp(250.0, 342.0)
                                  .toDouble()
                            : 0.0;

                        const bottomBarReserve = 78.0;

                        final available =
                            height - top - bottomBarReserve - emojiReserve;

                        // On very small landscape/keyboard combinations there
                        // genuinely isn't enough safe room for the size rail.
                        // Hide it instead of allowing it to overlap the text.
                        if (available < 130) {
                          return const SizedBox.shrink();
                        }

                        final sliderHeight = math
                            .min(315.0, available * .82)
                            .clamp(130.0, 315.0)
                            .toDouble();

                        final sliderTop =
                            top + ((available - sliderHeight) / 2);

                        return Stack(
                          children: [
                            PositionedDirectional(
                              start: 0,

                              top: sliderTop,

                              width: 58,

                              height: sliderHeight,

                              child: ChatMediaTextSizeSlider(
                                value: session.fontScale,

                                min: ChatMediaTextSession.minFontScale,

                                max: ChatMediaTextSession.maxFontScale,

                                height: sliderHeight,

                                onChanged: (value) {
                                  session.setFontScale(editor, value);
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              );
            },
          ),
        ];
      },
    ),
  );
}
