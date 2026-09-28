import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatMediaEditorHeader extends StatelessWidget {
  const ChatMediaEditorHeader({
    super.key,
    required this.onBack,
  });

  final VoidCallback onBack;

  static const double contentHeight = 64;

  static const double _horizontalInset = 13;
  static const double _topGap = 6;

  static const double _buttonSize = 46;
  static const double _buttonRadius = 23;

  void _handleBack() {
    unawaited(
      HapticFeedback.selectionClick(),
    );

    onBack();
  }

  @override
  Widget build(BuildContext context) {
    // IMPORTANT:
    //
    // The Pro Image Editor main canvas uses EditorSafeArea.none().
    //
    // MediaQuery.padding can therefore be modified/removed inside that
    // subtree. viewPadding represents the physical system inset and is what
    // we want for our custom chrome.
    final topInset =
        MediaQuery.viewPaddingOf(context).top;

    return SizedBox(
      height: topInset + contentHeight,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: _horizontalInset,
          end: _horizontalInset,
          top: topInset + _topGap,
        ),
        child: Align(
          alignment: AlignmentDirectional.topStart,
          child: Semantics(
            button: true,
            label: 'Back',
            child: SizedBox.square(
              dimension: _buttonSize,
              child: WrytteGlassSurface(
                borderRadius: BorderRadius.circular(
                  _buttonRadius,
                ),
                blur: 20,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkResponse(
                    onTap: _handleBack,
                    containedInkWell: true,
                    highlightShape: BoxShape.circle,
                    radius: _buttonRadius,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.white.withValues(
                      alpha: .045,
                    ),
                    child: Center(
                      child: Transform.translate(
                        offset: const Offset(
                          -0.5,
                          0,
                        ),
                        child: const WrytteSvgIcon(
                          asset:
                              'assets/svg/ic--round-arrow-back-ios.svg',
                          size: 27,
                          color: WrytteColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}