import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

import 'package:wrytte/ui/media/widgets/editor/filter/chat_media_filter_session.dart';

class ChatMediaFilterHeader extends StatefulWidget {
  const ChatMediaFilterHeader({
    super.key,
    required this.editor,
    required this.session,
    required this.onApplied,
    required this.onDiscarded,
  });

  static const double contentHeight = 64;

  final FilterEditorState editor;
  final ChatMediaFilterSession session;

  final ValueChanged<bool> onApplied;
  final VoidCallback onDiscarded;

  @override
  State<ChatMediaFilterHeader> createState() => _ChatMediaFilterHeaderState();
}

class _ChatMediaFilterHeaderState extends State<ChatMediaFilterHeader> {
  static const double _buttonSize = 52;

  bool _busy = false;
  bool _discardOpen = false;

  Future<void> _cancel() async {
    if (_busy || _discardOpen) {
      return;
    }

    unawaited(HapticFeedback.selectionClick());

    if (!widget.session.hasChanges(widget.editor)) {
      widget.onDiscarded();
      return;
    }

    _discardOpen = true;

    final discard = await _showDiscardDialog(context);

    _discardOpen = false;

    if (!discard || !mounted) {
      return;
    }

    unawaited(HapticFeedback.lightImpact());

    // PIE closes this Filter editor without applying the current session.
    widget.onDiscarded();
  }

  void _apply() {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
    });

    unawaited(HapticFeedback.lightImpact());

    final filterActive = !widget.session.isOriginal(widget.editor);

    widget.onApplied(filterActive);

    widget.editor.done();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.viewPaddingOf(context).top;

    final isOriginal = widget.session.isOriginal(widget.editor);

    return SizedBox(
      height: topInset + ChatMediaFilterHeader.contentHeight,

      child: Padding(
        padding: EdgeInsets.fromLTRB(12, topInset + 7, 12, 0),

        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,

          children: [
            _FilterRoundButton(
              tooltip: 'Cancel filters',

              onTap: _busy
                  ? null
                  : () {
                      unawaited(_cancel());
                    },

              child: const Icon(
                Icons.close_rounded,

                size: 29,

                color: WrytteColors.textPrimary,
              ),
            ),

            _FilterRoundButton(
              tooltip: 'Apply filter',

              backgroundColor: isOriginal
                  ? WrytteColors.primary.withValues(alpha: .72)
                  : WrytteColors.primary,

              onTap: _busy ? null : _apply,

              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 120),

                opacity: _busy
                    ? .60
                    : isOriginal
                    ? .70
                    : 1,

                child: const WrytteSvgIcon(
                  asset: 'assets/svg/Checkmark edit.svg',

                  size: 27,

                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _showDiscardDialog(BuildContext context) async {
    final result = await showGeneralDialog<bool>(
      context: context,

      useRootNavigator: true,

      barrierDismissible: true,

      barrierLabel: 'Dismiss discard changes menu',

      barrierColor: Colors.transparent,

      transitionDuration: const Duration(milliseconds: 150),

      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final topInset = MediaQuery.viewPaddingOf(dialogContext).top;

        return Material(
          type: MaterialType.transparency,

          child: Stack(
            children: [
              PositionedDirectional(
                top: topInset + 66,

                start: 12,

                child: SizedBox(
                  width: 216,

                  child: WrytteGlassSurface(
                    borderRadius: BorderRadius.circular(26),

                    blur: 22,

                    child: Material(
                      type: MaterialType.transparency,

                      child: InkWell(
                        onTap: () {
                          Navigator.of(dialogContext).pop(true);
                        },

                        splashFactory: NoSplash.splashFactory,

                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 18,

                            vertical: 17,
                          ),

                          child: Text(
                            'Discard changes',

                            style: TextStyle(
                              color: Color(0xFFFF4D4F),

                              fontFamily: WrytteTypography.primaryFontFamily,

                              fontSize: 17,

                              fontWeight: FontWeight.w500,
                            ),
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

      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,

          curve: Curves.easeOutCubic,

          reverseCurve: Curves.easeInCubic,
        );

        return FadeTransition(
          opacity: curved,

          child: ScaleTransition(
            alignment: Alignment.topLeft,

            scale: Tween<double>(begin: .96, end: 1).animate(curved),

            child: child,
          ),
        );
      },
    );

    return result ?? false;
  }
}

class _FilterRoundButton extends StatelessWidget {
  const _FilterRoundButton({
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
  Widget build(BuildContext context) {
    final button = SizedBox.square(
      dimension: _ChatMediaFilterHeaderState._buttonSize,

      child: backgroundColor == null
          ? WrytteGlassSurface(
              borderRadius: BorderRadius.circular(26),

              blur: 22,

              child: Material(
                type: MaterialType.transparency,

                child: InkResponse(
                  onTap: onTap,

                  containedInkWell: true,

                  highlightShape: BoxShape.circle,

                  radius: 26,

                  splashColor: Colors.transparent,

                  highlightColor: Colors.white.withValues(alpha: .045),

                  child: Center(child: child),
                ),
              ),
            )
          : DecoratedBox(
              decoration: BoxDecoration(
                color: backgroundColor,

                shape: BoxShape.circle,
              ),

              child: Material(
                type: MaterialType.transparency,

                child: InkResponse(
                  onTap: onTap,

                  containedInkWell: true,

                  highlightShape: BoxShape.circle,

                  radius: 26,

                  splashColor: Colors.transparent,

                  child: Center(child: child),
                ),
              ),
            ),
    );

    return Semantics(
      button: true,

      enabled: onTap != null,

      label: tooltip,

      child: button,
    );
  }
}
