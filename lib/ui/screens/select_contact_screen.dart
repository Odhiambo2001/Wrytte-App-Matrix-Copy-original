import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wrytte/components/contact_components/contact_item.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_avatar_sanitizer.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';
import 'package:wrytte/ui/screens/new_group_screen.dart';

import 'package:wrytte/services/contacts/contact_local_db.dart';

class _ContactChatOpenData {
  final String conversationId;
  final List<ChatMessage> messages;

  const _ContactChatOpenData({
    required this.conversationId,
    required this.messages,
  });
}

class SelectContactScreen extends StatefulWidget {
  const SelectContactScreen({super.key});

  @override
  State<SelectContactScreen> createState() => _SelectContactScreenState();
}

class _SelectContactScreenState extends State<SelectContactScreen> {
  final ContactService _contactService = ContactService();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Contact> _wrytteContacts = [];
  List<Contact> _nonWrytteContacts = [];
  List<Contact> _filteredWrytte = [];
  List<Contact> _filteredNonWrytte = [];
  bool _isLoading = true;
  String _error = '';
  String? _openingContactId;
  double _searchBarProgress = 0.0;

  static const double _kSearchBarHeight = 60.0;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final progress = (offset / _kSearchBarHeight).clamp(0.0, 1.0);
    if ((progress - _searchBarProgress).abs() > 0.005) {
      setState(() => _searchBarProgress = progress);
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _applyContactFilter(query);
    });
  }

  Future<void> _loadContacts() async {
    try {
      if (mounted) {
        setState(() {
          _isLoading = _wrytteContacts.isEmpty && _nonWrytteContacts.isEmpty;
          _error = '';
        });
      }

      final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
      if (currentUserId.trim().isEmpty) {
        if (mounted) {
          setState(() {
            _wrytteContacts = [];
            _nonWrytteContacts = [];
            _filteredWrytte = [];
            _filteredNonWrytte = [];
            _isLoading = false;
          });
        }
        return;
      }

      final immediateContacts = await _loadImmediateContacts(currentUserId);
      if (mounted) {
        setState(() {
          _setContacts(immediateContacts);
          _isLoading = false;
        });
      }
      unawaited(_refreshContactsInBackground(currentUserId));
    } catch (e) {
      debugPrint('[SelectContactScreen] contact load failed: $e');
      setState(() {
        _error = '';
        _isLoading = false;
      });
    }
  }

  Future<List<Contact>> _loadImmediateContacts(String ownerUserId) async {
    final saved = await ContactLocalDb.loadSavedContacts(
      ownerUserId: ownerUserId,
    );
    if (saved.isNotEmpty) return ContactAvatarSanitizer.sanitizeAll(saved);

    final cached = await ContactLocalDb.loadContacts(ownerUserId: ownerUserId);
    if (cached.isNotEmpty) return ContactAvatarSanitizer.sanitizeAll(cached);

    return const [];
  }

  Future<void> _refreshContactsInBackground(String currentUserId) async {
    try {
      final matrixContacts = await _contactService.getMatrixContacts(
        currentUserId,
      );
      if (matrixContacts.isEmpty || !mounted) return;
      final cleanContacts = ContactAvatarSanitizer.sanitizeAll(matrixContacts);

      await ContactLocalDb.saveContacts(
        cleanContacts,
        ownerUserId: currentUserId,
      );

      if (mounted) {
        setState(() {
          _setContacts(cleanContacts);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[SelectContactScreen] contact refresh failed: $e');
    }
  }

  void _setContacts(List<Contact> contacts) {
    final cleanContacts = ContactAvatarSanitizer.sanitizeAll(contacts);
    _wrytteContacts = cleanContacts.where((c) => c.isOnWrytte).toList();
    _nonWrytteContacts = cleanContacts.where((c) => !c.isOnWrytte).toList();
    _applyContactFilter(_searchController.text.toLowerCase());
  }

  void _applyContactFilter(String query) {
    _filteredWrytte =
        _wrytteContacts
            .where((c) => c.formattedName.toLowerCase().contains(query))
            .toList();
    _filteredNonWrytte =
        _nonWrytteContacts
            .where((c) => c.formattedName.toLowerCase().contains(query))
            .toList();
  }

  String _generateConversationId(String id1, String id2) {
    final ids = [_conversationKey(id1), _conversationKey(id2)]..sort();
    return 'si_${ids[0]}_${ids[1]}';
  }

  String _conversationKey(String value) {
    final trimmed = value.trim();
    final localpart =
        trimmed.startsWith('@') && trimmed.contains(':')
            ? trimmed.substring(1, trimmed.indexOf(':'))
            : trimmed;
    return localpart.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
  }

  void _navigateToChatScreen(Contact contact) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final receiverId = contact.wrytteUserId;
    if (receiverId == null || receiverId.isEmpty) return;
    if (_openingContactId != null) return;

    _openingContactId = receiverId;
    final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
    if (_conversationKey(receiverId) == _conversationKey(currentUserId)) {
      debugPrint(
        '[SelectContactScreen] refused self contact open: $receiverId',
      );
      _openingContactId = null;
      return;
    }
    try {
      final chatOpenData = await _resolveLocalChatOpenData(
        currentUserId: currentUserId,
        contact: contact,
      );
      unawaited(
        _resolveMatrixRoomId(
          currentUserId: currentUserId,
          receiverId: receiverId,
          localConversationId: chatOpenData.conversationId,
          contact: contact,
        ),
      );

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder:
              (_, __, ___) => ChatScreen(
                conversationId: chatOpenData.conversationId,
                receiverId: receiverId,
                currentUserId: currentUserId,
                title: contact.formattedName,
                avatarUrl: contact.avatarUrl,
                initialMessages: chatOpenData.messages,
                conversationKind: ConversationKind.direct,
              ),
          transitionsBuilder: (_, animation, __, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
        ),
      );
    } catch (e) {
      debugPrint('[SelectContactScreen] open chat failed: $e');
      if (mounted) {
        setState(() => _openingContactId = null);
      }
    }
  }

  Future<_ContactChatOpenData> _resolveLocalChatOpenData({
    required String currentUserId,
    required Contact contact,
  }) async {
    final receiverId = contact.wrytteUserId ?? '';
    final localConversationId = _generateConversationId(
      currentUserId,
      receiverId,
    );
    final candidateIds = <String>{localConversationId};

    final directId = await ChatLocalDb.instance.findDirectConversationId(
      selfUserId: currentUserId,
      otherUserId: receiverId,
    );
    if (directId != null && directId.isNotEmpty) {
      candidateIds.add(directId);
    }

    final receiverKeys = <String>{
      _conversationKey(receiverId),
      _conversationKey(contact.primaryPhone),
      for (final phone in contact.phones) _conversationKey(phone),
    }..removeWhere((key) => key.isEmpty);
    final selfKey = _conversationKey(currentUserId);

    final messageConversationIds = await ChatLocalDb.instance
        .findConversationIdsByMessageIdentity(
          userIds: [receiverId],
          phones: [contact.primaryPhone, ...contact.phones],
        );
    candidateIds.addAll(messageConversationIds);

    final conversations = await ChatLocalDb.instance.loadConversations();
    for (final conversation in conversations) {
      final otherKey = _conversationKey(conversation.otherUserId);
      final participantKeys =
          conversation.participants.map(_conversationKey).toSet();
      final matchesReceiver =
          receiverKeys.contains(otherKey) ||
          participantKeys.any(receiverKeys.contains);
      final matchesSelf = selfKey.isEmpty || participantKeys.contains(selfKey);
      if (matchesReceiver && (matchesSelf || conversation.id.startsWith('!'))) {
        candidateIds.add(conversation.id);
      }
    }

    // Prefer the real Matrix room when one is known. This ensures the chat
    // screen loads that room's clear-for-me marker instead of opening through
    // the synthetic `si_...` contact conversation key.
    var selectedConversationId =
        directId?.trim().isNotEmpty == true && directId!.startsWith('!')
        ? directId
        : localConversationId;
    if (!selectedConversationId.startsWith('!')) {
      final roomCandidate = candidateIds.firstWhere(
        (id) => id.startsWith('!'),
        orElse: () => '',
      );
      if (roomCandidate.isNotEmpty) selectedConversationId = roomCandidate;
    }
    var selectedMessages = const <ChatMessage>[];
    DateTime? selectedLatest;

    for (final candidateId in candidateIds) {
      final messages = await ChatService().loadCachedMessages(candidateId);
      final latest = messages.isEmpty ? null : messages.last.timestamp;
      final shouldSelect =
          messages.isNotEmpty && selectedMessages.isEmpty ||
          messages.isNotEmpty &&
              candidateId.startsWith('!') &&
              !selectedConversationId.startsWith('!') ||
          latest != null &&
              (selectedLatest == null || latest.isAfter(selectedLatest));
      if (shouldSelect) {
        selectedConversationId = candidateId;
        selectedMessages = messages;
        selectedLatest = latest;
      }
    }

    return _ContactChatOpenData(
      conversationId: selectedConversationId,
      messages: selectedMessages,
    );
  }

  Future<String?> _resolveMatrixRoomId({
    required String currentUserId,
    required String receiverId,
    required String localConversationId,
    required Contact contact,
  }) async {
    if (receiverId.trim().isEmpty) return null;
    if (_conversationKey(receiverId) == _conversationKey(currentUserId)) {
      debugPrint('[SelectContactScreen] refused self direct chat: $receiverId');
      return null;
    }
    if (localConversationId.startsWith('!')) return localConversationId;

    try {
      final chat = ChatService();
      await chat.connect();
      final existingRoomId = await chat.findMatrixConversationId(receiverId);
      final roomId =
          existingRoomId != null && existingRoomId.isNotEmpty
              ? existingRoomId
              : await chat.getMatrixConversationId(receiverId);
      if (roomId == null || roomId.isEmpty) return null;

      await ChatLocalDb.instance.migrateConversationId(
        oldConversationId: localConversationId,
        roomConversation: ChatConversation(
          id: roomId,
          participants: [currentUserId, receiverId],
          otherUserId: receiverId,
          lastMessage: '',
          lastMessageSenderId: '',
          lastMessageTime: DateTime.now(),
          unreadCount: 0,
          otherUserName: contact.formattedName,
          otherUserAvatar: contact.avatarUrl,
        ),
      );
      return roomId;
    } catch (e) {
      debugPrint('[SelectContactScreen] Matrix room resolve failed: $e');
      return null;
    }
  }

  Map<String, List<Contact>> _groupByAlphabet(List<Contact> contacts) {
    final Map<String, List<Contact>> grouped = {};
    for (final contact in contacts) {
      final letter =
          contact.formattedName.isNotEmpty
              ? contact.formattedName[0].toUpperCase()
              : '#';
      grouped.putIfAbsent(letter, () => []).add(contact);
    }
    final keys = grouped.keys.toList()..sort();
    return Map.fromEntries(keys.map((k) => MapEntry(k, grouped[k]!)));
  }

  List<Widget> _buildContactSlivers() {
    if (_isLoading) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(
              child: Column(
                children: [
                  CircularProgressIndicator(color: Color(0xFF4DA3FF)),
                  SizedBox(height: 16),
                  Text(
                    'Finding your contacts on Wrytte...',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    if (_error.isNotEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Center(
              child: Text(
                'Error: $_error',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ),
        ),
      ];
    }

    if (_filteredWrytte.isEmpty && _filteredNonWrytte.isEmpty) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(
              child: Text(
                'No contacts found',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            ),
          ),
        ),
      ];
    }

    final slivers = <Widget>[];

    final wrytteGrouped = _groupByAlphabet(_filteredWrytte);
    for (final entry in wrytteGrouped.entries) {
      slivers.add(SliverToBoxAdapter(child: _sectionHeader(entry.key)));
      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => ContactItem(
              contact: entry.value[i],
              onTap: () => _navigateToChatScreen(entry.value[i]),
            ),
            childCount: entry.value.length,
          ),
        ),
      );
    }

    if (_filteredNonWrytte.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(child: _sectionHeader('Invite to Wrytte')),
      );
      final nonGrouped = _groupByAlphabet(_filteredNonWrytte);
      for (final entry in nonGrouped.entries) {
        slivers.add(SliverToBoxAdapter(child: _sectionHeader(entry.key)));
        slivers.add(
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => ContactItem(
                contact: entry.value[i],
                showInviteButton: true,
                onTap: () {},
              ),
              childCount: entry.value.length,
            ),
          ),
        );
      }
    }

    return slivers;
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double headerHeight =
        statusBarHeight + kToolbarHeight + _kSearchBarHeight + 8.0;

    final double searchBarOffset = _kSearchBarHeight * _searchBarProgress;
    final double gradientHeight = headerHeight - searchBarOffset;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: headerHeight)),
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      _actionItem(Icons.group_outlined, 'New group'),
                      _actionItem(Icons.person_add_outlined, 'New contact'),
                      _actionItem(Icons.campaign_outlined, 'Create channel'),
                    ],
                  ),
                ),
                ..._buildContactSlivers(),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: gradientHeight,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.6, 1.0],
                    colors: [
                      const Color(0xFF08090B).withValues(alpha: 0.95),
                      const Color(0xFF08090B).withValues(alpha: 0.75),
                      const Color(0xFF08090B).withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTopBar(statusBarHeight),
                Transform.translate(
                  offset: Offset(0, -searchBarOffset),
                  child: Opacity(
                    opacity: (1.0 - _searchBarProgress).clamp(0.0, 1.0),
                    child: SizedBox(
                      height: _kSearchBarHeight,
                      child: _buildSearchBar(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(double statusBarHeight) {
    return SizedBox(
      height: statusBarHeight + kToolbarHeight,
      child: Padding(
        padding: EdgeInsets.only(top: statusBarHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1013),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 20),
                ),
              ),
              const Expanded(
                child: Center(
                  child: Text(
                    'New chat',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 36),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF23262C),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              cursorColor: Colors.white,
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
            if (_searchController.text.isEmpty)
              IgnorePointer(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.search, color: Colors.grey, size: 18),
                    SizedBox(width: 6),
                    Text(
                      'Search',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _actionItem(IconData icon, String title) {
    return Column(
      children: [
        ListTile(
          leading: Icon(icon, color: const Color(0xFF4DA3FF), size: 28),
          title: Text(
            title,
            style: const TextStyle(color: Color(0xFF4DA3FF), fontSize: 18),
          ),
          onTap: () async {
            if (title == 'New contact') {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NewContactPage(token: ''),
                ),
              );

              // Reload so the newly saved contact appears immediately.
              if (result != null && mounted) {
                _loadContacts();
              }
            } else if (title == 'New group') {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NewGroupScreen()),
              );
            } else if (title == 'Create channel') {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NewGroupScreen(isChannel: true),
                ),
              );
            }
          },
        ),
        const Padding(
          padding: EdgeInsets.only(left: 72),
          child: Divider(height: 1, color: Color(0xFF2A2A2A)),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: const Color(0xFF1A1A1A),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.grey,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}
