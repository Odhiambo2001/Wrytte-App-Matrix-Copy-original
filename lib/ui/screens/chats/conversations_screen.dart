import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
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
//  Name resolution priority (highest -> lowest):
//    1. Saved contacts in Matrix account data.
//    2. Phone number.
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
  StreamSubscription<bool>? _chatConnectionSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  final ScrollController _scrollCtrl = ScrollController();
  double _searchBarProgress = 0.0;

  // ── Priority 1: saved contact names keyed by phone, Matrix ID, and localpart.
  final Map<String, String> _contactNameCache = {};
  final Map<String, String?> _contactAvatarCache = {};
  final Map<String, ContactIdentity> _identityCache = {};
  List<Contact> _savedContacts = const [];
  bool _initialCacheWarmup = true;

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
    _chatConnectionSub?.cancel();
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

    final identityFuture = _loadIdentityCache();
    final contactsFuture = _loadSavedContacts();
    final localConversationsFuture = _loadLocalConversations();

    await localConversationsFuture;
    if (mounted) setState(() => _initialCacheWarmup = false);

    unawaited(
      Future.wait([
        identityFuture,
        contactsFuture,
      ]).then((_) => _repaintConversationsWithCurrentContactData()).catchError((
        e,
      ) {
        debugPrint('[ConversationsScreen] initial contact hydrate skipped: $e');
      }),
    );

    // Pre-warm phonebook identity matches, then repaint any rows that were
    // initially loaded from raw Matrix room data.
    ContactService.preloadContacts(_currentUserId, ContactService());
    unawaited(_loadPhonebookIdentitiesAndRefresh());

    // Subscribe to Matrix conversation stream
    _convSub = _chat.conversationsStream.listen((incoming) async {
      final local = await ChatLocalDb.instance.loadConversations();
      final mergedCache = _mergeConversationLists(local, incoming);
      final visible = _enrichSavedContactNames(
        _realConversationRows(mergedCache),
      );
      if (!mounted) return;
      setState(() => _conversations = visible);
      _notifyUnread(_conversations);
      unawaited(_enrichPublicProfilesAndRepaint(visible));
    });

    _chatConnectionSub = _chat.connectionStream.listen((connected) {
      if (connected) {
        unawaited(_restoreContactsAfterMatrixReady());
      }
    });

    // Connect ChatService (idempotent) after local conversations are visible.
    try {
      await _chat.connect();
      unawaited(_chat.fetchConversations());
      unawaited(_restoreContactsAfterMatrixReady());
    } catch (e) {
      debugPrint('[ConversationsScreen] chat connect skipped: $e');
    }

    // Retry enrichment when connectivity is restored
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet) _retryEnrichment();
    });
  }

  Future<void> _repaintConversationsWithCurrentContactData() async {
    if (!mounted || _conversations.isEmpty) return;
    final visible = _enrichSavedContactNames(
      _realConversationRows(_conversations),
    );
    if (!mounted) return;
    setState(() => _conversations = visible);
    _notifyUnread(_conversations);
    unawaited(_enrichPublicProfilesAndRepaint(visible));
  }

  Future<void> _loadLocalConversations() async {
    try {
      final local = await ChatLocalDb.instance.loadConversations();
      if (!mounted) return;
      final withContactRows = _realConversationRows(local);
      if (withContactRows.isEmpty && _initialCacheWarmup) return;
      final visible = _enrichSavedContactNames(withContactRows);
      setState(() => _conversations = visible);
      _notifyUnread(_conversations);

      _prewarmVisibleMessages(visible);
      unawaited(_enrichPublicProfilesAndRepaint(visible));
    } catch (e) {
      debugPrint('[ConversationsScreen] local conversation load error: $e');
    }
  }

  void _prewarmVisibleMessages(List<ChatConversation> conversations) {
    for (final conversation in conversations) {
      if (_chat.cachedMessagesFor(conversation.id).isNotEmpty) continue;
      unawaited(_chat.loadCachedMessages(conversation.id));
    }
  }

  Future<void> _loadPhonebookIdentitiesAndRefresh() async {
    try {
      await ContactService().getWrytteContactsOptimized();
      await _loadIdentityCache();
      final enriched = _enrichSavedContactNames(_conversations);
      if (!mounted) return;
      setState(() => _conversations = enriched);
      _notifyUnread(_conversations);
      unawaited(_enrichPublicProfilesAndRepaint(enriched));
    } catch (e) {
      debugPrint('[ConversationsScreen] phone identity refresh skipped: $e');
    }
  }

  // ===========================================================================
  //  LOAD SAVED CONTACTS
  //  Reads contacts the user explicitly saved (savedBy == currentUserId).
  //  Populates _contactNameCache keyed by phone digits for O(1) lookup.
  // ===========================================================================

  Future<void> _loadSavedContacts() async {
    try {
      final contacts = await _loadImmediateContactSource();
      _savedContacts = contacts;
      await _rebuildContactNameCaches(contacts);

      debugPrint(
        '[ConversationsScreen] loaded ${_contactNameCache.length} immediate contact names',
      );

      unawaited(_refreshContactSourceInBackground());
    } catch (e) {
      debugPrint('[ConversationsScreen] _loadSavedContacts error: $e');
    }
  }

  Future<List<Contact>> _loadImmediateContactSource() async {
    final saved = await ContactLocalDb.loadSavedContacts(
      ownerUserId: _currentUserId,
    );
    if (saved.isNotEmpty) {
      return _sortContacts(saved);
    }

    final cached = await ContactLocalDb.loadContacts(
      ownerUserId: _currentUserId,
    );
    final wrytteContacts =
        cached.where((contact) => contact.isOnWrytte).toList();
    if (wrytteContacts.isNotEmpty) {
      return _sortContacts(wrytteContacts);
    }

    return const [];
  }

  Future<void> _refreshContactSourceInBackground() async {
    try {
      final contacts = await ContactService().getMatrixContactsCached(
        _currentUserId,
      );
      if (contacts.isEmpty || !mounted) return;
      _savedContacts = _sortContacts(contacts);
      await _rebuildContactNameCaches(_savedContacts);
      final enriched = _enrichSavedContactNames(
        _realConversationRows(_conversations),
      );
      if (!mounted) return;
      setState(() => _conversations = enriched);
      _notifyUnread(_conversations);
    } catch (e) {
      debugPrint(
        '[ConversationsScreen] background contact refresh skipped: $e',
      );
    }
  }

  Future<void> _restoreContactsAfterMatrixReady() async {
    try {
      ContactService.invalidateMatrixContactsCache();
      final contacts = await ContactService().getMatrixContacts(_currentUserId);
      if (contacts.isEmpty || !mounted) return;
      _savedContacts = _sortContacts(contacts);
      await _rebuildContactNameCaches(_savedContacts);
      await _repaintConversationsWithCurrentContactData();
    } catch (e) {
      debugPrint('[ConversationsScreen] Matrix contact restore skipped: $e');
    }
  }

  List<Contact> _sortContacts(List<Contact> contacts) {
    return List<Contact>.from(contacts)
      ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
  }

  Future<void> _rebuildContactNameCaches(List<Contact> contacts) async {
    // Clear existing cache before reloading so removed/renamed contacts
    // don't linger.
    _contactNameCache.clear();
    _contactAvatarCache.clear();

    for (final c in contacts) {
      final name = c.displayName ?? '';
      // Only cache real human names — skip if it looks like a phone number.
      if (name.isEmpty || _looksLikePhone(name)) continue;

      _cacheContactName(c.wrytteUserId, name, c.avatarUrl);
      _cacheContactName(_matrixLocalpart(c.wrytteUserId), name, c.avatarUrl);
      if (c.wrytteUserId != null && c.wrytteUserId!.trim().isNotEmpty) {
        await ContactIdentityCache.instance.upsert(
          ownerUserId: _currentUserId,
          matrixUserId: c.wrytteUserId!,
          phone: c.primaryPhone,
          savedName: name,
          avatarUrl: c.avatarUrl,
        );
      }

      for (final phone in c.phones) {
        _cacheContactName(phone, name, c.avatarUrl);
      }
    }
    await _loadIdentityCache();
  }

  Future<void> _loadIdentityCache() async {
    _identityCache
      ..clear()
      ..addAll(
        await ContactIdentityCache.instance.loadAll(
          ownerUserId: _currentUserId,
        ),
      );
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
    final afterSavedContacts = _enrichSavedContactNames(convs);

    // ── Pass 2: public backend profile fills sender avatar/name for "Everyone"
    // visibility. Saved contact names stay above public names, but the avatar
    // should still show even when the receiver has not saved the sender.
    final enriched = <ChatConversation>[];
    for (final conv in afterSavedContacts) {
      enriched.add(await _enrichConversationFromPublicProfile(conv));
    }

    return enriched;
  }

  Future<void> _enrichPublicProfilesAndRepaint(
    List<ChatConversation> convs,
  ) async {
    if (convs.isEmpty) return;
    try {
      final enriched = await _enrichNames(convs);
      if (!mounted) return;
      setState(() => _conversations = enriched);
      _notifyUnread(_conversations);
    } catch (e) {
      debugPrint('[ConversationsScreen] public profile enrichment skipped: $e');
    }
  }

  List<ChatConversation> _enrichSavedContactNames(
    List<ChatConversation> convs,
  ) {
    final deduped = _dedupeLocalPlaceholders(_realConversationRows(convs));

    // Saved contact names always win. Matrix displayname is the registered
    // profile name, not necessarily this user's saved contact label.
    return deduped.map((c) {
      final title = _conversationTitle(c);
      final contactKey = _contactKeyForConversation(c);
      final fallbackTitle = _fallbackConversationTitle(c);
      return c.copyWith(
        otherUserName: title.trim().isEmpty ? fallbackTitle : title,
        otherUserAvatar:
            contactKey == null
                ? c.otherUserAvatar
                : _contactAvatarCache[contactKey] ?? c.otherUserAvatar,
      );
    }).toList();
  }

  List<ChatConversation> _mergeConversationLists(
    List<ChatConversation> cached,
    List<ChatConversation> incoming,
  ) {
    final byId = <String, ChatConversation>{
      for (final conversation in cached) conversation.id: conversation,
    };

    for (final conversation in incoming) {
      final existing = byId[conversation.id];
      byId[conversation.id] =
          existing == null
              ? conversation
              : _preferRicherConversation(existing, conversation);
    }

    final merged =
        byId.values.toList()
          ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    return merged;
  }

  List<ChatConversation> _realConversationRows(
    List<ChatConversation> conversations,
  ) {
    return conversations
        .where(
          (conversation) =>
              !(conversation.id.startsWith('si_') &&
                  conversation.lastMessage.trim().isEmpty),
        )
        .toList();
  }

  ChatConversation _preferRicherConversation(
    ChatConversation cached,
    ChatConversation incoming,
  ) {
    final incomingHasMessage = incoming.lastMessage.trim().isNotEmpty;
    final cachedHasMessage = cached.lastMessage.trim().isNotEmpty;
    if (!incomingHasMessage && cachedHasMessage) {
      return cached.copyWith(
        unreadCount: incoming.unreadCount,
        otherUserName: incoming.otherUserName ?? cached.otherUserName,
        otherUserAvatar: incoming.otherUserAvatar ?? cached.otherUserAvatar,
      );
    }
    return incoming.copyWith(
      otherUserName: incoming.otherUserName ?? cached.otherUserName,
      otherUserAvatar: incoming.otherUserAvatar ?? cached.otherUserAvatar,
    );
  }

  Future<ChatConversation> _enrichConversationFromPublicProfile(
    ChatConversation conv,
  ) async {
    final profileUid = _profileUidForConversation(conv);
    if (profileUid == null) return conv;

    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final profile = await UserProfileService.instance.getProfileByUid(
      profileUid,
      phone: fallbackPhone,
    );
    final matrixProfile = await _loadMatrixProfile(profileUid);
    if (profile == null && matrixProfile == null) return conv;

    final publicName = _cleanHumanName(profile?.displayName);
    final matrixName = _cleanHumanName(matrixProfile?.$1);
    final savedName = _cleanHumanName(
      _identityForConversation(conv)?.savedName,
    );
    final contactKey = _contactKeyForConversation(conv);
    final contactName =
        contactKey == null
            ? ''
            : _cleanHumanName(_contactNameCache[contactKey]);
    final name =
        savedName.isNotEmpty
            ? savedName
            : contactName.isNotEmpty
            ? contactName
            : publicName.isNotEmpty
            ? publicName
            : matrixName.isNotEmpty
            ? matrixName
            : _fallbackConversationTitle(conv);
    final avatar =
        profile?.hasProfileImage == true
            ? profile!.profileImage
            : matrixProfile?.$2 ?? conv.otherUserAvatar;
    final enriched = conv.copyWith(
      otherUserName: name,
      otherUserAvatar: avatar,
    );

    if (name.trim().isNotEmpty || (avatar ?? '').trim().isNotEmpty) {
      await ChatLocalDb.instance.updateConversationUserInfo(
        conversationId: conv.id,
        name: name.trim(),
        avatar: avatar,
      );
    }
    return enriched;
  }

  Future<(String?, String?)?> _loadMatrixProfile(String uid) async {
    try {
      if (!MatrixClientService.instance.isLoggedIn) return null;
      final matrixUserId =
          uid.startsWith('@') ? uid : '@$uid:${MatrixConfig.serverName}';
      final profile = await MatrixClientService.instance.client
          .getProfileFromUserId(
            matrixUserId,
            timeout: const Duration(seconds: 5),
          );
      return (profile.displayName, profile.avatarUrl?.toString());
    } catch (_) {
      return null;
    }
  }

  String? _profileUidForConversation(ChatConversation conv) {
    for (final candidate in [
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final value = candidate.trim();
      if (value.isEmpty || _isCurrentUserIdentifier(value)) continue;
      if (value.startsWith('!') || value.startsWith('@!')) continue;
      final localpart = _matrixLocalpart(value) ?? value;
      if (localpart.isEmpty) continue;
      return value.startsWith('@')
          ? value
          : '@$localpart:${MatrixConfig.serverName}';
    }
    return null;
  }

  String _fallbackPhoneForConversation(ChatConversation conv) {
    for (final candidate in [
      _identityForConversation(conv)?.phone,
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final phone = _extractPhone(candidate);
      if (phone.isNotEmpty) return phone;
    }
    return '';
  }

  String _fallbackConversationTitle(ChatConversation conv) {
    final phone = _fallbackPhoneForConversation(conv);
    if (phone.isNotEmpty) return _formatPhone(phone);

    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final name = _cleanHumanName(candidate);
      if (name.isNotEmpty) return name;
    }

    return 'Wrytte user';
  }

  String _conversationTitle(ChatConversation conv) {
    final identity = _identityForConversation(conv);
    final savedName = _cleanHumanName(identity?.savedName);
    if (savedName.isNotEmpty) return savedName;

    final contactKey = _contactKeyForConversation(conv);
    if (contactKey != null) {
      final contactName = _cleanHumanName(_contactNameCache[contactKey]);
      if (contactName.isNotEmpty) return contactName;
    }

    final identityPhone = _extractPhone(identity?.phone);
    if (identityPhone.isNotEmpty) return _formatPhone(identityPhone);

    if (contactKey != null) {
      final phone = _extractPhone(contactKey);
      if (phone.isNotEmpty) return _formatPhone(phone);
    }

    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final phone = _phoneFromIdentifier(candidate);
      if (phone.isNotEmpty) return _formatPhone(phone);
    }

    final lastSenderPhone = _phoneFromIdentifier(conv.lastMessageSenderId);
    if (lastSenderPhone.isNotEmpty) return _formatPhone(lastSenderPhone);

    return '';
  }

  ContactIdentity? _identityForConversation(ChatConversation conv) {
    for (final key in _conversationKeys(conv)) {
      final localpart = _matrixLocalpart(key)?.toLowerCase();
      if (localpart != null && _identityCache.containsKey(localpart)) {
        return _identityCache[localpart];
      }
    }
    return null;
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
    if (!_isCurrentUserIdentifier(conv.lastMessageSenderId)) {
      yield* _identityKeys(conv.lastMessageSenderId);
    }
    if (conv.otherUserName != null) yield* _identityKeys(conv.otherUserName!);
    for (final participant in conv.participants) {
      if (!_isCurrentUserIdentifier(participant)) {
        yield* _identityKeys(participant);
      }
    }
  }

  bool _isCurrentUserIdentifier(String value) {
    final current = _currentUserId.trim();
    if (current.isEmpty) return false;
    final localpart = _matrixLocalpart(value) ?? value.trim();
    return localpart == current ||
        value.trim() == '@$current:${MatrixConfig.serverName}';
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

  /// Returns true when [value] is a raw phone number rather than a
  /// human display name.
  bool _looksLikePhone(String value) {
    final s = value.replaceAll(RegExp(r'[\s\-()+]'), '');
    if (s.length < 7 || s.length > 15) return false;
    return s.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(s);
  }

  bool _looksLikeMatrixId(String value) {
    final trimmed = value.trim();
    final localpart = _matrixLocalpart(trimmed) ?? trimmed;
    return trimmed.startsWith('@') ||
        trimmed.startsWith('!') ||
        trimmed.contains(':matrix.') ||
        RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart);
  }

  String _cleanHumanName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return '';
    }
    if (_looksLikePhone(trimmed) || _looksLikeMatrixId(trimmed)) return '';
    return trimmed;
  }

  String _extractPhone(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return '';
    final match = RegExp(r'(\+?\d[\d\s\-()]{6,}\d)').firstMatch(raw);
    if (match == null) return '';
    final phone = match.group(1)?.trim() ?? '';
    return _looksLikePhone(phone) ? phone : '';
  }

  String _phoneFromIdentifier(String? value) {
    final extracted = _extractPhone(value);
    if (extracted.isNotEmpty) return extracted;

    final localpart = _matrixLocalpart(value);
    final digits = localpart?.replaceAll(RegExp(r'[^\d]'), '') ?? '';
    return digits.length >= 7 && digits.length <= 15 ? digits : '';
  }

  String _formatPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    final digitsOnly = digits.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.length < 7 || digitsOnly.length > 15) return '';
    if (digits.startsWith('+1') && digits.length == 12) {
      return '${digits.substring(0, 2)} ${digits.substring(2, 5)} ${digits.substring(5, 8)} ${digits.substring(8)}';
    }
    if (digits.isNotEmpty && !digits.startsWith('+')) return '+$digits';
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
    final rawName = _cleanHumanName(conv.otherUserName);
    final name = _sanitize(
      rawName.isNotEmpty ? rawName : _fallbackConversationTitle(conv),
    );
    final avatar = conv.otherUserAvatar;
    final selected = _selectedIds.contains(conv.id);

    return ConversationTile(
      name: name,
      lastMessage: _sanitize(conv.lastMessage),
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

        var initialMessages = _chat.cachedMessagesFor(conv.id);
        if (initialMessages.isEmpty) {
          initialMessages = await _chat.loadCachedMessages(conv.id);
          if (!mounted) return;
        }

        unawaited(_chat.markConversationAsRead(conv.id));
        unawaited(
          NotificationService.instance.clearConversationNotifications(conv.id),
        );

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
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 220),
            pageBuilder:
                (_, __, ___) => ChatScreen(
                  conversationId: conv.id,
                  receiverId: conv.otherUserId,
                  currentUserId: _currentUserId,
                  title: name,
                  avatarUrl: avatar,
                  initialMessages: initialMessages,
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
        if (mounted) await _loadLocalConversations();
      },
    );
  }

  // ===========================================================================
  //  BUILD
  // ===========================================================================

  Widget _buildChatsTab(double topPadding) {
    if (_conversations.isEmpty) {
      if (_initialCacheWarmup) {
        return ScrollConfiguration(
          behavior: const _ConversationsScrollBehavior(),
          child: ListView(
            controller: _scrollCtrl,
            padding: EdgeInsets.only(top: topPadding, bottom: 120),
            physics: const BouncingScrollPhysics(),
          ),
        );
      }

      return ScrollConfiguration(
        behavior: const _ConversationsScrollBehavior(),
        child: ListView(
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
        ),
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
      child: ScrollConfiguration(
        behavior: const _ConversationsScrollBehavior(),
        child: ListView.builder(
          controller: _scrollCtrl,
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(top: topPadding, bottom: 120),
          itemCount: _conversations.length,
          itemBuilder: (_, i) => _buildTile(_conversations[i]),
        ),
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
                  heroTag: 'conversations_new_chat_fab',
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

class _ConversationsScrollBehavior extends ScrollBehavior {
  const _ConversationsScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
