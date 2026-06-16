import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/contacts/user_search_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
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
//    1. Saved contacts from local/backend contact storage.
//    2. Phone number.
// =============================================================================

const double _kSearchBarHeight = 60.0;
const double _kTabBarHeight = 56.0;

class ConversationsScreen extends StatefulWidget {
  final Function(int)? onUnreadCountUpdated;
  final String currentUserId;
  final List<Contact> initialSavedContacts;

  const ConversationsScreen({
    super.key,
    this.onUnreadCountUpdated,
    this.currentUserId = '',
    this.initialSavedContacts = const [],
  });

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}
//final Map<String, (String?, String?)?> _matrixProfileCache = {};

class _ConversationsScreenState extends State<ConversationsScreen> {
  final ChatService _chat = ChatService();
  final UserSearchService _userSearchService = UserSearchService();
  final Map<String, (String?, String?)?> _matrixProfileCache = {};

  List<ChatConversation> _conversations = [];

  String _currentUserId = '';
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  StreamSubscription<List<ChatConversation>>? _convSub;
  StreamSubscription<bool>? _chatConnectionSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<String>? _contactsChangedSub;
  Timer? _conversationBatchTimer;

  final ScrollController _scrollCtrl = ScrollController();
  double _searchBarProgress = 0.0;

  // ── Priority 1: saved contact names keyed by phone, Matrix ID, and localpart.
  final Map<String, String> _contactNameCache = {};
  final Map<String, String?> _contactAvatarCache = {};
  final Map<String, ContactIdentity> _identityCache = {};
  List<Contact> _savedContacts = const [];
  bool _initialCacheWarmup = true;
  int _conversationPaintVersion = 0;
  int _conversationRefreshVersion = 0;
  List<ChatConversation>? _pendingConversationBatch;
  bool _conversationBatchInFlight = false;

  // ===========================================================================
  //  LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _seedSavedContacts(widget.initialSavedContacts);
    _seedCachedConversations();
    _scrollCtrl.addListener(_onScroll);
    Future.microtask(_initialize);
  }

  @override
  void dispose() {
    _convSub?.cancel();
    _chatConnectionSub?.cancel();
    _connectivitySub?.cancel();
    _contactsChangedSub?.cancel();
    _conversationBatchTimer?.cancel();
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

  void _seedSavedContacts(List<Contact> contacts) {
    if (contacts.isEmpty) return;
    _savedContacts = _sortContacts(contacts);
    _contactNameCache.clear();
    _contactAvatarCache.clear();
    for (final c in _savedContacts) {
      final name = c.displayName ?? '';
      if (name.isEmpty || _looksLikePhone(name)) continue;
      _cacheContactName(c.wrytteUserId, name, c.avatarUrl);
      _cacheContactName(_matrixLocalpart(c.wrytteUserId), name, c.avatarUrl);
      for (final phone in c.phones) {
        _cacheContactName(phone, name, c.avatarUrl);
      }
    }
  }

  void _seedCachedConversations() {
    final cached = _enrichSavedContactNames(
      _realConversationRows(_chat.cachedConversationsSnapshot),
    );
    if (cached.isEmpty) return;
    _conversations = cached;
    _notifyUnread(_conversations);
  }

  Future<void> _initialize() async {
    _currentUserId =
        widget.currentUserId.isNotEmpty
            ? widget.currentUserId
            : await AuthService.instance.getCurrentUserId() ?? '';

    if (_currentUserId.isEmpty) return;

    await _loadIdentityCacheFast();
    await _loadSavedContacts();
    await _loadLocalConversations();
    if (mounted) setState(() => _initialCacheWarmup = false);
    unawaited(_refreshContactSourceInBackground());

    // Pre-warm phonebook identity matches, then repaint any rows that were
    // initially loaded from raw Matrix room data.
    ContactService.preloadContacts(_currentUserId, ContactService());
    unawaited(_loadPhonebookIdentitiesAndRefresh());

    // Subscribe to Matrix conversation stream
    _convSub = _chat.conversationsStream.listen(_queueConversationBatch);
    _contactsChangedSub = ContactService.contactsChanged.listen((ownerUserId) {
      if (ownerUserId.trim().toLowerCase() !=
          _currentUserId.trim().toLowerCase()) {
        return;
      }
      unawaited(_reloadContactsAndRepaint(reason: 'local contact changed'));
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

  void _queueConversationBatch(List<ChatConversation> incoming) {
    _pendingConversationBatch = incoming;
    _conversationBatchTimer?.cancel();
    _conversationBatchTimer = Timer(const Duration(milliseconds: 160), () {
      unawaited(_processQueuedConversationBatch());
    });
  }

  Future<void> _processQueuedConversationBatch() async {
    if (_conversationBatchInFlight) return;
    _conversationBatchInFlight = true;

    try {
      while (mounted && _pendingConversationBatch != null) {
        final incoming = _pendingConversationBatch!;
        _pendingConversationBatch = null;

        final local = await ChatLocalDb.instance.loadConversations();
        final mergedCache = _mergeConversationLists(local, incoming);
        final rows = _enrichSavedContactNames(
          _realConversationRows(mergedCache),
        );
        final version = ++_conversationPaintVersion;
        final visible = await _prepareConversationsForFirstPaint(rows, version);
        if (!mounted || version != _conversationPaintVersion) continue;

        setState(() => _conversations = visible);
        _notifyUnread(_conversations);
      }
    } finally {
      _conversationBatchInFlight = false;
      if (mounted && _pendingConversationBatch != null) {
        _conversationBatchTimer?.cancel();
        _conversationBatchTimer = Timer(const Duration(milliseconds: 80), () {
          unawaited(_processQueuedConversationBatch());
        });
      }
    }
  }

  Future<void> _repaintConversationsWithCurrentContactData() async {
    if (!mounted || _conversations.isEmpty) return;
    final rows = _enrichSavedContactNames(
      _realConversationRows(_conversations),
    );
    final visible = await _enrichNames(rows);
    await _publishPreparedConversations(visible);
  }

  Future<void> _loadLocalConversations() async {
    try {
      final local = await ChatLocalDb.instance.loadConversations();
      if (!mounted) return;
      final withContactRows = _enrichSavedContactNames(
        _realConversationRows(local),
      );
      if (withContactRows.isEmpty && _initialCacheWarmup) {
        return;
      }

      final version = ++_conversationPaintVersion;
      final visible = await _prepareConversationsForFirstPaint(
        withContactRows,
        version,
      );
      if (!mounted || version != _conversationPaintVersion) return;
      setState(() => _conversations = visible);
      _notifyUnread(_conversations);

      _prewarmVisibleMessages(visible);
    } catch (e) {
      debugPrint('[ConversationsScreen] local conversation load error: $e');
    }
  }

  Future<void> _loadIdentityCacheFast() async {
    try {
      await _loadIdentityCache();
    } catch (e) {
      debugPrint('[ConversationsScreen] initial identity cache skipped: $e');
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
      final rows = _enrichSavedContactNames(_conversations);
      final enriched = await _enrichNames(rows);
      await _publishPreparedConversations(enriched);
    } catch (e) {
      debugPrint('[ConversationsScreen] phone identity refresh skipped: $e');
    }
  }

  // ===========================================================================
  //  LOAD SAVED CONTACTS
  //  Reads contacts the user explicitly saved (savedBy == currentUserId).
  //  Populates _contactNameCache keyed by phone digits for O(1) lookup.
  // ===========================================================================

  Future<void> _loadSavedContacts({bool refreshBackend = true}) async {
    try {
      final contacts = await _loadImmediateContactSource();
      _savedContacts = contacts;
      await _rebuildContactNameCaches(contacts);

      debugPrint(
        '[ConversationsScreen] loaded ${_contactNameCache.length} immediate contact names',
      );

      if (refreshBackend) {
        unawaited(_refreshContactSourceInBackground());
      }
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
      final rows = _enrichSavedContactNames(
        _realConversationRows(_conversations),
      );
      final enriched = await _enrichNames(rows);
      await _publishPreparedConversations(enriched);
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
      debugPrint('[ConversationsScreen] contact restore skipped: $e');
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
    //final enriched = <ChatConversation>[];

    /** 
    for (final conv in afterSavedContacts) {
      enriched.add(await _enrichConversationFromPublicProfile(conv));
    }
    **/

    return Future.wait(
      afterSavedContacts.map(
        (conv) => _enrichConversationFromPublicProfile(conv),
      ),
    );
  }

  Future<void> _publishPreparedConversations(
    List<ChatConversation> conversations,
  ) async {
    if (!mounted) return;
    final refreshVersion = ++_conversationRefreshVersion;
    var rows = _enrichSavedContactNames(_realConversationRows(conversations));
    if (_hasRowsMissingStableIdentity(rows)) {
      rows = await _enrichNames(rows);
    }
    unawaited(_precacheConversationAvatars(rows));
    if (!mounted || refreshVersion != _conversationRefreshVersion) return;
    setState(() => _conversations = rows);
    _notifyUnread(_conversations);
  }

  Future<List<ChatConversation>> _prepareConversationsForFirstPaint(
    List<ChatConversation> convs,
    int version,
  ) async {
    var withSavedContacts = _enrichSavedContactNames(convs);
    if (_hasRowsMissingStableIdentity(withSavedContacts)) {
      withSavedContacts = await _enrichNames(withSavedContacts);
    }
    unawaited(_precacheInitialConversationAvatars(withSavedContacts));
    return withSavedContacts;
  }

  Future<void> _precacheInitialConversationAvatars(
    List<ChatConversation> conversations,
  ) async {
    try {
      await _precacheConversationAvatars(conversations);
    } catch (e) {
      debugPrint('[ConversationsScreen] initial avatar batch skipped: $e');
    }
  }

  bool _hasRowsMissingStableIdentity(List<ChatConversation> convs) {
    for (final conv in convs) {
      final contactKey = _contactKeyForConversation(conv);
      final cachedPublicName = _cachedPublicNameForConversation(conv);
      final identityName = _cleanHumanName(
        _identityForConversation(conv)?.profileName,
      );
      final hasStableName =
          contactKey != null ||
          (cachedPublicName != null && cachedPublicName.isNotEmpty) ||
          identityName.isNotEmpty ||
          _conversationHasPhoneLabel(conv);
      if (!hasStableName) return true;
      final avatar = _avatarForConversation(conv);
      if ((avatar ?? '').trim().isEmpty) return true;
    }
    return false;
  }

  bool _conversationHasPhoneLabel(ChatConversation conv) {
    final phone = _fallbackPhoneForConversation(conv);
    if (phone.isNotEmpty) return true;

    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      if (_phoneFromIdentifier(candidate).isNotEmpty) return true;
    }
    return false;
  }

  Future<void> _precacheConversationAvatars(
    List<ChatConversation> conversations,
  ) async {
    if (!mounted) return;
    final token =
        AuthService.instance.cachedBackendToken ??
        await AuthService.instance.getValidBackendToken();
    final seen = <String>{};
    final futures = <Future<void>>[];

    for (final conversation in conversations) {
      final url = _resolveAvatarUrl(_avatarForConversation(conversation));
      if (url.isEmpty || !seen.add(url)) continue;
      futures.add(
        _warmAvatarImage(
          CachedNetworkImageProvider(
            url,
            headers: _avatarAuthHeaders(url, token),
          ),
        ).catchError((e) {
          debugPrint(
            '[ConversationsScreen] avatar precache skipped url="$url" error=$e',
          );
        }),
      );
    }

    if (futures.isEmpty) return;
    await Future.wait(futures);
  }

  Future<void> _warmAvatarImage(ImageProvider provider) {
    final completer = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, __) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  String _resolveAvatarUrl(String? raw) {
    final url = raw?.trim() ?? '';
    if (url.isEmpty) return '';
    if (url.startsWith('/')) return '${ApiService.baseUrl}$url';
    return url;
  }

  Map<String, String>? _avatarAuthHeaders(String url, String? token) {
    final clean = token?.trim() ?? '';
    if (clean.isEmpty) return null;
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final isWrytteImage =
        url.startsWith('${ApiService.baseUrl}/usrimg/') ||
        url.startsWith('/usrimg/') ||
        host == 'wryttedev.azurewebsites.net' ||
        host == 'wrytte.com';
    if (!isWrytteImage) return null;
    return {'Authorization': 'Bearer $clean'};
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
        otherUserAvatar: _preferredAvatarForConversation(c, contactKey),
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
    final unreadCount = cached.unreadCount == 0 ? 0 : incoming.unreadCount;
    if (!incomingHasMessage && cachedHasMessage) {
      return cached.copyWith(
        unreadCount: unreadCount,
        otherUserName: incoming.otherUserName ?? cached.otherUserName,
        otherUserAvatar:
            cached.otherUserAvatar?.trim().isNotEmpty == true
                ? cached.otherUserAvatar
                : incoming.otherUserAvatar,
      );
    }
    return incoming.copyWith(
      unreadCount: unreadCount,
      otherUserName: incoming.otherUserName ?? cached.otherUserName,
      otherUserAvatar:
          cached.otherUserAvatar?.trim().isNotEmpty == true
              ? cached.otherUserAvatar
              : incoming.otherUserAvatar,
    );
  }

  Future<ChatConversation> _enrichConversationFromPublicProfile(
    ChatConversation conv,
  ) async {
    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final profileUid =
        _profileUidForConversation(conv) ??
        await _profileUidFromPhone(fallbackPhone);
    if (profileUid == null) return conv;

    final profile = await UserProfileService.instance.getProfileByUid(
      profileUid,
      phone: fallbackPhone,
      forceRefresh: false,
    );
    final matrixProfile = await _loadMatrixProfile(profileUid);
    if (profile == null && matrixProfile == null) return conv;

    final contactKey = _contactKeyForConversation(conv);
    final contactName =
        contactKey == null
            ? ''
            : _cleanHumanName(_contactNameCache[contactKey]);
    final contactAvatar =
        contactKey == null ? null : _contactAvatarCache[contactKey]?.trim();
    final phone = _fallbackPhoneForConversation(conv);
    final name =
        contactName.isNotEmpty
            ? contactName
            : phone.isNotEmpty
            ? _formatPhone(phone)
            : '';
    final existingAvatar = conv.otherUserAvatar?.trim();
    final identityAvatar = _identityForConversation(conv)?.avatarUrl?.trim();
    final profileAvatar =
        profile?.hasProfileImage == true ? profile!.profileImage.trim() : '';
    final matrixAvatar = matrixProfile?.$2?.trim();
    final avatar =
        contactAvatar?.isNotEmpty == true
            ? contactAvatar
            : profileAvatar.isNotEmpty
            ? profileAvatar
            : matrixAvatar?.isNotEmpty == true
            ? matrixAvatar
            : existingAvatar?.isNotEmpty == true
            ? existingAvatar
            : identityAvatar?.isNotEmpty == true
            ? identityAvatar
            : null;
    if ((avatar ?? '').trim().isNotEmpty &&
        avatar?.trim() != conv.otherUserAvatar?.trim()) {
      await AvatarPreloadService.replace(
        oldUrl: conv.otherUserAvatar,
        newUrl: avatar,
      );
    }
    final refreshedSavedContact =
        profile == null
            ? null
            : await ContactLocalDb.refreshPublicProfileFields(
              ownerUserId: _currentUserId,
              wrytteUserId: profileUid,
              phone: profile.phone.isNotEmpty ? profile.phone : phone,
              avatarUrl: avatar,
              bio: profile.bio,
            );
    if (refreshedSavedContact != null) {
      _cacheContactName(
        refreshedSavedContact.wrytteUserId,
        refreshedSavedContact.formattedName,
        refreshedSavedContact.avatarUrl,
      );
      for (final savedPhone in refreshedSavedContact.phones) {
        _cacheContactName(
          savedPhone,
          refreshedSavedContact.formattedName,
          refreshedSavedContact.avatarUrl,
        );
      }
    }
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
      final identity = ContactIdentity(
        matrixUserId: profileUid,
        phone: profile?.phone ?? phone,
        profileName:
            _cleanHumanName(profile?.displayName).isNotEmpty
                ? _cleanHumanName(profile?.displayName)
                : _cleanHumanName(matrixProfile?.$1).isNotEmpty
                ? _cleanHumanName(matrixProfile?.$1)
                : null,
        avatarUrl: avatar,
        bio: profile?.bio,
      );
      _cacheIdentity(identity);
      await ContactIdentityCache.instance.upsert(
        ownerUserId: _currentUserId,
        matrixUserId: profileUid,
        phone: profile?.phone ?? phone,
        profileName:
            _cleanHumanName(profile?.displayName).isNotEmpty
                ? _cleanHumanName(profile?.displayName)
                : _cleanHumanName(matrixProfile?.$1).isNotEmpty
                ? _cleanHumanName(matrixProfile?.$1)
                : null,
        avatarUrl: avatar,
        bio: profile?.bio,
      );
    }
    return enriched;
  }

  Future<String?> _profileUidFromPhone(String phone) async {
    final cleanPhone = _normalizePhone(phone);
    if (cleanPhone.isEmpty) return null;
    final digits = cleanPhone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length < 7) return null;

    try {
      final result = await _userSearchService.searchUsersByPhones(
        phoneNumbersC: '$digits|$cleanPhone',
        token: '',
      );
      final resolved =
          result[cleanPhone] ??
          result[digits] ??
          result[cleanPhone.replaceFirst('+', '')];
      if (resolved == null ||
          resolved.isEmpty ||
          resolved == UserSearchService.registeredWithoutMatrixId) {
        return null;
      }
      final localpart = _matrixLocalpart(resolved) ?? resolved;
      return resolved.startsWith('@')
          ? resolved
          : '@$localpart:${MatrixConfig.serverName}';
    } catch (e) {
      debugPrint(
        '[ConversationsScreen] profile phone lookup skipped phone="$cleanPhone": $e',
      );
      return null;
    }
  }

  Future<(String?, String?)?> _loadMatrixProfile(String uid) async {
    if (_matrixProfileCache.containsKey(uid)) return _matrixProfileCache[uid];
    try {
      if (!MatrixClientService.instance.isLoggedIn) return null;
      final matrixUserId =
          uid.startsWith('@') ? uid : '@$uid:${MatrixConfig.serverName}';
      final profile = await MatrixClientService.instance.client
          .getProfileFromUserId(
            matrixUserId,
            timeout: const Duration(seconds: 2),
          );
      final result = (profile.displayName, profile.avatarUrl?.toString());
      _matrixProfileCache[uid] = result;
      return result;
    } catch (_) {
      _matrixProfileCache[uid] = null;
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

    return _fallbackConversationIdentifier(conv);
  }

  String _fallbackConversationIdentifier(ChatConversation conv) {
    for (final candidate in [
      conv.otherUserName,
      conv.otherUserId,
      conv.lastMessageSenderId,
      ...conv.participants,
    ]) {
      final value = candidate?.trim() ?? '';
      if (value.isEmpty || _isCurrentUserIdentifier(value)) continue;
      if (value.startsWith('!') || value.startsWith('@!')) continue;
      final localpart = _matrixLocalpart(value) ?? value;
      if (localpart.trim().isNotEmpty) return localpart.trim();
    }
    return conv.id;
  }

  String _conversationTitle(ChatConversation conv) {
    final identity = _identityForConversation(conv);
    final contactKey = _contactKeyForConversation(conv);

    // Saved contact labels are local user intent and always win.
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

  String? _avatarForConversation(ChatConversation conv) {
    final contactKey = _contactKeyForConversation(conv);
    final contactAvatar =
        contactKey == null ? null : _contactAvatarCache[contactKey]?.trim();
    if (contactAvatar != null && contactAvatar.isNotEmpty) {
      return contactAvatar;
    }

    final cachedPublicAvatar = _cachedPublicAvatarForConversation(conv);
    if (cachedPublicAvatar != null && cachedPublicAvatar.isNotEmpty) {
      return cachedPublicAvatar;
    }

    final direct = conv.otherUserAvatar?.trim();
    if (direct != null && direct.isNotEmpty) return direct;

    final identityAvatar = _identityForConversation(conv)?.avatarUrl?.trim();
    if (identityAvatar != null && identityAvatar.isNotEmpty) {
      return identityAvatar;
    }

    return null;
  }

  String? _preferredAvatarForConversation(
    ChatConversation conv,
    String? contactKey,
  ) {
    final contactAvatar =
        contactKey == null ? null : _contactAvatarCache[contactKey]?.trim();
    if (contactAvatar != null && contactAvatar.isNotEmpty) {
      return contactAvatar;
    }

    final cachedPublicAvatar = _cachedPublicAvatarForConversation(conv);
    if (cachedPublicAvatar != null && cachedPublicAvatar.isNotEmpty) {
      return cachedPublicAvatar;
    }

    final direct = conv.otherUserAvatar?.trim();
    if (direct != null && direct.isNotEmpty) return direct;

    final identityAvatar = _identityForConversation(conv)?.avatarUrl?.trim();
    if (identityAvatar != null && identityAvatar.isNotEmpty) {
      return identityAvatar;
    }

    return null;
  }

  String? _cachedPublicAvatarForConversation(ChatConversation conv) {
    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final uid = _profileUidForConversation(conv);
    if (uid == null) return null;
    final cached = UserProfileService.instance.cachedPublicProfileByUid(
      uid,
      phone: fallbackPhone,
    );
    return cached?.hasProfileImage == true ? cached!.profileImage : null;
  }

  String? _localAvatarPathForConversation(ChatConversation conv) {
    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final uid = _profileUidForConversation(conv);
    if (uid == null) return null;
    final cached = UserProfileService.instance.cachedPublicProfileByUid(
      uid,
      phone: fallbackPhone,
    );
    final localPath = cached?.localProfileImagePath.trim() ?? '';
    return localPath.isEmpty ? null : localPath;
  }

  String? _cachedPublicNameForConversation(ChatConversation conv) {
    final fallbackPhone = _fallbackPhoneForConversation(conv);
    final uid = _profileUidForConversation(conv);
    if (uid == null) return null;
    final cached = UserProfileService.instance.cachedPublicProfileByUid(
      uid,
      phone: fallbackPhone,
    );
    final name = _cleanHumanName(cached?.displayName);
    return name.isEmpty ? null : name;
  }

  void _cacheIdentity(ContactIdentity identity) {
    for (final key in [
      ..._identityKeys(identity.matrixUserId),
      ..._identityKeys(identity.phone),
    ]) {
      final localpart = _matrixLocalpart(key)?.toLowerCase();
      if (localpart != null && localpart.isNotEmpty) {
        _identityCache[localpart] = identity;
      }
    }
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
    if (lowered == 'user' ||
        lowered == 'uder' ||
        lowered == 'unknown' ||
        lowered.startsWith('group with ')) {
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
    final raw = value?.trim() ?? '';
    if (raw.isEmpty || _looksLikeMatrixId(raw)) return '';

    final extracted = _extractPhone(value);
    if (extracted.isNotEmpty) return extracted;

    final localpart = _matrixLocalpart(raw) ?? raw;
    if (_looksLikeMatrixId(localpart)) return '';
    final digits = localpart.replaceAll(RegExp(r'[^\d]'), '');
    return RegExp(r'^\+?\d{7,15}$').hasMatch(localpart) ? digits : '';
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

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }

  Future<void> _retryEnrichment() async {
    await _reloadContactsAndRepaint(reason: 'retry enrichment');
  }

  Future<void> _reloadContactsAndRepaint({required String reason}) async {
    await _loadSavedContacts(refreshBackend: false);
    final enriched = await _enrichNames(_conversations);
    await _publishPreparedConversations(enriched);
    debugPrint('[ConversationsScreen] contact repaint done reason="$reason"');
  }

  // ===========================================================================
  //  HELPERS
  // ===========================================================================

  void _notifyUnread(List<ChatConversation> convs) {
    final total = convs.fold(0, (sum, c) => sum + c.unreadCount);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onUnreadCountUpdated?.call(total);
    });
  }

  String _sanitize(String s) =>
      String.fromCharCodes(s.runes.where((r) => r <= 0xD7FF || r >= 0xE000));

  String _conversationPreview(String raw) {
    var text = _sanitize(raw).trim();
    if (text.startsWith('> ')) {
      final parts = text.split('\n\n');
      if (parts.length > 1) {
        text = parts.sublist(1).join('\n\n').trim();
      }
    }
    text = text.replaceFirst(RegExp(r'^<[^>]+>\s*'), '').trim();
    text =
        text.replaceFirst(RegExp(r'^@[A-Za-z0-9._=-]+:[^\s]+\s*'), '').trim();
    return text;
  }

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
    final name = _sanitize(_conversationTitle(conv));
    final avatar = _avatarForConversation(conv);
    final localAvatarPath = _localAvatarPathForConversation(conv);
    final selected = _selectedIds.contains(conv.id);

    return ConversationTile(
      name: name,
      lastMessage: _conversationPreview(conv.lastMessage),
      time: _formatTime(conv.lastMessageTime),
      avatarUrl: avatar,
      localAvatarPath: localAvatarPath,
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
            children: const [
              _ConversationLoadingRow(),
              _ConversationLoadingRow(),
            ],
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
          itemBuilder:
              (_, i) => KeyedSubtree(
                key: ValueKey(_conversations[i].id),
                child: _buildTile(_conversations[i]),
              ),
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
                      await _publishPreparedConversations(enriched);
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

class _ConversationLoadingRow extends StatelessWidget {
  const _ConversationLoadingRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF23262C),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 18,
                  width: 120,
                  decoration: BoxDecoration(
                    color: const Color(0xFF23262C),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 14,
                  width: 180,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1D22),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(
                  color: Color(0xFF2A2D34),
                  thickness: 0.5,
                  height: 0,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
