import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/widgets/editor/paint/chat_media_paint_bottom_bar.dart';
import 'package:wrytte/ui/media/widgets/editor/paint/chat_media_paint_header.dart';
import 'package:wrytte/ui/media/widgets/editor/paint/chat_media_paint_path_builders.dart';

PaintEditorConfigs buildChatMediaPaintEditorConfigs({
  required VoidCallback onDiscarded,
}) {
  return PaintEditorConfigs(
    enableZoom: true,

    enableDoubleTapZoom: true,

    editorMinScale: 1,

    editorMaxScale: 8,

    // Keep the main editor's zoom context when entering Paint.
    enableShareZoomMatrix: true,

    // Pro Image Editor owns editable PaintLayer behavior.
    enableEdit: true,

    showLayers: true,

    // We provide our own explicit X / Discard UX.
    enableGesturePop: false,

    initialPaintMode: PaintMode.freeStyle,

    tools: const [
      PaintMode.freeStyle,

      // Real custom square.
      PaintMode.custom1,

      PaintMode.circle,

      // Real custom triangle.
      PaintMode.custom2,

      PaintMode.arrow,
    ],

    customPathBuilders: {
      PaintMode.custom1:
          ({
            required PaintedModel item,
            required PaintEditorConfigs paintEditorConfigs,
            required double scale,
          }) => ChatMediaSquarePathBuilder(
            item: item,
            paintEditorConfigs: paintEditorConfigs,
            scale: scale,
          ),

      PaintMode.custom2:
          ({
            required PaintedModel item,
            required PaintEditorConfigs paintEditorConfigs,
            required double scale,
          }) => ChatMediaTrianglePathBuilder(
            item: item,
            paintEditorConfigs: paintEditorConfigs,
            scale: scale,
          ),
    },

    // Package controls are hidden because Wrytte owns all visible controls.
    showToggleFillButton: false,

    showLineWidthAdjustmentButton: false,

    showOpacityAdjustmentButton: false,

    isInitiallyFilled: false,

    minStrokeWidth: 1,

    maxStrokeWidth: 40,

    // Match the main editor: canvas remains full-screen. Our overlays use
    // physical viewPadding for status/navigation areas.
    safeArea: const EditorSafeArea.none(),

    style: const PaintEditorStyle(
      background: WrytteColors.background,

      appBarBackground: Colors.transparent,

      appBarColor: WrytteColors.textPrimary,

      bottomBarBackground: Colors.transparent,

      bottomBarActiveItemColor: WrytteColors.textPrimary,

      bottomBarInactiveItemColor: WrytteColors.textPrimary,

      initialColor: Color(0xFFFF0000),

      initialStrokeWidth: 3,

      uiOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,

        statusBarIconBrightness: Brightness.light,

        statusBarBrightness: Brightness.dark,

        systemNavigationBarColor: WrytteColors.background,

        systemNavigationBarIconBrightness: Brightness.light,
      ),
    ),

    widgets: PaintEditorWidgets(
      // No package chrome.
      appBar: (editor, rebuildStream) => null,

      bottomBar: (editor, rebuildStream) => null,

      bodyItems: (editor, rebuildStream) {
        return <ReactiveWidget<Widget>>[
          // Header + color rail.
          ReactiveWidget<Widget>(
            stream: rebuildStream,

            builder: (_) {
              return Positioned.fill(
                child: ChatMediaPaintHeader(editor: editor),
              );
            },
          ),

          // Bottom controls.
          ReactiveWidget<Widget>(
            stream: rebuildStream,

            builder: (overlayContext) {
              return PositionedDirectional(
                start: 0,

                end: 0,

                // Position the control group itself so its hit regions match
                // the visible X and checkmark buttons.
                bottom: 80,

                child: ChatMediaPaintBottomBar(
                  editor: editor,
                  onDiscarded: onDiscarded,
                ),
              );
            },
          ),
        ];
      },

      // Disable Pro Image Editor's picker. Wrytte supplies exactly one picker.
      colorPicker: (editor, rebuildStream, currentColor, setColor) => null,
    ),
  );
}
