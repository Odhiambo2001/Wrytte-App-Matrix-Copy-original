import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';

class NewGroupScreen extends StatefulWidget {
  final bool isChannel;

  const NewGroupScreen({super.key, this.isChannel = false});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _chat = ChatService();
  final _nameController = TextEditingController();
  late final _aliasController = TextEditingController(text: _aliasPrefix);
  Timer? _aliasDebounce;
  bool? _isPublic;
  bool _checkingAlias = false;
  bool _aliasAvailable = false;
  String _aliasError = '';
  int _aliasCheckGeneration = 0;

  bool get _hasName => _nameController.text.isNotEmpty;
  String get _aliasPrefix => widget.isChannel ? '.@' : 'gr.@';
  bool get _aliasHasBody => _aliasBody(_aliasController.text).isNotEmpty;
  bool get _canGoNext {
    if (!_hasName) return false;
    if (widget.isChannel) {
      return _aliasHasBody && _aliasAvailable && !_checkingAlias;
    }
    if (_isPublic == null) return false;
    if (_isPublic == false) return true;
    return _aliasHasBody && _aliasAvailable && !_checkingAlias;
  }

  @override
  void initState() {
    super.initState();
    _nameController.addListener(() => setState(() {}));
    _aliasController.addListener(_onAliasChanged);
  }

  @override
  void dispose() {
    _aliasDebounce?.cancel();
    _nameController.dispose();
    _aliasController.dispose();
    super.dispose();
  }

  String _aliasBody(String value) {
    final raw = value.trim().toLowerCase();
    if (!raw.startsWith(_aliasPrefix)) return raw;
    return raw.substring(_aliasPrefix.length);
  }

  String _cleanAliasBody(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  void _onAliasChanged() {
    final body = _cleanAliasBody(_aliasBody(_aliasController.text));
    final next = '$_aliasPrefix$body';
    if (_aliasController.text != next) {
      _aliasController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      return;
    }

    _aliasDebounce?.cancel();
    setState(() {
      _aliasAvailable = false;
      _aliasError = '';
      _checkingAlias = body.isNotEmpty;
    });
    if (body.isEmpty) return;

    final generation = ++_aliasCheckGeneration;
    _aliasDebounce = Timer(const Duration(milliseconds: 450), () async {
      final available = await _chat.isGroupAliasAvailable('$_aliasPrefix$body');
      if (!mounted || generation != _aliasCheckGeneration) return;
      setState(() {
        _checkingAlias = false;
        _aliasAvailable = available;
        _aliasError =
            available ? '' : 'The username is not available. Try another one';
      });
    });
  }

  Future<void> _goNext() async {
    if (!_canGoNext) return;
    final conversation = await Navigator.push<ChatConversation>(
      context,
      MaterialPageRoute(
        builder:
            (_) => _NewGroupMembersScreen(
              groupName: _nameController.text,
              isPublic: widget.isChannel || _isPublic == true,
              aliasLocalpart:
                  widget.isChannel || _isPublic == true
                      ? _aliasController.text
                      : null,
              isChannel: widget.isChannel,
            ),
      ),
    );
    if (!mounted || conversation == null) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder:
            (_) => ChatScreen(
              conversationId: conversation.id,
              receiverId: conversation.otherUserId,
              currentUserId: _chat.currentUserId ?? '',
              title: conversation.otherUserName ?? _nameController.text,
              avatarUrl: conversation.otherUserAvatar,
              initialMemberCount: conversation.participants.length,
              conversationKind:
                  widget.isChannel
                      ? ConversationKind.channel
                      : ConversationKind.group,
            ),
      ),
    );
  }

  void _setPublic(bool value) {
    setState(() {
      _isPublic = value;
      if (value && _aliasController.text.trim().isEmpty) {
        _aliasController.text = _aliasPrefix;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  _roundButton(
                    Icons.arrow_back_ios_new,
                    () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        widget.isChannel ? 'New Channel' : 'New Group',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: _nextButton(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(24, top > 0 ? 10 : 20, 24, 24),
                children: [
                  _nameCard(),
                  if (widget.isChannel) ...[
                    const SizedBox(height: 14),
                    _aliasField(),
                    if (_aliasError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 32, top: 10),
                        child: Text(
                          _aliasError,
                          style: const TextStyle(
                            color: Color(0xFFFF5A66),
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ] else ...[
                    const SizedBox(height: 16),
                    const Text(
                      "Private group can't be found in search,\nyou can join only if you were invited.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _choiceRow(
                      'Private',
                      _isPublic == false,
                      () => _setPublic(false),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Public group can be found in search,\nanyone can join.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _choiceRow(
                      'Public',
                      _isPublic == true,
                      () => _setPublic(true),
                    ),
                    if (_isPublic == true) ...[
                      const SizedBox(height: 14),
                      _aliasField(),
                      if (_aliasError.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 32, top: 10),
                          child: Text(
                            _aliasError,
                            style: const TextStyle(
                              color: Color(0xFFFF5A66),
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nextButton() {
    return GestureDetector(
      onTap: _canGoNext ? _goNext : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF15181D),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Text(
          'Next',
          style: TextStyle(
            color: _canGoNext ? Colors.white : Colors.white38,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _roundButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0xFF15181D),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(icon, color: Colors.white, size: 17),
      ),
    );
  }

  Widget _nameCard() {
    return Container(
      height: 86,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF23262C),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              color: Color(0xFF063B78),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.camera_alt,
              color: Color(0xFF4DA3FF),
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: TextField(
              controller: _nameController,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              cursorColor: const Color(0xFF4DA3FF),
              decoration: InputDecoration(
                hintText: widget.isChannel ? 'Channel name' : 'Group name',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 18),
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choiceRow(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: const Color(0xFF23262C),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 19),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? const Color(0xFF4DA3FF) : Colors.transparent,
                border: Border.all(
                  color: selected ? const Color(0xFF4DA3FF) : Colors.white30,
                  width: 1.5,
                ),
              ),
              child:
                  selected
                      ? const Icon(Icons.check, color: Colors.white, size: 16)
                      : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _aliasField() {
    Widget? suffix;
    if (_checkingAlias) {
      suffix = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_aliasHasBody && _aliasAvailable) {
      suffix = const Icon(Icons.check, color: Colors.greenAccent, size: 24);
    } else if (_aliasHasBody) {
      suffix = GestureDetector(
        onTap: () => _aliasController.text = _aliasPrefix,
        child: const Icon(Icons.close, color: Colors.white54, size: 22),
      );
    }

    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: const Color(0xFF23262C),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _aliasController,
              inputFormatters:
                  widget.isChannel
                      ? [
                        TextInputFormatter.withFunction((oldValue, newValue) {
                          return newValue.text.startsWith(_aliasPrefix)
                              ? newValue
                              : oldValue;
                        }),
                      ]
                      : null,
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(color: Color(0xFF4DA3FF), fontSize: 18),
              cursorColor: const Color(0xFF4DA3FF),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
          if (suffix != null) suffix,
        ],
      ),
    );
  }
}

class _NewGroupMembersScreen extends StatefulWidget {
  final String groupName;
  final bool isPublic;
  final String? aliasLocalpart;
  final bool isChannel;

  const _NewGroupMembersScreen({
    required this.groupName,
    required this.isPublic,
    this.aliasLocalpart,
    this.isChannel = false,
  });

  @override
  State<_NewGroupMembersScreen> createState() => _NewGroupMembersScreenState();
}

class _NewGroupMembersScreenState extends State<_NewGroupMembersScreen> {
  final _chat = ChatService();
  final _searchController = TextEditingController();
  final Set<String> _selectedKeys = {};
  List<Contact> _contacts = const [];
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    final owner = await AuthService.instance.getCurrentUserId() ?? '';
    if (owner.trim().isEmpty) return;
    final contacts = await ContactLocalDb.loadSavedContacts(ownerUserId: owner);
    if (!mounted) return;
    setState(() {
      _contacts =
          contacts
              .where(
                (c) => (c.wrytteUserId ?? c.primaryPhone).trim().isNotEmpty,
              )
              .toList()
            ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
    });
  }

  String _contactKey(Contact contact) {
    return (contact.wrytteUserId?.trim().isNotEmpty == true
                ? contact.wrytteUserId
                : contact.primaryPhone)
            ?.trim() ??
        '';
  }

  List<Contact> get _visibleContacts {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _contacts;
    return _contacts
        .where(
          (c) =>
              c.formattedName.toLowerCase().contains(query) ||
              c.primaryPhone.toLowerCase().contains(query),
        )
        .toList();
  }

  Future<void> _create() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final selectedIds =
          _contacts
              .where((contact) => _selectedKeys.contains(_contactKey(contact)))
              .map(_contactKey)
              .where((key) => key.isNotEmpty)
              .toList();
      final conversation = await _chat.createGroupConversation(
        name: widget.groupName,
        isPublic: widget.isPublic,
        aliasLocalpart: widget.aliasLocalpart,
        memberIds: selectedIds,
        conversationKind:
            widget.isChannel
                ? ConversationKind.channel
                : ConversationKind.group,
      );
      if (!mounted) return;
      Navigator.pop(context, conversation);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to create ${widget.isChannel ? 'channel' : 'group'}: $e',
          ),
        ),
      );
      setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: Color(0xFF15181D),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, color: Colors.white),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.isChannel ? 'New channel' : 'New group',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${_selectedKeys.length}/0 members',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: GestureDetector(
                      onTap: _creating ? null : _create,
                      child: Container(
                        height: 42,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFF15181D),
                          borderRadius: BorderRadius.circular(21),
                        ),
                        child:
                            _creating
                                ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Text(
                                  'Create',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF23262C),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, color: Colors.white38),
                    hintText: 'Search',
                    hintStyle: TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                itemCount: _visibleContacts.length,
                itemBuilder: (context, index) {
                  final contact = _visibleContacts[index];
                  final key = _contactKey(contact);
                  final selected = _selectedKeys.contains(key);
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 6,
                    ),
                    leading: UserAvatar(
                      imageUrl: contact.avatarUrl,
                      name: contact.formattedName,
                      size: 54,
                    ),
                    title: Text(
                      contact.formattedName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle:
                        contact.primaryPhone.isEmpty
                            ? null
                            : Text(
                              contact.primaryPhone,
                              style: const TextStyle(color: Colors.white54),
                            ),
                    trailing: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            selected
                                ? const Color(0xFF1ECB6B)
                                : Colors.transparent,
                        border: Border.all(
                          color:
                              selected
                                  ? const Color(0xFF1ECB6B)
                                  : Colors.white38,
                          width: 1.6,
                        ),
                      ),
                      child:
                          selected
                              ? const Icon(
                                Icons.check,
                                color: Colors.black,
                                size: 20,
                              )
                              : null,
                    ),
                    onTap: () {
                      if (key.isEmpty) return;
                      setState(() {
                        if (selected) {
                          _selectedKeys.remove(key);
                        } else {
                          _selectedKeys.add(key);
                        }
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
