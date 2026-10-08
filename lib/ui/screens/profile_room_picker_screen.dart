import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/ui/screens/new_group_screen.dart';

class ProfileRoomPickerResult {
  final String? value;
  final bool removed;

  const ProfileRoomPickerResult.selected(this.value) : removed = false;
  const ProfileRoomPickerResult.removed() : value = null, removed = true;
}

class ProfileRoomPickerScreen extends StatefulWidget {
  final bool isChannel;
  final String? selectedValue;

  const ProfileRoomPickerScreen({
    super.key,
    required this.isChannel,
    this.selectedValue,
  });

  @override
  State<ProfileRoomPickerScreen> createState() =>
      _ProfileRoomPickerScreenState();
}

class _ProfileRoomPickerScreenState extends State<ProfileRoomPickerScreen> {
  List<mx.Room> get _ownedRooms {
    final matrix = MatrixChatService.instance;
    return matrix.rooms.where((room) {
      if (room.membership != mx.Membership.join || !matrix.isGroupOwner(room)) {
        return false;
      }
      return widget.isChannel
          ? matrix.isChannelRoom(room)
          : matrix.isMatrixGroupRoom(room) && !matrix.isChannelRoom(room);
    }).toList()
      ..sort(
        (a, b) => a.getLocalizedDisplayname().toLowerCase().compareTo(
          b.getLocalizedDisplayname().toLowerCase(),
        ),
      );
  }

  String _roomValue(mx.Room room) => room.id.trim();

  bool _isSelected(mx.Room room) {
    final value = widget.selectedValue?.trim() ?? '';
    return value.isNotEmpty &&
        (value == room.id || value == room.canonicalAlias.trim());
  }

  void _returnSelected(mx.Room room) {
    Navigator.pop(context, ProfileRoomPickerResult.selected(_roomValue(room)));
  }

  Future<void> _create() async {
    final conversation = await Navigator.push<ChatConversation>(
      context,
      MaterialPageRoute(
        builder: (_) => NewGroupScreen(isChannel: widget.isChannel),
      ),
    );
    if (!mounted || conversation == null) return;
    final roomId = conversation.id.trim();
    if (roomId.isEmpty) return;
    final room = MatrixChatService.instance.getRoomById(roomId);
    Navigator.pop(
      context,
      ProfileRoomPickerResult.selected(room == null ? roomId : _roomValue(room)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF08090B);
    const blue = Color(0xFF4DA3FF);
    final kind = widget.isChannel ? 'channel' : 'group';
    final selectedRooms = _ownedRooms.where(_isSelected);
    final selected = selectedRooms.isEmpty ? null : selectedRooms.first;

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 32),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Select $kind', style: const TextStyle(color: Colors.white)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: const Icon(Icons.add, color: blue, size: 30),
            title: Text(
              'Create $kind',
              style: const TextStyle(color: blue, fontSize: 20),
            ),
            onTap: _create,
          ),
          for (final room in _ownedRooms)
            _roomTile(
              room,
              selected: room == selected,
              onTap: () => _returnSelected(room),
            ),
          if (_ownedRooms.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                'You have no $kind yet.',
                style: const TextStyle(color: Color(0xFF92959C), fontSize: 16),
              ),
            ),
        ],
      ),
    );
  }

  Widget _roomTile(
    mx.Room room, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final title = room.getLocalizedDisplayname();
    final memberCount = MatrixChatService.instance.groupMemberCount(room);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: UserAvatar(
        size: 52,
        imageUrl: room.avatar?.toString(),
        name: title,
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '$memberCount ${widget.isChannel ? 'subscribers' : 'members'}',
        style: const TextStyle(color: Color(0xFFB9BBC1), fontSize: 15),
      ),
      trailing:
          selected
              ? TextButton.icon(
                onPressed:
                    () => Navigator.pop(
                      context,
                      const ProfileRoomPickerResult.removed(),
                    ),
                icon: const Icon(Icons.cancel_outlined, color: Colors.redAccent),
                label: const Text(
                  'Remove',
                  style: TextStyle(color: Colors.redAccent),
                ),
              )
              : null,
      onTap: onTap,
    );
  }
}
