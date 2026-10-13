import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';

class ChatEncryptionNotice extends StatelessWidget {
  const ChatEncryptionNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Colors.white.withValues(alpha: .52);
    const style = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.2,
    );
    return Semantics(
      label: 'Private messages and calls are end-to-end encrypted.',
      child: ExcludeSemantics(
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text.rich(
              TextSpan(
                style: style.copyWith(color: color),
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(end: 7),
                      child: WrytteSvgIcon(
                        asset: 'assets/svg/boxicons--lock-filled.svg',
                        size: 13,
                        color: color,
                      ),
                    ),
                  ),
                  const TextSpan(text: 'Private messages and calls are\n'),
                  const TextSpan(text: 'end-to-end encrypted.'),
                ],
              ),
              textAlign: TextAlign.center,
              softWrap: false,
            ),
          ),
        ),
      ),
    );
  }
}
