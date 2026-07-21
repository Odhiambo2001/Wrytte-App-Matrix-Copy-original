import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/ui/screens/group_profile_screen.dart';

/// Result returned when the user taps Save.
class ChannelEditResult {
  final String name;
  final String handle;
  final String description;
  final bool deleted;
  final GroupExitRequest? pendingAction;

  const ChannelEditResult({
    required this.name,
    required this.handle,
    required this.description,
    this.deleted = false,
    this.pendingAction,
  });
}

/// Edit page for a channel: Cancel / Save bar, avatar with "Set new photo",
/// then pill fields for name, handle, description, link and channel.
class ChannelEditScreen extends StatefulWidget {
  final String title;
  final String handle;
  final String? description;
  final String? avatarUrl;
  final String conversationId;

  const ChannelEditScreen({
    super.key,
    required this.title,
    required this.handle,
    this.description,
    this.avatarUrl,
    required this.conversationId,
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
  Timer? _aliasDebounce;
  bool _checkingAlias = false;
  bool _aliasAvailable = true;
  bool _showAliasValidation = false;
  String _aliasError = '';
  int _aliasCheckGeneration = 0;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.title);
    _handleController = TextEditingController(text: widget.handle);
    _descriptionController = TextEditingController(
      text: widget.description ?? '',
    );
    _handleController.addListener(_onAliasChanged);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    _descriptionController.dispose();
    _aliasDebounce?.cancel();
    super.dispose();
  }

  String _aliasBody(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.startsWith('.@')) return normalized.substring(2);
    if (normalized.startsWith('@')) return normalized.substring(1);
    return normalized;
  }

  String _cleanAliasBody(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  String _localAlias(String value) {
    final normalized = value.trim().toLowerCase();
    final withoutHash =
        normalized.startsWith('#') ? normalized.substring(1) : normalized;
    return withoutHash.split(':').first;
  }

  bool get _aliasHasBody =>
      _cleanAliasBody(_aliasBody(_handleController.text)).isNotEmpty;

  String get _candidateAlias =>
      '.@${_cleanAliasBody(_aliasBody(_handleController.text))}';

  void _onAliasChanged() {
    final body = _cleanAliasBody(_aliasBody(_handleController.text));
    final normalized = '@$body';
    if (_handleController.text != normalized) {
      _handleController.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
      return;
    }
    _aliasDebounce?.cancel();
    final room = MatrixChatService.instance.getRoomById(widget.conversationId);
    final currentAlias = _localAlias(room?.canonicalAlias ?? '');
    if (body.isEmpty) {
      setState(() {
        _checkingAlias = false;
        _aliasAvailable = false;
        _showAliasValidation = false;
        _aliasError = '';
      });
      return;
    }
    if (currentAlias == _candidateAlias) {
      setState(() {
        _checkingAlias = false;
        _aliasAvailable = true;
        _showAliasValidation = false;
        _aliasError = '';
      });
      return;
    }
    final generation = ++_aliasCheckGeneration;
    setState(() {
      _checkingAlias = true;
      _aliasAvailable = false;
      _showAliasValidation = true;
      _aliasError = '';
    });
    _aliasDebounce = Timer(const Duration(milliseconds: 450), () async {
      final available = await MatrixChatService.instance.isRoomAliasAvailable(
        _candidateAlias,
      );
      if (!mounted || generation != _aliasCheckGeneration) return;
      setState(() {
        _checkingAlias = false;
        _aliasAvailable = available;
        _aliasError =
            available
                ? ''
                : 'The username is already registered in Matrix. Try another one.';
      });
    });
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
    if (!_aliasHasBody || _checkingAlias || !_aliasAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _aliasError.isEmpty
                ? 'Choose an available channel alias.'
                : _aliasError,
          ),
        ),
      );
      return;
    }
    setState(() => _saving = true);

    final room = MatrixChatService.instance.getRoomById(widget.conversationId);
    if (room == null) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    try {
      if (name != room.name.trim()) await room.setName(name);
      final description = _descriptionController.text.trim();
      if (description != room.topic.trim()) {
        await room.setDescription(description);
      }
      if (_candidateAlias != _localAlias(room.canonicalAlias)) {
        await MatrixChatService.instance.replaceGroupAlias(
          roomId: room.id,
          oldAlias: room.canonicalAlias,
          newAliasLocalpart: _candidateAlias,
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save channel: $error')));
      return;
    }

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

  Future<void> _deleteChannel() async {
    final room = MatrixChatService.instance.getRoomById(widget.conversationId);
    if (room == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFF23262C),
            title: const Text(
              'Delete channel',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'This will remove the channel from your account.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Color(0xFFE85D75)),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    if (!mounted) return;
    Navigator.pop(
      context,
      ChannelEditResult(
        name: '',
        handle: '',
        description: '',
        deleted: true,
        pendingAction: GroupExitRequest.delete(
          roomId: widget.conversationId,
          commit: () async {
            await ChatService().dismissDeletedGroupLocally(
              widget.conversationId,
            );
            await MatrixChatService.instance.markPublicGroupDeleted(
              roomId: widget.conversationId,
              canonicalAlias: room.canonicalAlias,
            );
            await MatrixChatService.instance.leaveGroup(widget.conversationId);
          },
        ),
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
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Column(
                  children: [
                    _avatarSection(),
                    const SizedBox(height: 18),
                    _textField(
                      controller: _nameController,
                      hint: 'Channel name',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _textField(
                      controller: _handleController,
                      hint: '@handle',
                      style: const TextStyle(
                        color: Color(0xFF4DA3FF),
                        fontSize: 17,
                      ),
                      inputFormatters: [
                        TextInputFormatter.withFunction((oldValue, newValue) {
                          return newValue.text.startsWith('@')
                              ? newValue
                              : oldValue;
                        }),
                      ],
                      suffix: _aliasSuffix(),
                    ),
                    if (_aliasError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 24, top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _aliasError,
                            style: const TextStyle(
                              color: Color(0xFFFF5A66),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    _textField(
                      controller: _descriptionController,
                      hint: 'Description',
                      style: const TextStyle(color: Colors.white, fontSize: 17),
                      maxLines: 1,
                      minLines: 1,
                    ),
                    const SizedBox(height: 10),
                    _addRow('Link', () => _showUnavailable('Adding links')),
                    const SizedBox(height: 10),
                    _addRow('Group', () => _showUnavailable('Linking groups')),
                  ],
                ),
              ),
            ),
            _deleteFooter(),
          ],
        ),
      ),
    );
  }

  Widget _deleteFooter() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
        child: TextButton(
          onPressed: _saving ? null : _deleteChannel,
          child: const Text(
            'Delete channel',
            style: TextStyle(color: Color(0xFFE85D75), fontSize: 17),
          ),
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
          name:
              _nameController.text.isEmpty
                  ? widget.title
                  : _nameController.text,
          size: 104,
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => _showUnavailable('Changing the photo'),
          child: const Text(
            'Set new photo',
            style: TextStyle(color: Color(0xFF4DA3FF), fontSize: 17),
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
    List<TextInputFormatter>? inputFormatters,
    Widget? suffix,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      decoration: BoxDecoration(
        color: _fieldColor,
        borderRadius: BorderRadius.circular(36),
      ),
      child: TextField(
        controller: controller,
        style: style,
        maxLines: maxLines,
        minLines: minLines ?? maxLines,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF8C8F95), fontSize: 17),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          suffixIcon: suffix,
        ),
      ),
    );
  }

  Widget? _aliasSuffix() {
    if (_checkingAlias) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_showAliasValidation && _aliasAvailable) {
      return const Icon(Icons.check, color: Colors.greenAccent);
    }
    if (_showAliasValidation && _aliasHasBody) {
      return const Icon(Icons.close, color: Colors.white54);
    }
    return null;
  }

  Widget _addRow(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(36),
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 20),
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
