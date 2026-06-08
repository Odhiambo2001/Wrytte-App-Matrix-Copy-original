import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';

class FirebaseNewChatItem extends StatelessWidget {
  final UserProfile user;
  final VoidCallback onTap;

  const FirebaseNewChatItem({
    super.key,
    required this.user,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: UserAvatar(
            size: 44,
            imageUrl:
                user.profileImage.trim().isNotEmpty ? user.profileImage : null,
            name: user.displayName,
          ),
          title: Text(
            user.displayName,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          onTap: onTap,
        ),
        const Padding(
          padding: EdgeInsets.only(left: 72),
          child: Divider(height: 1, color: Color(0xFF2A2A2A)),
        ),
      ],
    );
  }
}
