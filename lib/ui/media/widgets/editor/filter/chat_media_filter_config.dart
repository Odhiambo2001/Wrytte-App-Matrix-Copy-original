import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

import 'package:wrytte/ui/media/widgets/editor/filter/chat_media_filter_bottom_bar.dart';
import 'package:wrytte/ui/media/widgets/editor/filter/chat_media_filter_header.dart';
import 'package:wrytte/ui/media/widgets/editor/filter/chat_media_filter_preview.dart';
import 'package:wrytte/ui/media/widgets/editor/filter/chat_media_filter_session.dart';

FilterEditorConfigs buildChatMediaFilterEditorConfigs({
  required ValueChanged<bool> onApplied,
  required VoidCallback onDiscarded,
}) {
  final session = ChatMediaFilterSession();

  return FilterEditorConfigs(
    // A newly selected filter replaces the current one.
    enableMultiSelection: false,

    // Existing text/paint/emoji layers stay visible while judging a filter.
    showLayers: true,

    // Wrytte supplies an explicit X/Discard flow.
    enableGesturePop: false,

    // Full-screen filter canvas. We handle physical safe areas in our chrome.
    safeArea: const EditorSafeArea.none(),

    style: const FilterEditorStyle(background: WrytteColors.background),

    widgets: FilterEditorWidgets(
      // Package chrome would reduce the image viewport.
      appBar: (editor, rebuildStream) => null,

      bottomBar: (editor, rebuildStream) => null,

      bodyItems: (editor, rebuildStream) {
        session.attach(editor);

        return <ReactiveWidget<Widget>>[
          // ==============================================================
          // FULL-SCREEN LIVE PREVIEW
          // ==============================================================
          ReactiveWidget<Widget>(
            stream: rebuildStream,

            builder: (context) {
              return Positioned.fill(
                child: IgnorePointer(
                  child: ChatMediaFilterFullscreenPreview(editor: editor),
                ),
              );
            },
          ),

          // ==============================================================
          // FILTER STRIP
          // ==============================================================
          ReactiveWidget<Widget>(
            stream: rebuildStream,

            builder: (context) {
              return PositionedDirectional(
                start: 0,

                end: 0,

                bottom: 0,

                child: ChatMediaFilterBottomBar(
                  editor: editor,

                  session: session,
                ),
              );
            },
          ),

          // ==============================================================
          // HEADER
          // ==============================================================
          ReactiveWidget<Widget>(
            stream: rebuildStream,

            builder: (context) {
              final topInset = MediaQuery.viewPaddingOf(context).top;

              return PositionedDirectional(
                top: 0,

                start: 0,

                end: 0,

                height: topInset + ChatMediaFilterHeader.contentHeight,

                child: ChatMediaFilterHeader(
                  editor: editor,

                  session: session,

                  onApplied: onApplied,
                  onDiscarded: onDiscarded,
                ),
              );
            },
          ),
        ];
      },

      // Your old approved design had no filter-strength/opacity slider.
      slider: (editor, rebuildStream, value, onChanged, onChangeEnd) {
        return ReactiveWidget<Widget>(
          stream: rebuildStream,

          builder: (context) {
            return const SizedBox.shrink();
          },
        );
      },
    ),
  );
}
