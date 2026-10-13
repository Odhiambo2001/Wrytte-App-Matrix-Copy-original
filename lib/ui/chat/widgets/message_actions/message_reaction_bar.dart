import 'package:flutter/material.dart';

import 'package:wrytte/ui/chat/models/message_action.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class MessageReactionBar extends StatelessWidget {
  const MessageReactionBar({
    super.key,
    required this.reactions,
    required this.onReactionSelected,
    this.onMoreReactions,
  });

  static const double height = 54;
  static const double reactionExtent = 42;

  static const double startPadding = 6;
  static const double endPadding = 5;

  static const double moreGap = 2;
  static const double moreExtent = 40;

  static const double radius = 27;

  // Keep these public because message_action_overlay.dart
  // also uses them for the connector bubbles.
  static const double blurSigma = 24;

  // EXACT same glass color used by WrytteGlassSurface.
  static const Color glassColor =
      Color(0xB31B1E24);

  static Color get surfaceColor =>
      glassColor;

  final List<String> reactions;

  final MessageReactionHandler
      onReactionSelected;

  final MessageMoreReactionsHandler?
      onMoreReactions;

  static double naturalWidthFor({
    required int reactionCount,
    required bool hasMore,
  }) {
    return startPadding +
        (reactionCount *
            reactionExtent) +
        (hasMore
            ? moreGap + moreExtent
            : 0) +
        endPadding;
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    if (reactions.isEmpty &&
        onMoreReactions == null) {
      return const SizedBox.shrink();
    }

    final BorderRadius borderRadius =
        BorderRadius.circular(
      radius,
    );

    return SizedBox(
      height: height,

      child: DecoratedBox(
        // Shadow stays outside of the glass surface.
        decoration: BoxDecoration(
          borderRadius:
              borderRadius,

          boxShadow: [
            BoxShadow(
              color: Colors.black
                  .withValues(
                alpha: .24,
              ),
              blurRadius: 18,
              offset:
                  const Offset(
                0,
                6,
              ),
            ),
          ],
        ),

        // =====================================================
        // SHARED WRYTTE GLASS SURFACE
        // =====================================================

        child: WrytteGlassSurface(
          borderRadius:
              borderRadius,

          color:
              glassColor,

          blur:
              blurSigma,

          child: Material(
            type:
                MaterialType.transparency,

            child:
                SingleChildScrollView(
              scrollDirection:
                  Axis.horizontal,

              physics:
                  const ClampingScrollPhysics(),

              child: Padding(
                padding:
                    const EdgeInsetsDirectional
                        .fromSTEB(
                  startPadding,
                  4,
                  endPadding,
                  4,
                ),

                child: Row(
                  mainAxisSize:
                      MainAxisSize.min,

                  children: [
                    for (final String reaction
                        in reactions)
                      _ReactionButton(
                        reaction:
                            reaction,

                        onPressed: () {
                          onReactionSelected(
                            reaction,
                          );
                        },
                      ),

                    if (onMoreReactions !=
                        null) ...[
                      const SizedBox(
                        width:
                            moreGap,
                      ),

                      _MoreReactionButton(
                        onPressed: () {
                          onMoreReactions
                              ?.call();
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactionButton
    extends StatelessWidget {
  const _ReactionButton({
    required this.reaction,
    required this.onPressed,
  });

  final String reaction;
  final VoidCallback onPressed;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Semantics(
      button: true,
      label:
          'React with $reaction',

      child: InkResponse(
        onTap:
            onPressed,

        containedInkWell:
            true,

        highlightShape:
            BoxShape.circle,

        radius:
            21,

        child: SizedBox.square(
          dimension:
              MessageReactionBar
                  .reactionExtent,

          child: Center(
            child: Text(
              reaction,

              style:
                  const TextStyle(
                fontSize:
                    23,
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

class _MoreReactionButton
    extends StatelessWidget {
  const _MoreReactionButton({
    required this.onPressed,
  });

  final VoidCallback onPressed;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Semantics(
      button: true,
      label:
          'Show more reactions',

      child: InkResponse(
        onTap:
            onPressed,

        containedInkWell:
            true,

        highlightShape:
            BoxShape.circle,

        radius:
            21,

        child: Container(
          width:
              40,

          height:
              40,

          alignment:
              Alignment.center,

          decoration:
              BoxDecoration(
            color:
                Colors.white
                    .withValues(
              alpha:
                  .075,
            ),

            shape:
                BoxShape.circle,
          ),

          child:
              const Icon(
            Icons
                .keyboard_arrow_down_rounded,

            size:
                23,

            color:
                WrytteColors
                    .textSecondary,
          ),
        ),
      ),
    );
  }
}