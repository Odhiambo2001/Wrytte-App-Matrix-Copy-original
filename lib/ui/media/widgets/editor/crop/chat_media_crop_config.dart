import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/widgets/editor/crop/chat_media_crop_aspect_ratio_options.dart';
import 'package:wrytte/ui/media/widgets/editor/crop/chat_media_crop_bottom_bar.dart';
import 'package:wrytte/ui/media/widgets/editor/crop/chat_media_crop_frame_overlay.dart';

CropRotateEditorConfigs buildChatMediaCropEditorConfigs({
  required ValueChanged<bool> onApplied,
  required VoidCallback onDiscarded,
}) {
  return CropRotateEditorConfigs(
    rotateDirection: RotateDirection.left,

    // We provide an explicit X/Discard flow.
    enableGesturePop: false,

    // Keep normal layers attached to the real photo transform.
    enableTransformLayers: true,

    enableKeepAspectRatioOnRotate: true,

    maxScale: 8,

    tools: const [
      CropRotateTool.rotate,
      CropRotateTool.flip,
      CropRotateTool.tilt,
      CropRotateTool.aspectRatio,
      CropRotateTool.reset,
    ],

    aspectRatios: const [
      AspectRatioItem(text: 'Original', value: 0),
      AspectRatioItem(text: 'Square', value: 1),
      AspectRatioItem(text: '3:2', value: 3 / 2),
      AspectRatioItem(text: '5:3', value: 5 / 3),
      AspectRatioItem(text: '4:3', value: 4 / 3),
      AspectRatioItem(text: '5:4', value: 5 / 4),
      AspectRatioItem(text: '7:5', value: 7 / 5),
      AspectRatioItem(text: '16:9', value: 16 / 9),
    ],

    // Crop is a real sub-editor, so let Pro Image Editor respect physical
    // status/navigation safe areas.
    safeArea: const EditorSafeArea(),

    style: const CropRotateEditorStyle(
      background: WrytteColors.background,

      appBarBackground: Colors.transparent,

      appBarColor: WrytteColors.textPrimary,

      bottomBarBackground: Colors.transparent,

      bottomBarColor: WrytteColors.textPrimary,

      cropOverlayColor: Color(0xCC000000),

      cropCornerColor: WrytteColors.textPrimary,

      helperLineColor: Color(0xCCFFFFFF),

      helperLineWidth: .8,

      cropCornerLength: 22,

      cropCornerThickness: 3,

      uiOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,

        statusBarIconBrightness: Brightness.light,

        statusBarBrightness: Brightness.dark,

        systemNavigationBarColor: WrytteColors.background,

        systemNavigationBarIconBrightness: Brightness.light,
      ),
    ),

    widgets: CropRotateEditorWidgets(
      // No visible package header.
      appBar: (cropEditor, rebuildStream) => null,

      bodyItems: (cropEditor, rebuildStream) {
        return <ReactiveWidget<Widget>>[
          ReactiveWidget<Widget>(
            stream: rebuildStream,
            builder: (_) {
              return Positioned.fill(
                child: ChatMediaCropFrameOverlay(
                  editor: cropEditor,

                  rebuildStream: rebuildStream,

                  onRotationChanged: (degrees) {
                    cropEditor.tilt(
                      TiltMode.rotate,

                      degrees * math.pi / 180,

                      // Live movement should not spam the undo history.
                      updateStateHistory: false,
                    );
                  },

                  onRotationChangeEnd: (degrees) {
                    // Commit exactly one history step at the end of the drag.
                    cropEditor.tilt(TiltMode.rotate, degrees * math.pi / 180);
                  },
                ),
              );
            },
          ),
        ];
      },

      bottomBar: (cropEditor, rebuildStream) {
        return ReactiveWidget<Widget>(
          stream: rebuildStream,
          builder: (_) {
            return ChatMediaCropBottomBar(
              editor: cropEditor,
              onApplied: onApplied,
              onDiscarded: onDiscarded,
            );
          },
        );
      },

      aspectRatioOptions:
          (cropEditor, rebuildStream, aspectRatio, originalAspectRatio) {
            return ReactiveWidget<Widget>(
              stream: rebuildStream,
              builder: (_) {
                return ChatMediaCropAspectRatioOptions(
                  editor: cropEditor,

                  aspectRatio: aspectRatio,

                  originalAspectRatio: originalAspectRatio,
                );
              },
            );
          },
    ),
  );
}
