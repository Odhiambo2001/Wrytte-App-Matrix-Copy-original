import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wrytte/components/contact_components/contact_item.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';
import 'package:wrytte/ui/screens/new_group_screen.dart';

class FirebaseNewChatScreen extends StatefulWidget {
  const FirebaseNewChatScreen({super.key});

  @override
  State<FirebaseNewChatScreen> createState() => _FirebaseNewChatScreenState();
}

class _FirebaseNewChatScreenState extends State<FirebaseNewChatScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ContactService _contactService = ContactService();

  List<Contact> _allContacts = [];
  List<Contact> _filteredContacts = [];
  bool _isLoading = false;
  String _error = '';
  double _searchBarProgress = 0.0;

  static const double _kSearchBarHeight = 60.0;

  @override
  void initState() {
    super.initState();
    _loadMyContacts();
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
      _filteredContacts =
          _allContacts
              .where(
                (c) =>
                    _sanitize(c.formattedName).toLowerCase().contains(query) ||
                    c.primaryPhone.contains(query),
              )
              .toList();
    });
  }

  String _sanitize(String s) {
    return String.fromCharCodes(
      s.runes.where((r) => r <= 0xD7FF || r >= 0xE000),
    );
  }

  Future<void> _loadMyContacts() async {
    try {
      final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
      if (currentUserId.isEmpty) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final immediateContacts = await _loadImmediateContacts(currentUserId);
      if (mounted) {
        _showContacts(immediateContacts);
      }
      unawaited(_refreshContactsInBackground(currentUserId));
    } catch (e) {
      debugPrint('[FirebaseNewChatScreen] contact load failed: $e');
      if (mounted) {
        setState(() {
          _error = '';
          _isLoading = false;
        });
      }
    }
  }

  Future<List<Contact>> _loadImmediateContacts(String ownerUserId) async {
    final saved = await ContactLocalDb.loadSavedContacts(
      ownerUserId: ownerUserId,
    );
    if (saved.isNotEmpty) return saved;

    final cached = await ContactLocalDb.loadContacts(ownerUserId: ownerUserId);
    final wrytteContacts =
        cached.where((contact) => contact.isOnWrytte).toList();
    if (wrytteContacts.isNotEmpty) return wrytteContacts;

    return const [];
  }

  Future<void> _refreshContactsInBackground(String ownerUserId) async {
    try {
      final contacts = await _contactService.getMatrixContactsCached(
        ownerUserId,
      );
      if (contacts.isEmpty || !mounted) return;
      _showContacts(contacts);
    } catch (e) {
      debugPrint('[FirebaseNewChatScreen] contact refresh failed: $e');
    }
  }

  void _showContacts(List<Contact> contacts) {
    final sorted = List<Contact>.from(contacts)..sort(
      (a, b) => a.formattedName.toLowerCase().compareTo(
        b.formattedName.toLowerCase(),
      ),
    );
    debugPrint(
      '[FirebaseNewChatScreen] showing contacts=${sorted.length} '
      'summary="${sorted.map((c) => '${c.formattedName}:avatar=${(c.avatarUrl?.trim().isNotEmpty ?? false)}').join('|')}"',
    );
    setState(() {
      _allContacts = sorted;
      _filteredContacts =
          _searchController.text.trim().isEmpty
              ? sorted
              : sorted
                  .where(
                    (c) =>
                        _sanitize(c.formattedName).toLowerCase().contains(
                          _searchController.text.toLowerCase(),
                        ) ||
                        c.primaryPhone.contains(_searchController.text),
                  )
                  .toList();
      _error = '';
      _isLoading = false;
    });
  }

  Future<void> _navigateToChat(Contact contact) async {
    final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
    if (currentUserId.isEmpty) return;

    // Use the real Wrytte/Matrix identity for routing. Do not strip it down
    // to digits; Matrix invites must target the receiver's actual user ID.
    final receiverId =
        (contact.wrytteUserId != null && contact.wrytteUserId!.isNotEmpty)
            ? contact.wrytteUserId!
            : contact.primaryPhone;

    if (receiverId.isEmpty) return;
    if (_conversationKey(receiverId) == _conversationKey(currentUserId)) {
      debugPrint(
        '[FirebaseNewChatScreen] refused self contact open: $receiverId',
      );
      return;
    }

    final ids = [_conversationKey(currentUserId), _conversationKey(receiverId)]
      ..sort();
    var conversationId = 'si_${ids[0]}_${ids[1]}';
    var initialMessages = await ChatService().loadCachedMessages(
      conversationId,
    );

    final localRoomId = await _findLocalRoomConversationId(
      currentUserId: currentUserId,
      receiverId: receiverId,
      contact: contact,
    );
    if (localRoomId != null && localRoomId.isNotEmpty) {
      final roomMessages = await ChatService().loadCachedMessages(localRoomId);
      if (roomMessages.isNotEmpty) {
        conversationId = localRoomId;
        initialMessages = roomMessages;
      }
    }

    if (contact.wrytteUserId != null &&
        contact.wrytteUserId!.isNotEmpty &&
        _conversationKey(receiverId) != _conversationKey(currentUserId)) {
      try {
        final chat = ChatService();
        await chat.connect();
        final existingRoomId = await chat.findMatrixConversationId(receiverId);
        final roomId =
            existingRoomId != null && existingRoomId.isNotEmpty
                ? existingRoomId
                : await chat.getMatrixConversationId(receiverId);
        if (roomId != null && roomId.isNotEmpty) {
          if (!conversationId.startsWith('!')) {
            await ChatLocalDb.instance.migrateConversationId(
              oldConversationId: conversationId,
              roomConversation: ChatConversation(
                id: roomId,
                participants: [currentUserId, receiverId],
                otherUserId: receiverId,
                lastMessage: '',
                lastMessageSenderId: '',
                lastMessageTime: DateTime.now(),
                unreadCount: 0,
                otherUserName: _sanitize(contact.formattedName),
                otherUserAvatar: contact.avatarUrl,
                conversationKind: ConversationKind.direct,
              ),
            );
          }
          conversationId = roomId;
          await chat.fetchMessageHistory(conversationID: roomId);
          initialMessages = await chat.loadCachedMessages(roomId);
        }
      } catch (e) {
        debugPrint('[FirebaseNewChatScreen] Matrix room resolve failed: $e');
      }
    }

    if (!mounted) return;
    Navigator.pop(context);
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder:
            (_, __, ___) => ChatScreen(
              conversationId: conversationId,
              receiverId: receiverId,
              currentUserId: currentUserId,
              title: _sanitize(contact.formattedName),
              avatarUrl: contact.avatarUrl,
              initialMessages: initialMessages,
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
  }

  Future<String?> _findLocalRoomConversationId({
    required String currentUserId,
    required String receiverId,
    required Contact contact,
  }) async {
    final directId = await ChatLocalDb.instance.findDirectConversationId(
      selfUserId: currentUserId,
      otherUserId: receiverId,
    );
    if (directId != null && directId.startsWith('!')) return directId;

    final ids = await ChatLocalDb.instance.findConversationIdsByMessageIdentity(
      userIds: [receiverId],
      phones: [contact.primaryPhone, ...contact.phones],
    );
    for (final id in ids) {
      if (id.startsWith('!')) return id;
    }
    return null;
  }

  String _conversationKey(String value) {
    final trimmed = value.trim();
    final localpart =
        trimmed.startsWith('@') && trimmed.contains(':')
            ? trimmed.substring(1, trimmed.indexOf(':'))
            : trimmed;
    return localpart.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
  }

  Map<String, List<Contact>> _groupByAlphabet(List<Contact> contacts) {
    final Map<String, List<Contact>> grouped = {};
    for (final contact in contacts) {
      final sanitized = _sanitize(contact.formattedName);
      final letter = sanitized.isNotEmpty ? sanitized[0].toUpperCase() : '#';
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
                    'Loading your contacts...',
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

    if (_filteredContacts.isEmpty) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(
              child: Text(
                'No contacts yet. Add one using New contact.',
                style: TextStyle(color: Colors.grey, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ];
    }

    final slivers = <Widget>[];
    final grouped = _groupByAlphabet(_filteredContacts);

    for (final entry in grouped.entries) {
      slivers.add(SliverToBoxAdapter(child: _sectionHeader(entry.key)));
      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => ContactItem(
              contact: entry.value[i],
              onTap: () => _navigateToChat(entry.value[i]),
            ),
            childCount: entry.value.length,
          ),
        ),
      );
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
                      _actionItem(Icons.campaign_outlined, 'New channel'),
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
          onTap: () {
            if (title == 'New contact') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) => FutureBuilder<String?>(
                        future: AuthService.instance.getToken(),
                        builder: (context, snapshot) {
                          return NewContactPage(token: snapshot.data ?? '');
                        },
                      ),
                ),
              ).then((_) => _loadMyContacts());
            } else if (title == 'New group') {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NewGroupScreen()),
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
