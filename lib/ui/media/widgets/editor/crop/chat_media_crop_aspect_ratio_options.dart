import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaCropAspectRatioOptions
    extends StatelessWidget {
  const ChatMediaCropAspectRatioOptions({
    super.key,
    required this.editor,
    required this.aspectRatio,
    required this.originalAspectRatio,
  });

  final CropRotateEditorState editor;

  final double aspectRatio;
  final double originalAspectRatio;

  bool _near(
    double first,
    double second,
  ) {
    return (first - second).abs() <
        .0001;
  }

  bool _selected(
    double? value,
  ) {
    if (value == null) {
      return false;
    }

    if (value == 0) {
      return _near(
        aspectRatio,
        originalAspectRatio,
      );
    }

    return _near(
      aspectRatio,
      value,
    );
  }

  void _choose(
    BuildContext context,
    double? value,
  ) {
    if (value == null) {
      return;
    }

    unawaited(
      HapticFeedback.selectionClick(),
    );

    editor.updateAspectRatio(
      value,
    );

    Navigator.of(
      context,
    ).maybePop();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final options =
        editor
            .cropRotateEditorConfigs
            .aspectRatios;

    return Material(
      type:
          MaterialType
              .transparency,
      child: Center(
        child:
            Padding(
          padding:
              const EdgeInsets.all(
            12,
          ),
          child:
              ConstrainedBox(
            constraints:
                const BoxConstraints(
              maxWidth: 246,
              maxHeight: 350,
            ),
            child:
                WrytteGlassSurface(
              borderRadius:
                  BorderRadius.circular(
                26,
              ),
              blur: 22,
              child:
                  Material(
                type:
                    MaterialType
                        .transparency,
                child:
                    ListView.builder(
                  shrinkWrap:
                      true,
                  padding:
                      const EdgeInsets.symmetric(
                    vertical: 8,
                  ),
                  itemCount:
                      options.length,
                  itemBuilder: (
                    context,
                    index,
                  ) {
                    final option =
                        options[index];

                    final selected =
                        _selected(
                      option.value,
                    );

                    return Semantics(
                      button:
                          true,
                      selected:
                          selected,
                      label:
                          option.text,
                      child:
                          InkWell(
                        onTap: () {
                          _choose(
                            context,
                            option.value,
                          );
                        },
                        splashFactory:
                            NoSplash
                                .splashFactory,
                        child:
                            Padding(
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal:
                                18,
                            vertical:
                                9,
                          ),
                          child:
                              Row(
                            children: [
                              Expanded(
                                child:
                                    Text(
                                  option.text,
                                  style:
                                      TextStyle(
                                    color:
                                        WrytteColors
                                            .textPrimary,
                                    fontFamily:
                                        WrytteTypography
                                            .primaryFontFamily,
                                    fontSize:
                                        17,
                                    fontWeight:
                                        selected
                                        ? FontWeight
                                            .w600
                                        : FontWeight
                                            .w400,
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
      ),
    );
  }
}