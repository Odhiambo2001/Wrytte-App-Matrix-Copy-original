import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_glass_surface.dart';

class ChatReplyComposerBar extends StatelessWidget {
  const ChatReplyComposerBar({
    super.key,
    required this.sender,
    required this.preview,
    required this.onClose,
  });

  final String sender;
  final String preview;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: WrytteGlassSurface(
        borderRadius: BorderRadius.circular(18),
        blur: 18,
        child: SizedBox(
          height: 54,
          child: Row(
            children: [
              Container(
                width: 3,
                height: 34,
                margin: const EdgeInsetsDirectional.only(start: 13, end: 10),
                decoration: BoxDecoration(
                  color: WrytteColors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sender,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: WrytteColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: WrytteColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Cancel reply',
                onPressed: onClose,
                icon: const Icon(
                  Icons.close_rounded,
                  color: WrytteColors.textSecondary,
                  size: 21,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
