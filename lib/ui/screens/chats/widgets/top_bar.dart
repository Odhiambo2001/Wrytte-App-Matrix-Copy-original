import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wrytte/ui/screens/chats/widgets/selection_top_bar.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';
import 'package:wrytte/ui/screens/new_group_screen.dart';
import 'package:wrytte/ui/screens/profile_screen.dart';

class TopBar extends StatelessWidget implements PreferredSizeWidget {
  final bool isSelectionMode;
  final int selectedCount;
  final VoidCallback? onEditPressed;
  final VoidCallback? onSelectionClose;
  final VoidCallback? onMarkAsRead;
  final VoidCallback? onPin;
  final VoidCallback? onMute;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;
  final VoidCallback? onStoriesPressed;
  final VoidCallback? onMorePressed;

  const TopBar({
    super.key,
    this.isSelectionMode = false,
    this.selectedCount = 0,
    this.onEditPressed,
    this.onSelectionClose,
    this.onMarkAsRead,
    this.onPin,
    this.onMute,
    this.onArchive,
    this.onDelete,
    this.onStoriesPressed,
    this.onMorePressed,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  static const double _pillHeight = 44.0;
  static const Color _white = Colors.white;

  Future<void> _openCamera() async {
    final ImagePicker picker = ImagePicker();
    final XFile? photo = await picker.pickImage(source: ImageSource.camera);

    if (photo != null) {
      debugPrint('Photo captured: ${photo.path}');
    }
  }

  void _showMoreMenu(BuildContext context, Offset anchorOffset) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        anchorOffset.dx - 180,
        anchorOffset.dy + 50,
        anchorOffset.dx,
        anchorOffset.dy,
      ),
      color: const Color(0xFF23262C),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      items: [
        PopupMenuItem(
          padding: EdgeInsets.zero,
          value: 'group',
          child: _buildMenuItem(Icons.group_outlined, 'New group'),
        ),
        PopupMenuItem(
          padding: EdgeInsets.zero,
          value: 'contact',
          child: _buildMenuItem(Icons.person_add_outlined, 'New contact'),
        ),
        PopupMenuItem(
          padding: EdgeInsets.zero,
          value: 'channel',
          child: _buildMenuItem(Icons.campaign_outlined, 'Create channel'),
        ),
        PopupMenuItem(
          padding: EdgeInsets.zero,
          value: 'profile',
          child: _buildMenuItem(Icons.person_outline, 'Profile'),
        ),
      ],
    ).then((value) {
      if (!context.mounted) return;
      if (value == 'contact') {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NewContactPage(token: '')),
        );
      } else if (value == 'profile') {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ProfileScreen()),
        );
      } else if (value == 'group') {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NewGroupScreen()),
        );
      } else if (value == 'channel') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const NewGroupScreen(isChannel: true),
          ),
        );
      }
    });
  }

  Widget _buildMenuItem(IconData icon, String label) {
    return Container(
      width: 200,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: _white, size: 20),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(
              color: _white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isSelectionMode) {
      return SelectionTopBar(
        selectedCount: selectedCount,
        onClose: onSelectionClose ?? () {},
        onMarkAsRead: onMarkAsRead ?? () {},
        onPin: onPin ?? () {},
        onMute: onMute ?? () {},
        onArchive: onArchive ?? () {},
        onDelete: onDelete ?? () {},
      );
    }

    final topInset = MediaQuery.of(context).padding.top;

    return SizedBox(
      height: preferredSize.height + topInset,
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Edit pill ─────────────────────────────────────────────────
              GestureDetector(
                onTap: onEditPressed,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Container(
                      height: _pillHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF23262C).withValues(alpha: 0.30),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: const Color(0xFF23262C),
                          width: 1.0,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'Edit',
                        style: TextStyle(
                          color: Color(0xFF4DA3FF),
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const Spacer(),

              // ── Icons pill ────────────────────────────────────────────────
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    height: _pillHeight,
                    decoration: BoxDecoration(
                      color: const Color(0xFF23262C).withValues(alpha: 0.30),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: const Color(0xFF23262C),
                        width: 1.0,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 44,
                          height: _pillHeight,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            onPressed: _openCamera, // Camera opens immediately
                            icon: SvgPicture.asset(
                              'assets/svg/stories_icon.svg',
                              height: 20,
                              width: 20,
                              colorFilter: const ColorFilter.mode(
                                Color(0xFF4DA3FF),
                                BlendMode.srcIn,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          height: _pillHeight,
                          child: Builder(
                            builder:
                                (context) => IconButton(
                                  padding: EdgeInsets.zero,
                                  onPressed: () {
                                    final RenderBox button =
                                        context.findRenderObject() as RenderBox;
                                    final Offset offset = button.localToGlobal(
                                      Offset.zero,
                                    );
                                    _showMoreMenu(context, offset);
                                  },
                                  icon: const Icon(
                                    Icons.more_vert,
                                    color: Color(0xFF4DA3FF),
                                    size: 22,
                                  ),
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
