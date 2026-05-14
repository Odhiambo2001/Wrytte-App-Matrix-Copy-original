import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/screens/chats/widgets/conversation_tile.dart';
import 'package:wrytte/ui/screens/chats/widgets/mini_chat_window.dart';
import 'package:wrytte/ui/screens/chats/widgets/top_bar.dart';
import 'package:wrytte/ui/screens/firebase_new_chat_screen.dart';
import 'widgets/search_bar.dart' as local_widgets;
import 'widgets/tab_bar_section.dart';

// =============================================================================
//  ConversationsScreen
//
//  Name resolution priority (highest → lowest):
//    1. Saved contacts  — Firestore /users where savedBy == currentUserId.
//       These have the human display names the user typed (e.g. "John Doe").
//       sign-up, not the local user's contact alias.
//    2. Firestore /users doc by document ID (phone digits) — session cache.
//    3. Raw otherUserId — last resort fallback.
// =============================================================================

const double _kSearchBarHeight = 60.0;
const double _kTabBarHeight    = 56.0;

class ConversationsScreen extends StatefulWidget {
  final Function(int)? onUnreadCountUpdated;
  final String currentUserId;

  const ConversationsScreen({
    super.key,
    this.onUnreadCountUpdated,
    this.currentUserId = '',
  });

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  final ChatService _chat = ChatService();

  List<ChatConversation> _conversations = [];

  String _currentUserId = '';
  bool   _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  StreamSubscription<List<ChatConversation>>? _convSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  final ScrollController _scrollCtrl = ScrollController();
  double _searchBarProgress = 0.0;

  // ── Priority 1: saved contact names keyed by phone digits ─────────────────
  // e.g. "254700239641" → "John Doe"
  final Map<String, String>  _contactNameCache   = {};
  final Map<String, String?> _contactAvatarCache = {};

  // ── Priority 2: Firestore /users doc fallback (session-only) ─────────────
  // Key: phone digits (same format as _contactNameCache)
  final Map<String, String>  _nameCache   = {};
  final Map<String, String?> _avatarCache = {};

  // ===========================================================================
  //  LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    Future.microtask(_initialize);
  }

  @override
  void dispose() {
    _convSub?.cancel();
    _connectivitySub?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final progress =
        (_scrollCtrl.offset / _kSearchBarHeight).clamp(0.0, 1.0);
    if ((progress - _searchBarProgress).abs() > 0.005) {
      setState(() => _searchBarProgress = progress);
    }
  }

  // ===========================================================================
  //  INITIALIZE
  // ===========================================================================

  Future<void> _initialize() async {
    _currentUserId = widget.currentUserId.isNotEmpty
        ? widget.currentUserId
        : await AuthService.instance.getCurrentUserId() ?? '';

    if (_currentUserId.isEmpty) return;

    // Load saved contacts FIRST so names are ready before conversations render
    await _loadSavedContacts();

    // Pre-warm contact cache for FirebaseNewChatScreen
    ContactService.preloadContacts(_currentUserId, ContactService());

    // Connect ChatService (idempotent)
    await _chat.connect();

    // Subscribe to Matrix conversation stream
    _convSub = _chat.conversationsStream.listen((incoming) async {
      final enriched = await _enrichNames(incoming);
      if (!mounted) return;
      setState(() => _conversations = enriched);
      _notifyUnread(_conversations);
    });

    // Retry enrichment when connectivity is restored
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet) _retryEnrichment();
    });
  }

  // ===========================================================================
  //  LOAD SAVED CONTACTS
  //  Reads contacts the user explicitly saved (savedBy == currentUserId).
  //  Populates _contactNameCache keyed by phone digits for O(1) lookup.
  // ===========================================================================

  Future<void> _loadSavedContacts() async {
    try {
      // Always fetch fresh from Firestore — don't rely on stale static cache
      final contacts = await ContactService()
          .getFirestoreContactsCached(_currentUserId);

      // Clear existing cache before reloading so removed/renamed contacts
      // don't linger
      _contactNameCache.clear();
      _contactAvatarCache.clear();

      for (final c in contacts) {
        final name = c.displayName ?? '';
        // Only cache real human names — skip if it looks like a phone number
        if (name.isEmpty || _looksLikePhone(name)) continue;

        for (final phone in c.phones) {
          // Strip everything except digits so we can match with/without '+'
          final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
          if (digits.length >= 7) {
            _contactNameCache[digits]   = name;
            _contactAvatarCache[digits] = c.avatarUrl?.isNotEmpty == true
                ? c.avatarUrl
                : null;
          }
        }
      }

      debugPrint(
          '[ConversationsScreen] loaded ${_contactNameCache.length} saved contact names');
    } catch (e) {
      debugPrint('[ConversationsScreen] _loadSavedContacts error: $e');
    }
  }

  // ===========================================================================
  //  ENRICHMENT
  //
  //  Pass 1 — saved contact names (ALWAYS applied, even over Matrix displayname).
  //    Matrix displayname is set at registration, not the
  //    local user's chosen contact name.
  //
  //  Pass 2 — Firestore /users doc fallback.
  //    Only runs for conversations where pass 1 found no saved-contact name
  //    AND the current name is still a phone number or missing entirely.
  // ===========================================================================

  Future<List<ChatConversation>> _enrichNames(
    List<ChatConversation> convs,
  ) async {
    // ── Pass 1: saved contact names always win ─────────────────────────────
    final afterSavedContacts = convs.map((c) {
      final digits = c.otherUserId.replaceAll(RegExp(r'[^\d]'), '');
      if (_contactNameCache.containsKey(digits)) {
        return c.copyWith(
          otherUserName:   _contactNameCache[digits],
          otherUserAvatar: _contactAvatarCache[digits],
        );
      }
      return c;
    }).toList();

    // ── Pass 2: Firestore fallback for still-unnamed conversations ─────────
    final unknownDigits = afterSavedContacts
        .where((c) => _needsFirestoreLookup(c))
        .map((c) => c.otherUserId.replaceAll(RegExp(r'[^\d]'), ''))
        .where((d) => d.isNotEmpty && !_nameCache.containsKey(d))
        .toSet()
        .toList();

    if (unknownDigits.isNotEmpty) {
      const chunk = 10;
      for (int i = 0; i < unknownDigits.length; i += chunk) {
        final slice = unknownDigits.sublist(
            i, (i + chunk).clamp(0, unknownDigits.length));

        try {
          final snap = await FirebaseFirestore.instance
              .collection('users')
              .where(FieldPath.documentId, whereIn: slice)
              .get();

          for (final doc in snap.docs) {
            final data   = doc.data();
            final digits = doc.id;

            // Prefer saved-contact name if somehow we have one
            if (_contactNameCache.containsKey(digits)) {
              _nameCache[digits]   = _contactNameCache[digits]!;
              _avatarCache[digits] = _contactAvatarCache[digits];
            } else {
              _nameCache[digits]   = _resolveName(data);
              final avatar = data['profileImage']?.toString() ??
                  data['photoUrl']?.toString() ??
                  data['avatarUrl']?.toString();
              _avatarCache[digits] =
                  avatar?.isNotEmpty == true ? avatar : null;
            }
          }
        } catch (e) {
          debugPrint('[ConversationsScreen] enrichment error: $e');
        }
      }
    }

    return _applyFallbackCache(afterSavedContacts);
  }

  /// Returns true when this conversation still needs a Firestore lookup.
  bool _needsFirestoreLookup(ChatConversation c) {
    final digits = c.otherUserId.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return false;
    // Already resolved by saved contacts
    if (_contactNameCache.containsKey(digits)) return false;
    // No name at all
    if (c.otherUserName == null) return true;
    // Name is a phone number — needs a better name from Firestore
    return _looksLikePhone(c.otherUserName!);
  }

  /// Applies the Firestore fallback cache to conversations that:
  ///   - Were NOT resolved by saved contacts (pass 1)
  ///   - Have a usable non-phone name in the fallback cache
  List<ChatConversation> _applyFallbackCache(List<ChatConversation> convs) {
    return convs.map((c) {
      final digits = c.otherUserId.replaceAll(RegExp(r'[^\d]'), '');
      // Don't overwrite a name that came from saved contacts
      if (_contactNameCache.containsKey(digits)) return c;
      // Apply Firestore fallback if we have a real name for this number
      if (_nameCache.containsKey(digits)) {
        final cached = _nameCache[digits]!;
        if (!_looksLikePhone(cached)) {
          return c.copyWith(
            otherUserName:   cached,
            otherUserAvatar: _avatarCache[digits],
          );
        }
      }
      return c;
    }).toList();
  }

  /// Returns true when [value] is a raw phone number rather than a
  /// human display name.
  bool _looksLikePhone(String value) {
    final s = value.replaceAll(RegExp(r'[\s\-()]'), '');
    return s.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(s);
  }

  String _resolveName(Map<String, dynamic> data) {
    final name = data['name']?.toString() ?? '';
    if (name.isNotEmpty && !_looksLikePhone(name)) return name;

    final username = data['username']?.toString() ?? '';
    if (username.isNotEmpty && !_looksLikePhone(username)) return username;

    final phone = data['phone']?.toString() ?? '';
    if (phone.isNotEmpty) return phone;

    return data['uid']?.toString() ?? 'Unknown';
  }

  Future<void> _retryEnrichment() async {
    await _loadSavedContacts();
    final enriched = await _enrichNames(_conversations);
    if (mounted) setState(() => _conversations = enriched);
  }

  // ===========================================================================
  //  HELPERS
  // ===========================================================================

  void _notifyUnread(List<ChatConversation> convs) {
    final total = convs.fold(0, (sum, c) => sum + c.unreadCount);
    widget.onUnreadCountUpdated?.call(total);
  }

  String _sanitize(String s) => String.fromCharCodes(
      s.runes.where((r) => r <= 0xD7FF || r >= 0xE000));

  void _enterSelection() =>
      setState(() { _isSelectionMode = true; _selectedIds.clear(); });
  void _exitSelection() =>
      setState(() { _isSelectionMode = false; _selectedIds.clear(); });
  void _toggleSelection(String id) => setState(() {
    if (_selectedIds.contains(id)) _selectedIds.remove(id);
    else _selectedIds.add(id);
  });

  void _onPin()        => debugPrint('Pin: ${_selectedIds.toList()}');
  void _onMarkAsRead() => debugPrint('MarkAsRead: ${_selectedIds.toList()}');
  void _onMute()       => debugPrint('Mute: ${_selectedIds.toList()}');
  void _onArchive()    => debugPrint('Archive: ${_selectedIds.toList()}');
  void _onDelete()     => debugPrint('Delete: ${_selectedIds.toList()}');

  String _formatTime(DateTime dt) {
    final now   = DateTime.now();
    final local = dt.toLocal();
    final isToday = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (isToday) {
      final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m ${local.hour >= 12 ? 'PM' : 'AM'}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (local.year == yesterday.year &&
        local.month == yesterday.month &&
        local.day == yesterday.day) return 'Yesterday';
    if (now.difference(local).inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    }
    return '${local.day}/${local.month}/${local.year}';
  }

  // ===========================================================================
  //  CONVERSATION TILE
  // ===========================================================================

  Widget _buildTile(ChatConversation conv) {
    final rawName  = conv.otherUserName ?? conv.otherUserId;
    final name     = _sanitize(rawName);
    final avatar   = conv.otherUserAvatar;
    final selected = _selectedIds.contains(conv.id);

    return ConversationTile(
      name: name,
      lastMessage: conv.lastMessage.isEmpty
          ? 'Say hello! 👋'
          : _sanitize(conv.lastMessage),
      time: _formatTime(conv.lastMessageTime),
      avatarUrl: avatar,
      unreadCount: conv.unreadCount,
      isSelectionMode: _isSelectionMode,
      isSelected: selected,
      onSelectionToggle: () => _toggleSelection(conv.id),
      onLongPress: () {
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Preview',
          barrierColor: Colors.transparent,
          pageBuilder: (_, __, ___) => MiniChatPreview(
            conversationId: conv.id,
            name: name,
            avatarUrl: avatar,
            currentUserId: _currentUserId,
            receiverId: conv.otherUserId,
          ),
        );
      },
      onTap: () async {
        if (_isSelectionMode) {
          _toggleSelection(conv.id);
          return;
        }

        // Mark as read via Matrix
        await _chat.markConversationAsRead(conv.id);

        if (mounted) {
          setState(() {
            _conversations = _conversations
                .map((c) => c.id == conv.id
                    ? c.copyWith(unreadCount: 0)
                    : c)
                .toList();
          });
          _notifyUnread(_conversations);
        }

        if (!mounted) return;

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              conversationId: conv.id,
              receiverId:     conv.otherUserId,
              currentUserId:  _currentUserId,
              title:          name,
              avatarUrl:      avatar,
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  //  BUILD
  // ===========================================================================

  Widget _buildChatsTab(double topPadding) {
    if (_conversations.isEmpty) {
      return ListView(
        controller: _scrollCtrl,
        padding: EdgeInsets.only(top: topPadding, bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              children: [
                Icon(Icons.chat_bubble_outline_rounded,
                    size: 64, color: Colors.white.withOpacity(0.12)),
                const SizedBox(height: 16),
                Text('No conversations yet',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.35),
                        fontSize: 16,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Text('Tap the pencil icon to start a new chat',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.2), fontSize: 13)),
              ],
            ),
          ),
        ],
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF4DA3FF),
      backgroundColor: Colors.transparent,
      onRefresh: () async {
        await _loadSavedContacts();
        await _chat.fetchConversations();
        await _retryEnrichment();
      },
      child: ListView.builder(
        controller: _scrollCtrl,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.only(top: topPadding, bottom: 120),
        itemCount: _conversations.length,
        itemBuilder: (_, i) => _buildTile(_conversations[i]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarH  = MediaQuery.of(context).padding.top;
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double headerH = statusBarH +
        kToolbarHeight +
        _kSearchBarHeight +
        _kTabBarHeight +
        8.0;

    final double searchBarOffset = _kSearchBarHeight * _searchBarProgress;
    final double gradientH = headerH - searchBarOffset;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      extendBodyBehindAppBar: true,
      floatingActionButton: _isSelectionMode
          ? null
          : Padding(
              padding: EdgeInsets.only(bottom: bottomInset + 80.0),
              child: FloatingActionButton(
                // ── FIX: await the push so we can reload contacts on return ──
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const FirebaseNewChatScreen(),
                    ),
                  );
                  // Reload contacts fresh (static cache was busted by
                  // ContactService.invalidateFirestoreCache() on save)
                  // then re-enrich so the new contact name shows immediately.
                  if (mounted) {
                    await _loadSavedContacts();
                    final enriched = await _enrichNames(_conversations);
                    if (mounted) {
                      setState(() => _conversations = enriched);
                    }
                  }
                },
                backgroundColor: const Color(0xFF4DA3FF),
                child: const Icon(Icons.edit_square, color: Colors.black),
              ),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: DefaultTabController(
        length: 3,
        child: Stack(
          children: [
            // ── Tab content ──────────────────────────────────────────────
            Positioned.fill(
              child: TabBarView(
                children: [
                  _buildChatsTab(headerH),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: headerH),
                      child: const Text('Channels coming soon',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: headerH),
                      child: const Text('Groups coming soon',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
                ],
              ),
            ),

            // ── Gradient ─────────────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              height: gradientH,
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

            // ── Sticky header ─────────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TopBar(
                    isSelectionMode: _isSelectionMode,
                    selectedCount: _selectedIds.length,
                    onEditPressed: _enterSelection,
                    onSelectionClose: _exitSelection,
                    onMarkAsRead: _onMarkAsRead,
                    onPin: _onPin,
                    onMute: _onMute,
                    onArchive: _onArchive,
                    onDelete: _onDelete,
                  ),
                  Transform.translate(
                    offset: Offset(0, -searchBarOffset),
                    child: Opacity(
                      opacity: (1.0 - _searchBarProgress).clamp(0.0, 1.0),
                      child: SizedBox(
                        height: _kSearchBarHeight,
                        child: local_widgets.SearchBar(),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(0, -searchBarOffset),
                    child: const TabBarSection(),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
