import 'package:flutter/material.dart';
import 'package:wrytte/components/contact_components/contact_item.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';

import 'package:wrytte/services/contacts/contact_local_db.dart';

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
      _filteredWrytte =
          _wrytteContacts
              .where((c) => c.formattedName.toLowerCase().contains(query))
              .toList();
      _filteredNonWrytte =
          _nonWrytteContacts
              .where((c) => c.formattedName.toLowerCase().contains(query))
              .toList();
    });
  }

  Future<void> _loadContacts() async {
    try {
      setState(() {
        _isLoading = true;
        _error = '';
      });

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

      final localContacts = await ContactLocalDb.loadContacts(
        ownerUserId: currentUserId,
      );

      if (mounted && localContacts.isNotEmpty) {
        setState(() {
          _wrytteContacts = localContacts.where((c) => c.isOnWrytte).toList();
          _nonWrytteContacts =
              localContacts.where((c) => !c.isOnWrytte).toList();
          _filteredWrytte = _wrytteContacts;
          _filteredNonWrytte = _nonWrytteContacts;
          _isLoading = false;
        });
      }

      final matrixContacts = await _contactService.getMatrixContacts(
        currentUserId,
      );

      await ContactLocalDb.saveContacts(
        matrixContacts,
        ownerUserId: currentUserId,
      );

      if (mounted) {
        setState(() {
          _wrytteContacts = matrixContacts.where((c) => c.isOnWrytte).toList();
          _nonWrytteContacts =
              matrixContacts.where((c) => !c.isOnWrytte).toList();
          _filteredWrytte = _wrytteContacts;
          _filteredNonWrytte = _nonWrytteContacts;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[SelectContactScreen] contact refresh failed: $e');
      final message = e.toString();
      final isDirectoryLookupFailure =
          message.contains('User search error') ||
          message.contains('TimeoutException') ||
          message.contains('Wrytte contact search timed out') ||
          message.contains('ContactDirectoryUnavailable');
      setState(() {
        _error = isDirectoryLookupFailure ? '' : message;
        _isLoading = false;
      });
    }
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
    if (contact.wrytteUserId == null || contact.wrytteUserId!.isEmpty) return;

    final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
    final conversationId = _generateConversationId(
      currentUserId,
      contact.wrytteUserId!,
    );

    if (!mounted) return;
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => ChatScreen(
              conversationId: conversationId,
              receiverId: contact.wrytteUserId!,
              currentUserId: currentUserId,
              title: contact.formattedName,
            ),
      ),
    );
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

              // Reload so the newly saved Matrix contact appears immediately
              if (result != null && mounted) {
                _loadContacts();
              }
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
