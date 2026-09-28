import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';

class ChatMediaFilterFullscreenPreview
    extends StatelessWidget {
  const ChatMediaFilterFullscreenPreview({
    super.key,
    required this.editor,
  });

  final FilterEditorState editor;

  @override
  Widget build(
    BuildContext context,
  ) {
    final editorImage =
        editor.editorImage;

    if (editorImage == null) {
      return const ColoredBox(
        color:
            WrytteColors.background,
      );
    }

    Widget preview =
        Image(
      image:
          editorImage.toImageProvider(),

      width:
          double.infinity,

      height:
          double.infinity,

      fit:
          BoxFit.contain,

      alignment:
          Alignment.center,

      gaplessPlayback:
          true,

      filterQuality:
          FilterQuality.high,

      errorBuilder: (
        context,
        error,
        stackTrace,
      ) {
        return const ColoredBox(
          color:
              WrytteColors.background,

          child:
              Center(
            child:
                Icon(
              Icons
                  .image_not_supported_outlined,

              size:
                  26,

              color:
                  WrytteColors
                      .textMuted,
            ),
          ),
        );
      },
    );

    // Apply matrices in exactly the same order as the filter contains them.
    //
    // This keeps the large preview visually identical to the thumbnail.
    for (final matrix
        in editor
            .selectedFilter
            .filters) {
      preview =
          ColorFiltered(
        colorFilter:
            ColorFilter.matrix(
          matrix,
        ),

        child:
            preview,
      );
    }

    return ColoredBox(
      color:
          WrytteColors.background,

      child:
          SizedBox.expand(
        child:
            Center(
          child:
              preview,
        ),
      ),
    );
  }
}

Widget buildChatMediaFilteredPreview({
  required FilterModel filter,
  required EditorImage? editorImage,
}) {
  if (editorImage == null) {
    return const ColoredBox(
      color:
          Color(
        0xFF15171A,
      ),

      child:
          Center(
        child:
            Icon(
          Icons
              .image_not_supported_outlined,

          size:
              18,

          color:
              WrytteColors.textMuted,
        ),
      ),
    );
  }

  Widget preview =
      Image(
    image:
        editorImage.toImageProvider(),

    fit:
        BoxFit.cover,

    gaplessPlayback:
        true,

    filterQuality:
        FilterQuality.medium,
  );

  for (final matrix
      in filter.filters) {
    preview =
        ColorFiltered(
      colorFilter:
          ColorFilter.matrix(
        matrix,
      ),

      child:
          preview,
    );
  }

  return preview;
}