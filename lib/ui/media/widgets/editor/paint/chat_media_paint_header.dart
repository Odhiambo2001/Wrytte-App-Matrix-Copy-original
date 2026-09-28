import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/media/widgets/editor/paint/chat_media_paint_color_picker.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaPaintHeader
    extends StatelessWidget {
  const ChatMediaPaintHeader({
    super.key,
    required this.editor,
  });

  final PaintEditorState editor;

  static const double _topGap = 8;
  static const double _endInset = 18;

  static const double _buttonSize = 40;
  static const double _buttonRadius = 20;

  static const double _controlsGap = 14;
  static const double _pickerTopGap = 16;

  void _undo() {
    if (!editor.canUndo) {
      return;
    }

    unawaited(
      HapticFeedback.selectionClick(),
    );

    editor.undoAction();
  }

  void _setColor(
    Color color,
  ) {
    editor.setColor(
      color,
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final top =
        MediaQuery.viewPaddingOf(
              context,
            ).top +
            _topGap;

    // Both the selected-color circle and picker are in this same Stack.
    //
    // That removes the old cross-render-box alignment calculations entirely.
    return Stack(
      fit: StackFit.expand,
      children: [
        PositionedDirectional(
          top: top,
          end: _endInset,

          child: Row(
            mainAxisSize:
                MainAxisSize.min,

            children: [
              Semantics(
                button: true,
                enabled:
                    editor.canUndo,
                label:
                    'Undo drawing',

                child:
                    AnimatedOpacity(
                  opacity:
                      editor.canUndo
                      ? 1
                      : .42,

                  duration:
                      const Duration(
                    milliseconds:
                        160,
                  ),

                  child:
                      SizedBox.square(
                    dimension:
                        _buttonSize,

                    child:
                        WrytteGlassSurface(
                      borderRadius:
                          BorderRadius.circular(
                        _buttonRadius,
                      ),
                      blur: 22,

                      child:
                          Material(
                        type:
                            MaterialType
                                .transparency,

                        child:
                            InkResponse(
                          onTap:
                              editor.canUndo
                              ? _undo
                              : null,

                          containedInkWell:
                              true,

                          highlightShape:
                              BoxShape.circle,

                          radius:
                              _buttonRadius,

                          splashColor:
                              Colors.transparent,

                          highlightColor:
                              Colors.white
                                  .withValues(
                            alpha:
                                .045,
                          ),

                          child:
                              Center(
                            child:
                                Transform.scale(
                              scale:
                                  .78,

                              child:
                                  const WrytteSvgIcon(
                                asset:
                                    'assets/svg/Undo left icon.svg',
                                size:
                                    23,
                                color:
                                    WrytteColors
                                        .textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(
                width:
                    _controlsGap,
              ),

              Container(
                width:
                    _buttonSize,
                height:
                    _buttonSize,

                decoration:
                    BoxDecoration(
                  color:
                      editor.activeColor,

                  shape:
                      BoxShape.circle,

                  border:
                      Border.all(
                    color:
                        Colors.white
                            .withValues(
                      alpha:
                          .18,
                    ),
                    width:
                        1,
                  ),

                  boxShadow:
                      const [
                    BoxShadow(
                      color:
                          Color(
                        0x55000000,
                      ),
                      blurRadius:
                          10,
                      offset:
                          Offset(
                        0,
                        3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // The color circle's center is 38dp from the right:
        //
        // 18 outer inset + 20 radius.
        //
        // The picker is 28dp wide, so right inset 24 keeps its center at
        // exactly the same X coordinate:
        //
        // 24 + 14 = 38.
        PositionedDirectional(
          top:
              top +
              _buttonSize +
              _pickerTopGap,

          end: 24,

          child:
              ChatMediaPaintColorPicker(
            onColorChanged:
                _setColor,
          ),
        ),
      ],
    );
  }
}