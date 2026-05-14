import 'package:flutter/material.dart';
import 'package:wrytte/components/contact_components/firebase_new_chat_item.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';

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
      _filteredContacts = _allContacts
          .where((c) =>
              _sanitize(c.formattedName).toLowerCase().contains(query) ||
              c.primaryPhone.contains(query))
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

      if (currentUserId.isNotEmpty) {
        final firestoreContacts =
            await _contactService.getFirestoreContactsCached(currentUserId);

        firestoreContacts.sort((a, b) => a.formattedName
            .toLowerCase()
            .compareTo(b.formattedName.toLowerCase()));

        if (mounted) {
          setState(() {
            _allContacts = firestoreContacts;
            _filteredContacts = firestoreContacts;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }

      final wrytteContacts = await _contactService.getWrytteContactsOptimized();

      if (!mounted) return;

      final currentUserId2 =
          await AuthService.instance.getCurrentUserId() ?? '';
      final firestoreContacts =
          await _contactService.getFirestoreContacts(currentUserId2);

      final seenPhones = <String>{};
      final merged = <Contact>[];

      for (final c in wrytteContacts) {
        for (final p in c.phones) seenPhones.add(p);
        merged.add(c);
      }

      for (final c in firestoreContacts) {
        final alreadySeen = c.phones.any((p) => seenPhones.contains(p));
        if (!alreadySeen) {
          seenPhones.addAll(c.phones);
          merged.add(c);
        }
      }

      merged.sort((a, b) => a.formattedName
          .toLowerCase()
          .compareTo(b.formattedName.toLowerCase()));

      if (mounted) {
        setState(() {
          _allContacts = merged;
          _filteredContacts = merged;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _navigateToChat(Contact contact) async {
    final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
    if (currentUserId.isEmpty) return;

    // The Matrix userID is the phone number with the + prefix preserved.
    // wrytteUserId already stores it in this format when the contact was saved.
    // Fall back to primaryPhone as-is (which should include the + from E.164).
    final receiverId =
        (contact.wrytteUserId != null && contact.wrytteUserId!.isNotEmpty)
            ? contact.wrytteUserId!
            : contact.primaryPhone;

    if (receiverId.isEmpty) return;

    // Derive the Matrix direct room between two users
    final normalizedReceiverId = receiverId.replaceAll(RegExp(r'[^\d]'), '');
    final ids = [currentUserId, normalizedReceiverId]..sort();
    final conversationId = 'si_${ids[0]}_${ids[1]}';

    if (!mounted) return;
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          conversationId: conversationId,
          receiverId: normalizedReceiverId,
          currentUserId: currentUserId,
          title: _sanitize(contact.formattedName),
          avatarUrl: contact.avatarUrl,
        ),
      ),
    );
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
            (_, i) => FirebaseNewChatItem(
              user: UserProfile(
                uid: entry.value[i].wrytteUserId ?? '',
                name: _sanitize(entry.value[i].formattedName),
                username: _sanitize(entry.value[i].formattedName),
                phone: entry.value[i].primaryPhone,
                bio: '',
                profileImage: entry.value[i].avatarUrl ?? '',
                links: const [],
              ),
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
                      const Color(0xFF08090B).withOpacity(0.95),
                      const Color(0xFF08090B).withOpacity(0.75),
                      const Color(0xFF08090B).withOpacity(0.0),
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
                  child:
                      const Icon(Icons.close, color: Colors.white, size: 20),
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
                  builder: (_) => FutureBuilder<String?>(
                    future: AuthService.instance.getToken(),
                    builder: (context, snapshot) {
                      return NewContactPage(token: snapshot.data ?? '');
                    },
                  ),
                ),
              ).then((_) => _loadMyContacts());
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
