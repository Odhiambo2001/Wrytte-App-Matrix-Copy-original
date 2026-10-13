import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class SelectedMessageAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final int selectedCount;
  final bool hasSenderMessages;
  final bool hasReceiverMessages;
  final VoidCallback onClose;
  final VoidCallback onReply;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  final VoidCallback onPin;
  final VoidCallback onForward;
  final VoidCallback onDelete;

  const SelectedMessageAppBar({
    super.key,
    required this.selectedCount,
    required this.hasSenderMessages,
    required this.hasReceiverMessages,
    required this.onClose,
    required this.onReply,
    required this.onEdit,
    required this.onCopy,
    required this.onPin,
    required this.onForward,
    required this.onDelete,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  // Helper method to get available actions based on selection
  List<Widget> _getAvailableActions() {
    final actions = <Widget>[];

    if (selectedCount == 1) {
      if (hasSenderMessages && !hasReceiverMessages) {
        // One sender message selected
        actions.addAll([
          _buildSvgAction('assets/svg/reply.svg', onReply, Icons.reply),
          _buildIconAction(Icons.edit_outlined, onEdit),
          _buildIconAction(Icons.copy_outlined, onCopy),
          _buildIconAction(Icons.push_pin_outlined, onPin),
          _buildSvgAction('assets/svg/forward.svg', onForward, Icons.forward),
          _buildIconAction(Icons.delete_outline, onDelete),
        ]);
      } else if (hasReceiverMessages && !hasSenderMessages) {
        // One receiver message selected
        actions.addAll([
          _buildSvgAction('assets/svg/reply.svg', onReply, Icons.reply),
          _buildIconAction(Icons.copy_outlined, onCopy),
          _buildIconAction(Icons.push_pin_outlined, onPin),
          _buildSvgAction('assets/svg/forward.svg', onForward, Icons.forward),
          _buildIconAction(Icons.delete_outline, onDelete),
        ]);
      }
    } else {
      // Multiple messages selected
      actions.addAll([
        _buildIconAction(Icons.copy_outlined, onCopy),
        _buildSvgAction('assets/svg/forward.svg', onForward, Icons.forward),
        _buildIconAction(Icons.delete_outline, onDelete),
      ]);
    }

    return actions;
  }

  Widget _buildIconAction(IconData icon, VoidCallback? onPressed) {
    return IconButton(
      icon: Icon(icon, color: Colors.white),
      onPressed: onPressed,
    );
  }

  Widget _buildSvgAction(
    String assetPath,
    VoidCallback? onPressed,
    IconData fallbackIcon,
  ) {
    return IconButton(
      icon: SvgPicture.asset(
        assetPath,
        width: 27,
        height: 27,
        colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        // Fallback to material icon if SVG fails to load
      ),
      onPressed: onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final actionWidgets = _getAvailableActions();

    return AppBar(
      backgroundColor: const Color(0xFF0F1013),
      elevation: 0,
      leading: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: onClose,
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                selectedCount == 1 ? '1' : '$selectedCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
          ),
        ],
      ),
      title: const SizedBox(),
      actions: [...actionWidgets, const SizedBox(width: 4)],
    );
  }
}
