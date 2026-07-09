import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/contacts/contact_avatar_sanitizer.dart';

class ContactItem extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;
  final bool isSelectedMode;
  final bool isSelected;
  final bool showCheckbox;
  final bool showInviteButton;

  const ContactItem({
    super.key,
    required this.contact,
    required this.onTap,
    this.isSelectedMode = false,
    this.isSelected = false,
    this.showCheckbox = false,
    this.showInviteButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: UserAvatar(
            size: 44,
            imageUrl: ContactAvatarSanitizer.sanitizeAvatarUrl(
              contact.avatarUrl,
            ),
            name: contact.formattedName,
          ),
          title: Text(
            contact.formattedName,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          subtitle:
              showInviteButton
                  ? Text(
                    contact.primaryPhone,
                    style: const TextStyle(color: Colors.grey),
                  )
                  : null,
          trailing: _buildTrailing(),
          onTap: onTap,
        ),
        const Padding(
          padding: EdgeInsets.only(left: 72),
          child: Divider(height: 1, color: Color(0xFF2A2A2A)),
        ),
      ],
    );
  }

  Widget _buildTrailing() {
    if (showCheckbox && isSelectedMode) {
      return Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isSelected ? Colors.lightBlue : Colors.grey[600],
        ),
        child: Center(
          child:
              isSelected
                  ? const Icon(Icons.check, color: Colors.white, size: 14)
                  : null,
        ),
      );
    }

    if (showInviteButton) {
      return TextButton(
        onPressed: () {},
        child: const Text('Invite', style: TextStyle(color: Color(0xFF4EA4F6))),
      );
    }

    return const SizedBox.shrink();
  }
}
