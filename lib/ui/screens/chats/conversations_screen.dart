import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
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
//    1. Saved contacts in Matrix account data.
//    2. Raw Matrix room/user data.
// =============================================================================

const double _kSearchBarHeight = 60.0;
const double _kTabBarHeight = 56.0;

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
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  StreamSubscription<List<ChatConversation>>? _convSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  final ScrollController _scrollCtrl = ScrollController();
  double _searchBarProgress = 0.0;

  // ── Priority 1: saved contact names keyed by phone, Matrix ID, and localpart.
  final Map<String, String> _contactNameCache = {};
  final Map<String, String?> _contactAvatarCache = {};

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
    final progress = (_scrollCtrl.offset / _kSearchBarHeight).clamp(0.0, 1.0);
    if ((progress - _searchBarProgress).abs() > 0.005) {
      setState(() => _searchBarProgress = progress);
    }
  }

  // ===========================================================================
  //  INITIALIZE
  // ===========================================================================

  Future<void> _initialize() async {
    _currentUserId =
        widget.currentUserId.isNotEmpty
            ? widget.currentUserId
            : await AuthService.instance.getCurrentUserId() ?? '';

    if (_currentUserId.isEmpty) return;

    // Load saved contacts FIRST so names are ready before conversations render
    await _loadSavedContacts();
    await _loadLocalConversations();

    // Pre-warm contact cache for FirebaseNewChatScreen
    ContactService.preloadContacts(_currentUserId, ContactService());

    // Connect ChatService (idempotent)
    try {
      await _chat.connect();
      await _chat.fetchConversations();
    } catch (e) {
      debugPrint('[ConversationsScreen] chat connect skipped: $e');
    }

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

  Future<void> _loadLocalConversations() async {
    try {
      final local = await ChatLocalDb.instance.loadConversations();
      final enriched = await _enrichNames(local);
      if (!mounted) return;
      setState(() => _conversations = enriched);
      _notifyUnread(_conversations);
    } catch (e) {
      debugPrint('[ConversationsScreen] local conversation load error: $e');
    }
  }

  // ===========================================================================
  //  LOAD SAVED CONTACTS
  //  Reads contacts the user explicitly saved (savedBy == currentUserId).
  //  Populates _contactNameCache keyed by phone digits for O(1) lookup.
  // ===========================================================================

  Future<void> _loadSavedContacts() async {
    try {
      final contacts = await ContactService().getMatrixContactsCached(
        _currentUserId,
      );

      // Clear existing cache before reloading so removed/renamed contacts
      // don't linger
      _contactNameCache.clear();
      _contactAvatarCache.clear();

      for (final c in contacts) {
        final name = c.displayName ?? '';
        // Only cache real human names — skip if it looks like a phone number
        if (name.isEmpty || _looksLikePhone(name)) continue;

        _cacheContactName(c.wrytteUserId, name, c.avatarUrl);
        _cacheContactName(_matrixLocalpart(c.wrytteUserId), name, c.avatarUrl);

        for (final phone in c.phones) {
          // Strip everything except digits so we can match with/without '+'
          _cacheContactName(phone, name, c.avatarUrl);
        }
      }

      debugPrint(
        '[ConversationsScreen] loaded ${_contactNameCache.length} saved contact names',
      );
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
  // ===========================================================================

  Future<List<ChatConversation>> _enrichNames(
    List<ChatConversation> convs,
  ) async {
    final deduped = _dedupeLocalPlaceholders(convs);

    // ── Pass 1: saved contact names always win ─────────────────────────────
    final afterSavedContacts =
        deduped.map((c) {
          final contactKey = _contactKeyForConversation(c);
          if (contactKey != null) {
            return c.copyWith(
              otherUserName: _contactNameCache[contactKey],
              otherUserAvatar: _contactAvatarCache[contactKey],
            );
          }
          return c.copyWith(otherUserName: _unsavedConversationTitle(c));
        }).toList();

    return afterSavedContacts;
  }

  String _unsavedConversationTitle(ChatConversation conv) {
    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      ...conv.participants,
    ]) {
      final phone = _extractPhone(candidate);
      if (phone.isNotEmpty) return _formatPhone(phone);
    }

    final raw = conv.otherUserName ?? conv.otherUserId;
    if (!_isTechnicalName(raw)) return raw;
    return _matrixLocalpart(conv.otherUserId) ?? conv.otherUserId;
  }

  List<ChatConversation> _dedupeLocalPlaceholders(
    List<ChatConversation> convs,
  ) {
    final matrixPeerKeys =
        convs
            .where((c) => c.id.startsWith('!'))
            .expand(_conversationKeys)
            .toSet();

    if (matrixPeerKeys.isEmpty) return convs;

    return convs.where((c) {
      if (!c.id.startsWith('si_')) return true;
      return !_conversationKeys(c).any(matrixPeerKeys.contains);
    }).toList();
  }

  String? _contactKeyForConversation(ChatConversation conv) {
    for (final key in _conversationKeys(conv)) {
      if (_contactNameCache.containsKey(key)) return key;
    }
    return null;
  }

  Iterable<String> _conversationKeys(ChatConversation conv) sync* {
    yield* _identityKeys(conv.otherUserId);
    if (conv.otherUserName != null) yield* _identityKeys(conv.otherUserName!);
    for (final participant in conv.participants) {
      if (participant != _currentUserId &&
          participant != '@$_currentUserId:${MatrixConfig.serverName}') {
        yield* _identityKeys(participant);
      }
    }
  }

  void _cacheContactName(String? raw, String name, String? avatarUrl) {
    final avatar = avatarUrl?.isNotEmpty == true ? avatarUrl : null;
    for (final key in _identityKeys(raw)) {
      _contactNameCache[key] = name;
      _contactAvatarCache[key] = avatar;
    }
  }

  Iterable<String> _identityKeys(String? raw) sync* {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return;

    yield value;

    final localpart = _matrixLocalpart(value);
    if (localpart != null && localpart.isNotEmpty) yield localpart;

    final digits = value.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length >= 6) yield digits;
  }

  String? _matrixLocalpart(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  bool _isTechnicalName(String value) {
    final sanitized = value.trim();
    if (sanitized.isEmpty) return true;
    if (_looksLikePhone(sanitized)) return true;
    if (sanitized.startsWith('@') && sanitized.contains(':')) return true;
    if (sanitized.startsWith('!') && sanitized.contains(':')) return true;
    if (sanitized.toLowerCase().startsWith('group with ')) return true;
    return false;
  }

  /// Returns true when [value] is a raw phone number rather than a
  /// human display name.
  bool _looksLikePhone(String value) {
    final s = value.replaceAll(RegExp(r'[\s\-()]'), '');
    return s.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(s);
  }

  String _extractPhone(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return '';
    final match = RegExp(r'(\+?\d[\d\s\-()]{6,}\d)').firstMatch(raw);
    if (match == null) return '';
    final phone = match.group(1)?.trim() ?? '';
    return _looksLikePhone(phone) ? phone : '';
  }

  String _formatPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.startsWith('+1') && digits.length == 12) {
      return '${digits.substring(0, 2)} ${digits.substring(2, 5)} ${digits.substring(5, 8)} ${digits.substring(8)}';
    }
    return phone;
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

  String _sanitize(String s) =>
      String.fromCharCodes(s.runes.where((r) => r <= 0xD7FF || r >= 0xE000));

  void _enterSelection() => setState(() {
    _isSelectionMode = true;
    _selectedIds.clear();
  });
  void _exitSelection() => setState(() {
    _isSelectionMode = false;
    _selectedIds.clear();
  });
  void _toggleSelection(String id) => setState(() {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
    }
  });

  void _onPin() => debugPrint('Pin: ${_selectedIds.toList()}');
  void _onMarkAsRead() => debugPrint('MarkAsRead: ${_selectedIds.toList()}');
  void _onMute() => debugPrint('Mute: ${_selectedIds.toList()}');
  void _onArchive() => debugPrint('Archive: ${_selectedIds.toList()}');
  void _onDelete() => debugPrint('Delete: ${_selectedIds.toList()}');

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    final isToday =
        local.year == now.year &&
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
        local.day == yesterday.day) {
      return 'Yesterday';
    }
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
    final rawName = conv.otherUserName ?? conv.otherUserId;
    final name = _sanitize(rawName);
    final avatar = conv.otherUserAvatar;
    final selected = _selectedIds.contains(conv.id);

    return ConversationTile(
      name: name,
      lastMessage:
          conv.lastMessage.isEmpty
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
          pageBuilder:
              (_, __, ___) => MiniChatPreview(
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
            _conversations =
                _conversations
                    .map(
                      (c) => c.id == conv.id ? c.copyWith(unreadCount: 0) : c,
                    )
                    .toList();
          });
          _notifyUnread(_conversations);
        }

        if (!mounted) return;

        await Navigator.push(
          context,
          MaterialPageRoute(
            builder:
                (_) => ChatScreen(
                  conversationId: conv.id,
                  receiverId: conv.otherUserId,
                  currentUserId: _currentUserId,
                  title: name,
                  avatarUrl: avatar,
                ),
          ),
        );
        if (mounted) await _loadLocalConversations();
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
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 64,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
                const SizedBox(height: 16),
                Text(
                  'No conversations yet',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap the pencil icon to start a new chat',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.2),
                    fontSize: 13,
                  ),
                ),
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
        await _loadLocalConversations();
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
    final double statusBarH = MediaQuery.of(context).padding.top;
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double headerH =
        statusBarH + kToolbarHeight + _kSearchBarHeight + _kTabBarHeight + 8.0;

    final double searchBarOffset = _kSearchBarHeight * _searchBarProgress;
    final double gradientH = headerH - searchBarOffset;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      extendBodyBehindAppBar: true,
      floatingActionButton:
          _isSelectionMode
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
                    // ContactService.invalidateMatrixContactsCache() on save)
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
                      child: const Text(
                        'Channels coming soon',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: headerH),
                      child: const Text(
                        'Groups coming soon',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Gradient ─────────────────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: gradientH,
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

            // ── Sticky header ─────────────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
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
