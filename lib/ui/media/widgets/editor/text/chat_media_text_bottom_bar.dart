import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_font_menu.dart';
import 'package:wrytte/ui/media/widgets/editor/text/chat_media_text_session.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaTextBottomBar
    extends StatelessWidget {
  const ChatMediaTextBottomBar({
    super.key,
    required this.editor,
    required this.session,
  });

  static const double minimumHeight =
      64;

  final TextEditorState editor;
  final ChatMediaTextSession session;

  String _alignmentAsset() {
    return switch (session.alignment) {
      TextAlign.right =>
        'assets/svg/Text alighn icon 2.svg',
      TextAlign.left =>
        'assets/svg/Text alighn icon 3.svg',
      _ =>
        'assets/svg/Text alighn icon 1.svg',
    };
  }

  Future<void> _cancel(
    BuildContext context,
  ) async {
    if (session.busy) {
      return;
    }

    unawaited(
      HapticFeedback.selectionClick(),
    );

    if (!session.hasChanges(
      editor,
    )) {
      await session.discard(
        editor,
      );

      return;
    }

    final hadFocus =
        editor.focusNode.hasFocus;

    editor.focusNode.unfocus();

    session.closeEmoji(
      editor,
    );

    await SystemChannels.textInput.invokeMethod<void>(
      'TextInput.hide',
    );

    if (!context.mounted) {
      return;
    }

    final discard =
        await _showDiscardDialog(
      context,
    );

    if (!context.mounted) {
      return;
    }

    if (discard) {
      await session.discard(
        editor,
      );

      return;
    }

    if (hadFocus) {
      session.restoreKeyboardFocus(
        editor,
      );
    }
  }

  Future<void> _apply() async {
    unawaited(
      HapticFeedback.lightImpact(),
    );

    await session.apply(
      editor,
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return AnimatedBuilder(
      animation:
          session,

      builder: (
        context,
        child,
      ) {
        return SafeArea(
          top:
              false,

          minimum:
              const EdgeInsets.only(
            bottom:
                8,
          ),

          child:
              Padding(
            padding:
                const EdgeInsets.symmetric(
              horizontal:
                  14,
            ),

            child:
                SizedBox(
              height:
                  56,

              child:
                  LayoutBuilder(
                builder: (
                  context,
                  constraints,
                ) {
                  final toolbarWidth =
                      (constraints.maxWidth -
                              120)
                          .clamp(
                            152.0,
                            222.0,
                          )
                          .toDouble();

                  return Row(
                    children: [
                      _RoundButton(
                        tooltip:
                            'Cancel text',

                        onTap:
                            session.busy
                            ? null
                            : () {
                                unawaited(
                                  _cancel(
                                    context,
                                  ),
                                );
                              },

                        child:
                            const Icon(
                          Icons
                              .close_rounded,

                          size:
                              29,

                          color:
                              WrytteColors
                                  .textPrimary,
                        ),
                      ),

                      const SizedBox(
                        width:
                            8,
                      ),

                      Expanded(
                        child:
                            Center(
                          child:
                              SizedBox(
                            width:
                                toolbarWidth,

                            height:
                                50,

                            child:
                                WrytteGlassSurface(
                              borderRadius:
                                  BorderRadius.circular(
                                25,
                              ),

                              blur:
                                  22,

                              child:
                                  Material(
                                type:
                                    MaterialType
                                        .transparency,

                                child:
                                    Row(
                                  children: [
                                    _BackgroundButton(
                                      editor:
                                          editor,

                                      session:
                                          session,
                                    ),

                                    _TextToolButton(
                                      tooltip:
                                          'Change alignment',

                                      asset:
                                          _alignmentAsset(),

                                      onTap:
                                          () {
                                        unawaited(
                                          HapticFeedback
                                              .selectionClick(),
                                        );

                                        session
                                            .cycleAlignment(
                                          editor,
                                        );
                                      },
                                    ),

                                    _TextToolButton(
                                      tooltip:
                                          'Emoji',

                                      asset:
                                          'assets/svg/Sticker icon edit.svg',

                                      active:
                                          session
                                              .emojiVisible,

                                      onTap:
                                          () {
                                        unawaited(
                                          session
                                              .toggleEmoji(
                                            editor,
                                          ),
                                        );
                                      },
                                    ),

                                    ChatMediaTextFontButton(
                                      editor:
                                          editor,

                                      session:
                                          session,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(
                        width:
                            8,
                      ),

                      _RoundButton(
                        tooltip:
                            'Apply text',

                        backgroundColor:
                            WrytteColors.primary,

                        onTap:
                            session.busy
                            ? null
                            : () {
                                unawaited(
                                  _apply(),
                                );
                              },

                        child:
                            AnimatedOpacity(
                          duration:
                              const Duration(
                            milliseconds:
                                120,
                          ),

                          opacity:
                              session.busy
                              ? .6
                              : 1,

                          child:
                              const WrytteSvgIcon(
                            asset:
                                'assets/svg/Checkmark edit.svg',

                            size:
                                27,

                            color:
                                Colors.white,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _showDiscardDialog(
    BuildContext context,
  ) async {
    final result =
        await showGeneralDialog<bool>(
      context:
          context,

      useRootNavigator:
          true,

      barrierDismissible:
          true,

      barrierLabel:
          'Dismiss discard changes menu',

      barrierColor:
          Colors.transparent,

      transitionDuration:
          const Duration(
        milliseconds:
            150,
      ),

      pageBuilder: (
        dialogContext,
        animation,
        secondaryAnimation,
      ) {
        final bottomInset =
            MediaQuery
                .viewPaddingOf(
                  dialogContext,
                )
                .bottom;

        return Material(
          type:
              MaterialType
                  .transparency,

          child:
              Stack(
            children: [
              PositionedDirectional(
                start:
                    14,

                bottom:
                    bottomInset +
                    78,

                child:
                    SizedBox(
                  width:
                      216,

                  child:
                      WrytteGlassSurface(
                    borderRadius:
                        BorderRadius.circular(
                      26,
                    ),

                    blur:
                        22,

                    child:
                        InkWell(
                      onTap:
                          () {
                        Navigator.of(
                          dialogContext,
                        ).pop(
                          true,
                        );
                      },

                      splashFactory:
                          NoSplash
                              .splashFactory,

                      child:
                          const Padding(
                        padding:
                            EdgeInsets.symmetric(
                          horizontal:
                              18,
                          vertical:
                              17,
                        ),

                        child:
                            Text(
                          'Discard changes',

                          style:
                              TextStyle(
                            color:
                                Color(
                              0xFFFF4D4F,
                            ),

                            fontFamily:
                                WrytteTypography
                                    .primaryFontFamily,

                            fontSize:
                                17,

                            fontWeight:
                                FontWeight
                                    .w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    return result ??
        false;
  }
}

class _BackgroundButton
    extends StatelessWidget {
  const _BackgroundButton({
    required this.editor,
    required this.session,
  });

  final TextEditorState editor;
  final ChatMediaTextSession session;

  @override
  Widget build(
    BuildContext context,
  ) {
    final background =
        switch (session.backgroundStyle) {
      ChatMediaTextBackgroundStyle.light =>
        Colors.white,
      ChatMediaTextBackgroundStyle.dark =>
        const Color(
          0x66FFFFFF,
        ),
      ChatMediaTextBackgroundStyle.transparent =>
        Colors.transparent,
    };

    final textColor =
        session.backgroundStyle ==
                ChatMediaTextBackgroundStyle.light
            ? Colors.black
            : Colors.white;

    return Expanded(
      child:
          InkResponse(
        onTap:
            () {
          unawaited(
            HapticFeedback.selectionClick(),
          );

          session.cycleBackground(
            editor,
          );
        },

        containedInkWell:
            true,

        highlightShape:
            BoxShape.circle,

        radius:
            24,

        child:
            Center(
          child:
              AnimatedContainer(
            duration:
                const Duration(
              milliseconds:
                  180,
            ),

            width:
                29,
            height:
                29,

            alignment:
                Alignment.center,

            decoration:
                BoxDecoration(
              color:
                  background,

              borderRadius:
                  BorderRadius.circular(
                7,
              ),

              border:
                  session.backgroundStyle ==
                          ChatMediaTextBackgroundStyle
                              .transparent
                      ? Border.all(
                          color:
                              Colors.white
                                  .withValues(
                            alpha:
                                .3,
                          ),
                        )
                      : null,
            ),

            child:
                Text(
              'A',

              style:
                  TextStyle(
                color:
                    textColor,

                fontFamily:
                    WrytteTypography
                        .primaryFontFamily,

                fontSize:
                    19,

                fontWeight:
                    FontWeight.w600,

                height:
                    1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TextToolButton
    extends StatelessWidget {
  const _TextToolButton({
    required this.tooltip,
    required this.asset,
    required this.onTap,
    this.active = false,
  });

  final String tooltip;
  final String asset;

  final VoidCallback onTap;

  final bool active;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Expanded(
      child:
          InkResponse(
        onTap:
            onTap,

        containedInkWell:
            true,

        highlightShape:
            BoxShape.circle,

        radius:
            24,

        child:
            Center(
          child:
              WrytteSvgIcon(
            asset:
                asset,

            size:
                25,

            color:
                active
                ? WrytteColors.primary
                : WrytteColors
                    .textPrimary,
          ),
        ),
      ),
    );
  }
}

class _RoundButton
    extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.child,
    required this.onTap,
    this.backgroundColor,
  });

  final String tooltip;
  final Widget child;

  final VoidCallback? onTap;

  final Color? backgroundColor;

  @override
  Widget build(
    BuildContext context,
  ) {
    final content =
        SizedBox.square(
      dimension:
          52,

      child:
          backgroundColor ==
                  null
              ? WrytteGlassSurface(
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
                        InkResponse(
                      onTap:
                          onTap,

                      containedInkWell:
                          true,

                      highlightShape:
                          BoxShape.circle,

                      radius:
                          26,

                      child:
                          Center(
                        child:
                            child,
                      ),
                    ),
                  ),
                )
              : DecoratedBox(
                  decoration:
                      BoxDecoration(
                    color:
                        backgroundColor,

                    shape:
                        BoxShape.circle,
                  ),

                  child:
                      Material(
                    type:
                        MaterialType
                            .transparency,

                    child:
                        InkResponse(
                      onTap:
                          onTap,

                      containedInkWell:
                          true,

                      highlightShape:
                          BoxShape.circle,

                      radius:
                          26,

                      child:
                          Center(
                        child:
                            child,
                      ),
                    ),
                  ),
                ),
    );

    return Semantics(
      button:
          true,

      enabled:
          onTap != null,

      label:
          tooltip,

      child:
          content,
    );
  }
}