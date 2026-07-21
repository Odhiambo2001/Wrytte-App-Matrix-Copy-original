import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';

/// Result returned when the user taps Save.
class ChannelEditResult {
  final String name;
  final String handle;
  final String description;

  const ChannelEditResult({
    required this.name,
    required this.handle,
    required this.description,
  });
}

/// Edit page for a channel: Cancel / Save bar, avatar with "Set new photo",
/// then pill fields for name, handle, description, link and channel.
class ChannelEditScreen extends StatefulWidget {
  final String title;
  final String handle;
  final String? description;
  final String? avatarUrl;

  const ChannelEditScreen({
    super.key,
    required this.title,
    required this.handle,
    this.description,
    this.avatarUrl,
  });

  @override
  State<ChannelEditScreen> createState() => _ChannelEditScreenState();
}

class _ChannelEditScreenState extends State<ChannelEditScreen> {
  static const _fieldColor = Color(0xFF1E2126);

  late final TextEditingController _nameController;
  late final TextEditingController _handleController;
  late final TextEditingController _descriptionController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.title);
    _handleController = TextEditingController(text: widget.handle);
    _descriptionController =
        TextEditingController(text: widget.description ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _showUnavailable(String feature) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$feature will be available soon.')));
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Channel name cannot be empty')),
      );
      return;
    }
    setState(() => _saving = true);

    // TODO: persist to the backend / Matrix room here, e.g.
    //   final room = MatrixClientService.instance.client
    //       .getRoomById(conversationId);
    //   await room?.setName(name);
    // For now we just hand the values back to the profile screen.

    if (!mounted) return;
    Navigator.pop(
      context,
      ChannelEditResult(
        name: name,
        handle: _handleController.text.trim(),
        description: _descriptionController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 30, 20, 24),
                child: Column(
                  children: [
                    _avatarSection(),
                    const SizedBox(height: 40),
                    _textField(
                      controller: _nameController,
                      hint: 'Channel name',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _textField(
                      controller: _handleController,
                      hint: '@handle',
                      style: const TextStyle(
                        color: Color(0xFF4DA3FF),
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _textField(
                      controller: _descriptionController,
                      hint: 'Description',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                      ),
                      maxLines: 3,
                      minLines: 1,
                    ),
                    const SizedBox(height: 16),
                    _addRow('Link', () => _showUnavailable('Adding links')),
                    const SizedBox(height: 16),
                    _addRow(
                      'Group',
                      () => _showUnavailable('Linking groups'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ top bar

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white, fontSize: 20),
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _save,
            child: Text(
              'Save',
              style: TextStyle(
                color: _saving ? Colors.white38 : Colors.white,
                fontSize: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ avatar

  Widget _avatarSection() {
    return Column(
      children: [
        UserAvatar(
          imageUrl: widget.avatarUrl,
          name: _nameController.text.isEmpty
              ? widget.title
              : _nameController.text,
          size: 140,
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: () => _showUnavailable('Changing the photo'),
          child: const Text(
            'Set new photo',
            style: TextStyle(color: Color(0xFF4DA3FF), fontSize: 19),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ fields

  Widget _textField({
    required TextEditingController controller,
    required String hint,
    required TextStyle style,
    int maxLines = 1,
    int? minLines,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      decoration: BoxDecoration(
        color: _fieldColor,
        borderRadius: BorderRadius.circular(36),
      ),
      child: TextField(
        controller: controller,
        style: style,
        maxLines: maxLines,
        minLines: minLines ?? maxLines,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF8C8F95), fontSize: 17),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _addRow(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(36),
      child: Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: _fieldColor,
          borderRadius: BorderRadius.circular(36),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: const TextStyle(color: Color(0xFF8C8F95), fontSize: 17),
            ),
            const Spacer(),
            const Text(
              'Add',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
          ],
        ),
      ),
    );
  }
}
