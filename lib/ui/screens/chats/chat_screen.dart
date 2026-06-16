// lib/ui/screens/chats/chat_screen.dart
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/notification_service.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/calls/call_screen.dart';
import 'package:wrytte/ui/screens/chats/video_message_recorder_screen.dart';
import 'package:wrytte/ui/screens/chats/widgets/message_bubble.dart';
import 'package:wrytte/ui/screens/chats/widgets/message_input.dart';
import 'package:wrytte/ui/screens/profile_screen.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String receiverId;
  final String currentUserId;
  final String title;
  final String? avatarUrl;
  final List<ChatMessage> initialMessages;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.receiverId,
    required this.currentUserId,
    required this.title,
    this.avatarUrl,
    this.initialMessages = const [],
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScrollBehavior extends ScrollBehavior {
  const _ChatScrollBehavior();

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

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _focusNode = FocusNode();

  final ChatService _chat = ChatService();
  final CallService _call = CallService.instance;

  StreamSubscription<List<ChatMessage>>? _messagesSub;

  final List<ChatMessage> _messages = [];
  final List<ChatMessage> _initialStreamBuffer = [];
  final Map<String, String> _optimisticIdByContent = {};

  String? _resolvedConversationId;

  bool _loadingOlder = false;
  bool _loadingInitial = true;
  bool _hasMoreOlder = true;

  bool _isSending = false;
  bool _matrixAvailable = false;

  UserProfile? _receiverProfile;
  ContactIdentity? _receiverIdentity;
  bool _receiverIsSavedContact = false;
  ChatMessage? _replyingTo;
  double? _stableStatusBarH;
  late final String? _stableHeaderAvatarUrl;

  // ── debug overlay ──────────────────────────────────────────────────────────
  bool _showDebug = false;
  final ScrollController _debugScrollCtrl = ScrollController();
  final ApkDebugLogger _logger = ApkDebugLogger.instance;

  static const double _kHeaderPillH = 48.0;
  static const double _kInputPillH = 40.0;

  // ─── LIFECYCLE ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _chat.activateConversationRead(widget.conversationId);
    _stableHeaderAvatarUrl =
        widget.avatarUrl?.trim().isNotEmpty == true ? widget.avatarUrl : null;
    apkLog(
      'ChatScreen',
      '── initState ──  '
          'convId="${widget.conversationId}"  '
          'receiverId="${widget.receiverId}"  '
          'currentUserId="${widget.currentUserId}"',
    );
    if (_isSelfConversation) {
      _logSelfConversationBlocked('open');
    }

    _logger.addListener(_onNewLog);
    if (widget.initialMessages.isNotEmpty) {
      _mergeMessages(widget.initialMessages);
      _loadingInitial = false;
    }
    _focusNode.addListener(_onInputFocusChanged);
    _loadInitial();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stableStatusBarH ??= MediaQuery.viewPaddingOf(context).top;
  }

  @override
  void dispose() {
    _chat.deactivateConversationRead(widget.conversationId);
    final resolvedConversationId = _resolvedConversationId;
    if (resolvedConversationId != null &&
        resolvedConversationId != widget.conversationId) {
      _chat.deactivateConversationRead(resolvedConversationId);
    }
    _logger.removeListener(_onNewLog);
    _messagesSub?.cancel();
    _controller.dispose();
    _focusNode.removeListener(_onInputFocusChanged);
    _scrollCtrl.dispose();
    _debugScrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onInputFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onNewLog() {
    if (_showDebug && mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_debugScrollCtrl.hasClients) {
          _debugScrollCtrl.jumpTo(_debugScrollCtrl.position.maxScrollExtent);
        }
      });
    }
  }

  // ─── RESOLVE CONVERSATION ID ───────────────────────────────────────────────

  String _normaliseId(String id) => id.trim();

  bool get _isSelfConversation {
    final self = _matrixLocalpart(widget.currentUserId);
    final receiver = _matrixLocalpart(widget.receiverId);
    return self.isNotEmpty && receiver.isNotEmpty && self == receiver;
  }

  void _logSelfConversationBlocked(String action) {
    apkLog(
      'ChatScreen.self',
      '$action blocked: receiver is current user '
          'current="${_matrixLocalpart(widget.currentUserId)}" '
          'receiver="${_matrixLocalpart(widget.receiverId)}"',
    );
  }

  void _showSelfConversationError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This contact is linked to your own account.'),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  bool _looksLikePhone(String value) {
    final stripped = value.trim().replaceAll(RegExp(r'[\s\-()+]'), '');
    if (stripped.length < 7 || stripped.length > 15) return false;
    return stripped.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(stripped);
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

    final localpart = _matrixLocalpart(raw);
    if (_looksLikeMatrixId(localpart)) return '';
    final digits = localpart.replaceAll(RegExp(r'[^\d]'), '');
    return RegExp(r'^\+?\d{7,15}$').hasMatch(localpart) ? digits : '';
  }

  bool _looksLikeMatrixId(String value) {
    final trimmed = value.trim();
    final localpart = _matrixLocalpart(trimmed);
    return trimmed.startsWith('@') ||
        trimmed.startsWith('!') ||
        trimmed.contains(':matrix.') ||
        RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(localpart);
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

  String _firstPhoneFrom(Iterable<String?> candidates) {
    for (final candidate in candidates) {
      final phone = _phoneFromIdentifier(candidate);
      if (phone.isNotEmpty) return _formatPhone(phone);
    }
    return '';
  }

  Future<String> _resolveConversationId() async {
    if (_resolvedConversationId != null) return _resolvedConversationId!;

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    apkLog(
      'ChatScreen._resolveConv',
      'raw="${widget.receiverId}"  '
          'normalised="$normalisedReceiverId"  '
          'passedConvId="${widget.conversationId}"',
    );

    if (widget.conversationId.startsWith('!')) {
      _resolvedConversationId = widget.conversationId;
      _chat.activateConversationRead(widget.conversationId);
      apkLog(
        'ChatScreen._resolveConv',
        'used passedConvId → "$_resolvedConversationId"',
      );
      return _resolvedConversationId!;
    }

    if (!_matrixAvailable) {
      apkLog(
        'ChatScreen._resolveConv',
        'Matrix unavailable; using local convId "${widget.conversationId}"',
      );
      return widget.conversationId;
    }

    final matrixConversationId = await _chat.findMatrixConversationId(
      normalisedReceiverId,
    );
    if (matrixConversationId == null) {
      apkLog(
        'ChatScreen._resolveConv',
        'Matrix direct room unavailable; using local convId "${widget.conversationId}"',
      );
      return widget.conversationId;
    }

    _resolvedConversationId = matrixConversationId;
    _chat.activateConversationRead(matrixConversationId);
    apkLog(
      'ChatScreen._resolveConv',
      'Matrix direct room -> "$_resolvedConversationId"',
    );

    return _resolvedConversationId!;
  }

  Future<String?> _resolveMatrixConversationIdForSend() async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('resolve/send room');
      return null;
    }

    if (widget.conversationId.startsWith('!')) {
      _resolvedConversationId = widget.conversationId;
      _chat.activateConversationRead(widget.conversationId);
      return widget.conversationId;
    }

    try {
      apkLog('ChatScreen._resolveSendConv', 'validating Matrix before send...');
      await _chat.connect();
      _matrixAvailable = true;
    } catch (e) {
      _matrixAvailable = false;
      apkLog('ChatScreen._resolveSendConv', 'Matrix connect failed: $e');
      return null;
    }

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final matrixConversationId = await _chat.getMatrixConversationId(
      normalisedReceiverId,
    );
    if (matrixConversationId == null) {
      apkLog(
        'ChatScreen._resolveSendConv',
        'failed to create/reuse Matrix direct room',
      );
      return null;
    }
    _resolvedConversationId = matrixConversationId;
    _chat.activateConversationRead(matrixConversationId);
    return matrixConversationId;
  }

  // ─── INIT ──────────────────────────────────────────────────────────────────

  Future<void> _loadInitial() async {
    _matrixAvailable = false;
    _hasMoreOlder = false;
    await _hydrateAndSubscribe(widget.conversationId);

    apkLog('ChatScreen._loadInitial', 'calling chat.connect()…');

    try {
      await _chat.connect();
      _matrixAvailable = true;
      _resolvedConversationId = null;
    } catch (e) {
      _matrixAvailable = false;
      apkLog('ChatScreen._loadInitial', ' connect() FAILED: $e');
      if (mounted) {
        setState(() => _loadingInitial = false);
      }
      return; // Matrix unavailable; keep the chat usable with local messages.
    }

    apkLog(
      'ChatScreen._loadInitial',
      'connect() done  isConnected=${_chat.isConnected}',
    ); // use actual flag

    final realConvId = await _resolveConversationId();
    _chat.activateConversationRead(realConvId);
    apkLog('ChatScreen._loadInitial', 'realConvId="$realConvId"');

    if (realConvId != widget.conversationId) {
      await _migrateLocalConversationToRoom(realConvId, const []);
      if (!mounted) return;
      setState(() => _normaliseMessagesToConversation(realConvId));
    }

    if (realConvId.startsWith('!')) {
      final restored = await _chat.fetchMessageHistory(
        conversationID: realConvId,
      );
      if (restored.isNotEmpty) {
        _replaceMessagesFromSharedCache(restored);
      }
    }

    await _loadReceiverProfile(publish: false);

    await _chat.markConversationAsRead(realConvId);
    await NotificationService.instance.clearConversationNotifications(
      realConvId,
    );
    if (realConvId != widget.conversationId) {
      await NotificationService.instance.clearConversationNotifications(
        widget.conversationId,
      );
    }

    if (!mounted) return;
    setState(() {
      _mergeMessages(_initialStreamBuffer);
      _initialStreamBuffer.clear();
      _loadingInitial = false;
    });

    await _hydrateAndSubscribe(realConvId, publishHydrated: false);
  }

  Future<void> _hydrateAndSubscribe(
    String convId, {
    bool publishHydrated = true,
  }) async {
    final msgs = await _chat.hydrateConversation(convId);
    apkLog(
      'ChatScreen._hydrateAndSubscribe',
      'hydrated ${msgs.length} msgs for "$convId"',
    );
    if (mounted && (msgs.isNotEmpty || _messages.isEmpty)) {
      if (!publishHydrated || _loadingInitial) {
        _replaceMessagesFromSharedCache(msgs);
      } else {
        setState(() => _replaceMessagesFromSharedCache(msgs));
        if (_receiverProfile == null && _receiverIdentity == null) {
          unawaited(_loadReceiverProfile(forceRefresh: false));
        }
      }
    }

    await _messagesSub?.cancel();
    _messagesSub = _chat.messagesStreamFor(convId).listen((messages) {
      if (!mounted) return;
      apkLog('ChatScreen.roomStream', 'room="$convId" msgs=${messages.length}');
      if (messages.isEmpty && _messages.isNotEmpty) return;
      if (_loadingInitial) {
        _initialStreamBuffer
          ..clear()
          ..addAll(messages);
        return;
      }
      setState(() => _replaceMessagesFromSharedCache(messages));
      final currentConv = _resolvedConversationId ?? widget.conversationId;
      if (convId == currentConv && messages.any((m) => !_isMine(m))) {
        unawaited(_chat.markConversationAsRead(convId));
        unawaited(
          NotificationService.instance.clearConversationNotifications(convId),
        );
      }
    });
  }

  Future<void> _migrateLocalConversationToRoom(
    String roomId,
    List<ChatMessage> roomCached,
  ) async {
    if (roomId == widget.conversationId) return;
    final combined = <ChatMessage>[..._messages, ...roomCached]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final latest =
        combined.isNotEmpty
            ? combined.last
            : ChatMessage(
              id: 'empty_$roomId',
              conversationId: roomId,
              senderId: '',
              receiverId: widget.receiverId,
              content: '',
              timestamp: DateTime.now(),
              status: MessageStatus.sent,
            );
    final roomConversation = ChatConversation.fromMessage(
      latest.copyWith(conversationId: roomId),
      widget.currentUserId,
    ).copyWith(otherUserName: widget.title, otherUserAvatar: widget.avatarUrl);

    await ChatLocalDb.instance.migrateConversationId(
      oldConversationId: widget.conversationId,
      roomConversation: roomConversation,
    );
    apkLog(
      'ChatScreen._loadInitial',
      'migrated local conversation "${widget.conversationId}" -> "$roomId"',
    );
  }

  Future<void> _loadReceiverProfile({
    bool publish = true,
    bool forceRefresh = true,
  }) async {
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    final profileUid = _profilePeerId();
    if (profileUid == null) return;
    final fallbackPhone = _firstPhoneFrom([profileUid, widget.title]);
    final profile = await UserProfileService.instance.getProfileByUid(
      profileUid,
      phone: fallbackPhone,
      forceRefresh: forceRefresh,
    );

    final matrixProfile = await _loadMatrixProfile(profileUid);
    final saved =
        ownerUserId == null || ownerUserId.isEmpty
            ? null
            : await _findSavedContact(ownerUserId, profileUid);
    var identity =
        ownerUserId == null || ownerUserId.isEmpty
            ? null
            : await ContactIdentityCache.instance.findByMatrixId(
              ownerUserId: ownerUserId,
              matrixUserId: profileUid,
            );

    if (ownerUserId != null && ownerUserId.isNotEmpty && saved == null) {
      await ContactIdentityCache.instance.clearSavedName(
        ownerUserId: ownerUserId,
        matrixUserId: profileUid,
      );
      identity = await ContactIdentityCache.instance.findByMatrixId(
        ownerUserId: ownerUserId,
        matrixUserId: profileUid,
      );
    }

    if (ownerUserId != null && ownerUserId.isNotEmpty) {
      if (saved != null && profile != null) {
        final nextAvatar =
            profile.hasProfileImage
                ? profile.profileImage
                : matrixProfile?.$2 ?? widget.avatarUrl;
        if (nextAvatar?.trim().isNotEmpty == true &&
            nextAvatar?.trim() != widget.avatarUrl?.trim()) {
          await AvatarPreloadService.replace(
            oldUrl: widget.avatarUrl,
            newUrl: nextAvatar,
          );
        }
        final refreshedContact =
            await ContactLocalDb.refreshPublicProfileFields(
              ownerUserId: ownerUserId,
              wrytteUserId: profileUid,
              phone: profile.phone.isNotEmpty ? profile.phone : fallbackPhone,
              avatarUrl: nextAvatar,
              bio: profile.bio,
            );
        if (refreshedContact != null) {
          await ChatService().applySavedContact(refreshedContact);
        }
      }
      await ContactIdentityCache.instance.upsert(
        ownerUserId: ownerUserId,
        matrixUserId: profileUid,
        phone: profile?.phone ?? fallbackPhone,
        profileName:
            _cleanDisplayName(profile?.displayName).isNotEmpty
                ? profile?.displayName
                : matrixProfile?.$1,
        savedName: saved?.formattedName,
        avatarUrl:
            profile?.hasProfileImage == true
                ? profile!.profileImage
                : matrixProfile?.$2 ?? widget.avatarUrl,
        bio: profile?.bio,
      );
      identity = await ContactIdentityCache.instance.findByMatrixId(
        ownerUserId: ownerUserId,
        matrixUserId: profileUid,
      );
    }

    final nextAvatar =
        profile?.hasProfileImage == true
            ? profile!.profileImage
            : identity?.avatarUrl ?? widget.avatarUrl;
    unawaited(AvatarPreloadService.warm(nextAvatar));

    if (!mounted) return;
    if (publish) {
      setState(() {
        _receiverProfile = profile;
        _receiverIdentity = identity;
        _receiverIsSavedContact = saved != null;
      });
    } else {
      _receiverProfile = profile;
      _receiverIdentity = identity;
      _receiverIsSavedContact = saved != null;
    }
    await _persistResolvedReceiverInfo();
  }

  String? _profilePeerId() {
    for (final candidate in [
      _receiverIdentity?.matrixUserId,
      widget.receiverId,
      ..._messagePeerIdentifiers(),
    ]) {
      final value = candidate?.trim() ?? '';
      if (_isValidMatrixUserId(value) && !_isOwnMatrixId(value)) {
        return value;
      }
    }
    return null;
  }

  Future<Contact?> _findSavedContact(String ownerUserId, String uid) async {
    final targetLocalpart = _matrixLocalpart(uid);
    final contacts = await ContactService().getMatrixContactsCached(
      ownerUserId,
    );
    for (final contact in contacts) {
      final contactId = contact.wrytteUserId;
      if (contactId == null || contactId.isEmpty) continue;
      if (_matrixLocalpart(contactId) == targetLocalpart) return contact;
    }
    return null;
  }

  Future<(String?, String?)?> _loadMatrixProfile(String uid) async {
    try {
      if (!MatrixClientService.instance.isLoggedIn) return null;
      final matrixUserId = _toMatrixUserId(uid);
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

  String get _resolvedHeaderName {
    if (_receiverIsSavedContact) {
      final savedName = _cleanDisplayName(_receiverIdentity?.savedName);
      if (savedName.isNotEmpty) return savedName;
    }

    final phone = _firstPhoneFrom([
      _receiverIdentity?.phone,
      _receiverProfile?.phone,
      widget.receiverId,
      widget.title,
      ..._messagePeerIdentifiers(),
    ]);
    return phone.isNotEmpty ? _formatPhone(phone) : '';
  }

  Future<void> _persistResolvedReceiverInfo() async {
    final name = _resolvedHeaderName.trim();
    final avatar =
        _receiverProfile?.hasProfileImage == true
            ? _receiverProfile!.profileImage
            : _receiverIdentity?.avatarUrl ?? widget.avatarUrl;
    if (name.isEmpty && (avatar ?? '').trim().isEmpty) return;
    try {
      await ChatLocalDb.instance.updateConversationUserInfo(
        conversationId: _resolvedConversationId ?? widget.conversationId,
        name: name,
        avatar: avatar,
      );
    } catch (e) {
      debugPrint('[ChatScreen] receiver info persist skipped: $e');
    }
  }

  Iterable<String> _messagePeerIdentifiers() sync* {
    for (final message in _messages.reversed) {
      if (_isMine(message)) {
        yield message.receiverId;
      } else {
        yield message.senderId;
      }
    }
  }

  String _cleanDisplayName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty || _looksLikePhone(trimmed)) return '';
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return '';
    }
    if (trimmed.startsWith('@') && trimmed.contains(':')) return '';
    if (trimmed.startsWith('!') && trimmed.contains(':')) return '';
    if (RegExp(r'^[a-f0-9]{24,}$', caseSensitive: false).hasMatch(trimmed)) {
      return '';
    }
    return trimmed;
  }

  // ─── PAGINATION ────────────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.maxScrollExtent <= 0) return;
    final nearOldest =
        _scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 80;
    if (nearOldest && !_loadingOlder && _hasMoreOlder) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || !_hasMoreOlder) return;
    setState(() {
      _hasMoreOlder = false;
      _loadingOlder = false;
    });
  }

  // ─── SEND TEXT ─────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _controller.text.trim();
    apkLog(
      'ChatScreen._send',
      'text="${text.length > 40 ? text.substring(0, 40) : text}"  '
          'isSending=$_isSending  '
          'textEmpty=${text.isEmpty}',
    );

    if (text.isEmpty || _isSending) return;
    if (_isSelfConversation) {
      _logSelfConversationBlocked('send');
      _showSelfConversationError();
      return;
    }

    _controller.clear();
    final reply = _replyingTo;
    setState(() {
      _isSending = true;
      _replyingTo = null;
    });

    final normalisedReceiverId = _normaliseId(widget.receiverId);

    final optimistic = ChatMessage(
      id: 'opt_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: _resolvedConversationId ?? widget.conversationId,
      senderId: widget.currentUserId,
      receiverId: normalisedReceiverId,
      content: text,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      replyToMessageId: reply?.id,
      replyToSenderId: _replySenderIdForOutgoingReply(reply),
      replyPreview:
          reply == null
              ? null
              : (reply.isVoiceNote ? 'Voice note' : reply.content),
    );

    setState(() => _messages.add(optimistic));
    _optimisticIdByContent['${normalisedReceiverId}_$text'] = optimistic.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());

    final realConvId = await _resolveMatrixConversationIdForSend();

    apkLog(
      'ChatScreen._send',
      'realConvId="$realConvId"  '
          'normalisedReceiver="$normalisedReceiverId"',
    );

    final outbound = optimistic.copyWith(
      conversationId: realConvId ?? optimistic.conversationId,
    );

    if (!_matrixAvailable || realConvId == null) {
      final local = outbound.copyWith(status: MessageStatus.failed);
      await _saveLocalMessage(local);
      if (mounted) {
        setState(() {
          _replaceOptimisticMessage(optimistic.id, local);
        });
      }
      if (mounted) setState(() => _isSending = false);
      return;
    }

    try {
      apkLog('ChatScreen._send', 'calling chat.sendMessage…');
      final sent = await _chat.sendMessage(outbound);
      apkLog('ChatScreen._send', ' sent  id=${sent.id}  status=${sent.status}');

      await _saveCanonicalSentMessage(sent);
      if (mounted) {
        setState(() => _replaceOptimisticMessage(optimistic.id, sent));
      }
    } catch (e) {
      apkLog('ChatScreen._send', ' SEND FAILED: $e');
      final local = outbound.copyWith(status: MessageStatus.failed);
      await _saveLocalMessage(local);
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == optimistic.id);
          if (idx != -1) {
            _messages[idx] = local;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ─── SEND VOICE ────────────────────────────────────────────────────────────

  Future<void> _saveLocalMessage(ChatMessage message) async {
    await ChatLocalDb.instance.saveMessage(message);
    await ChatLocalDb.instance.saveConversations([
      ChatConversation.fromMessage(message, widget.currentUserId).copyWith(
        otherUserName: widget.title,
        otherUserAvatar: widget.avatarUrl,
      ),
    ]);
  }

  Future<void> _saveCanonicalSentMessage(ChatMessage message) async {
    await ChatLocalDb.instance.deleteDuplicateOutgoingEchoesFor(message);
    await _saveLocalMessage(message);
  }

  Future<void> _sendVoiceNote(String filePath, int durationSeconds) async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('send voice note');
      _showSelfConversationError();
      return;
    }

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final realConvId = await _resolveMatrixConversationIdForSend();
    apkLog(
      'ChatScreen._sendVoice',
      'duration=${durationSeconds}s  receiver="$normalisedReceiverId"',
    );

    if (realConvId == null) {
      apkLog('ChatScreen._sendVoice', 'Matrix room unavailable');
      return;
    }

    final placeholderId = 'voice_${DateTime.now().millisecondsSinceEpoch}';
    final placeholder = ChatMessage(
      id: placeholderId,
      conversationId: realConvId,
      senderId: widget.currentUserId,
      receiverId: normalisedReceiverId,
      content: '',
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      attachmentUrl: filePath,
      attachmentType: 'voice',
      voiceDuration: durationSeconds,
    );

    setState(() => _messages.add(placeholder));
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());

    try {
      await _chat.sendVoiceMessage(
        receiverID: normalisedReceiverId,
        filePath: filePath,
        durationSeconds: durationSeconds,
      );
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == placeholderId));
      }
    } catch (e) {
      apkLog('ChatScreen._sendVoice', ' ERROR: $e');
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == placeholderId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send voice note: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _recordAndSendVideoMessage() async {
    final result = await Navigator.of(context).push<VideoMessageResult>(
      MaterialPageRoute(
        builder:
            (_) => const VideoMessageRecorderScreen(
              maxDuration: Duration(seconds: 60),
            ),
      ),
    );
    if (!mounted || result == null) return;
    await _sendVideoNote(result.filePath, result.durationSeconds);
  }

  Future<void> _sendVideoNote(String filePath, int durationSeconds) async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('send video note');
      _showSelfConversationError();
      return;
    }

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final realConvId = await _resolveMatrixConversationIdForSend();
    apkLog(
      'ChatScreen._sendVideo',
      'duration=${durationSeconds}s  receiver="$normalisedReceiverId"',
    );

    if (realConvId == null) {
      apkLog('ChatScreen._sendVideo', 'Matrix room unavailable');
      return;
    }

    final placeholderId = 'video_${DateTime.now().millisecondsSinceEpoch}';
    final placeholder = ChatMessage(
      id: placeholderId,
      conversationId: realConvId,
      senderId: widget.currentUserId,
      receiverId: normalisedReceiverId,
      content: 'Video message',
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      attachmentUrl: filePath,
      attachmentType: 'video',
      voiceDuration: durationSeconds,
    );

    setState(() => _messages.add(placeholder));
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());

    try {
      await _chat.sendVideoMessage(
        receiverID: normalisedReceiverId,
        filePath: filePath,
        durationSeconds: durationSeconds,
      );
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == placeholderId));
      }
    } catch (e) {
      apkLog('ChatScreen._sendVideo', ' ERROR: $e');
      if (mounted) {
        setState(() => _messages.removeWhere((m) => m.id == placeholderId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send video message: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ─── CALL ──────────────────────────────────────────────────────────────────

  Future<void> _startCall(CallType type) async {
    if (_isSelfConversation) {
      _logSelfConversationBlocked('start call');
      _showSelfConversationError();
      return;
    }

    final normalisedReceiverId = _normaliseId(widget.receiverId);
    final displayName = widget.title;

    try {
      await _call.makeCall(
        receiverId: normalisedReceiverId,
        type: type,
        callerName: widget.currentUserId,
        callerAvatar: '',
      );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => CallScreen(
                remoteUserId: normalisedReceiverId,
                remoteUserName: displayName,
                remoteUserAvatar:
                    _receiverProfile?.hasProfileImage == true
                        ? _receiverProfile!.profileImage
                        : widget.avatarUrl,
                type: type,
                isCaller: true,
              ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not start call: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ─── SCROLL ────────────────────────────────────────────────────────────────

  bool get _shouldLiftShortConversation {
    return _messages.isNotEmpty && _messages.length <= 4;
  }

  void _jumpToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(0);
  }

  // ─── MESSAGE HELPERS ───────────────────────────────────────────────────────

  void _mergeMessages(List<ChatMessage> incoming) {
    for (final msg in incoming) {
      _upsertMessage(msg);
    }
    _removeDuplicateOutgoingEchoes();
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  void _replaceMessagesFromSharedCache(List<ChatMessage> incoming) {
    final optimistic = _messages.where(_isLocalOutgoingEcho).toList();
    _messages
      ..clear()
      ..addAll(incoming)
      ..addAll(
        optimistic.where(
          (candidate) =>
              !incoming.any((m) => _isDuplicateOutgoingEcho(candidate, m)),
        ),
      );
    _removeDuplicateOutgoingEchoes();
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  bool _isLocalOutgoingEcho(ChatMessage message) =>
      _isMine(message) && _isLocalOutgoingEchoId(message.id);

  void _normaliseMessagesToConversation(String conversationId) {
    for (var i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      if (message.conversationId != widget.conversationId) continue;
      _messages[i] = message.copyWith(conversationId: conversationId);
    }
  }

  void _upsertMessage(ChatMessage msg) {
    final exactIdx = _messages.indexWhere((m) => m.id == msg.id);
    if (exactIdx != -1) {
      _messages[exactIdx] = msg;
      return;
    }
    final optimisticId = _matchingOptimisticId(msg);
    if (optimisticId != null) {
      _replaceOptimisticMessage(optimisticId, msg);
      return;
    }
    _messages.add(msg);
  }

  String? _matchingOptimisticId(ChatMessage msg) {
    for (final entry in _optimisticIdByContent.entries) {
      final optimistic = _messages.firstWhere(
        (m) => m.id == entry.value,
        orElse: () => msg,
      );
      if (optimistic.id != entry.value) continue;
      if (optimistic.status != MessageStatus.sending) continue;
      if (!_isMine(optimistic)) continue;
      final sameContent = optimistic.content == msg.content;
      final sameConversation =
          optimistic.conversationId == msg.conversationId ||
          optimistic.conversationId == widget.conversationId ||
          optimistic.conversationId == _resolvedConversationId;
      final sameReceiver =
          optimistic.receiverId == msg.receiverId ||
          optimistic.receiverId == msg.senderId ||
          _matrixLocalpart(optimistic.receiverId) ==
              _matrixLocalpart(msg.receiverId) ||
          _matrixLocalpart(optimistic.receiverId) ==
              _matrixLocalpart(msg.senderId);
      final closeInTime =
          msg.timestamp.difference(optimistic.timestamp).inSeconds.abs() < 60;
      final ownMatrixEcho =
          _isMine(msg) && sameContent && sameConversation && closeInTime;
      if ((sameContent && sameReceiver && closeInTime) || ownMatrixEcho) {
        apkLog(
          'ChatScreen.reconcile',
          'replace optimistic id=${optimistic.id} with Matrix id=${msg.id}',
        );
        return optimistic.id;
      }
    }
    return null;
  }

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  String _toMatrixUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    return '@${_matrixLocalpart(trimmed)}:${MatrixConfig.serverName}';
  }

  void _replaceOptimisticMessage(String optimisticId, ChatMessage sent) {
    _messages.removeWhere((m) => m.id == sent.id && m.id != optimisticId);
    final idx = _messages.indexWhere((m) => m.id == optimisticId);
    if (idx != -1) {
      _messages[idx] = sent;
    } else {
      _upsertMessage(sent);
    }
    _messages.removeWhere((m) => _isDuplicateOutgoingEcho(m, sent));
    _optimisticIdByContent.removeWhere((_, id) => id == optimisticId);
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  void _removeDuplicateOutgoingEchoes() {
    final canonicalOutgoing =
        _messages
            .where((m) => _isMine(m) && !_isLocalOutgoingEchoId(m.id))
            .toList();
    if (canonicalOutgoing.isEmpty) return;
    _messages.removeWhere(
      (candidate) => canonicalOutgoing.any(
        (sent) => _isDuplicateOutgoingEcho(candidate, sent),
      ),
    );
  }

  bool _isDuplicateOutgoingEcho(ChatMessage candidate, ChatMessage sent) {
    if (candidate.id == sent.id) return false;
    if (!_isMine(candidate) || !_isMine(sent)) return false;
    if (!_isLocalOutgoingEchoId(candidate.id)) return false;
    if (candidate.content != sent.content) return false;
    final sameConversation =
        candidate.conversationId == sent.conversationId ||
        candidate.conversationId == widget.conversationId ||
        candidate.conversationId == _resolvedConversationId;
    if (!sameConversation) return false;
    final closeInTime =
        candidate.timestamp.difference(sent.timestamp).inSeconds.abs() < 60;
    return closeInTime;
  }

  bool _isLocalOutgoingEchoId(String id) {
    return id.startsWith('opt_') || id.startsWith('Wrytte-');
  }

  Future<void> _showMessageActions(ChatMessage message) async {
    final isMine = _isMine(message);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111318),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              _messageActionTile(
                icon: Icons.reply,
                label: 'Reply',
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _replyingTo = message);
                  _focusNode.requestFocus();
                },
              ),
              _messageActionTile(
                icon: Icons.shortcut_rounded,
                label: 'Forward',
                onTap: () {
                  Navigator.pop(context);
                  _promptForward(message);
                },
              ),
              _messageActionTile(
                icon: Icons.copy_outlined,
                label: 'Copy',
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: message.content));
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Copied')));
                },
              ),
              _messageActionTile(
                icon: Icons.delete_outline,
                label: 'Delete for me',
                onTap: () async {
                  Navigator.pop(context);
                  await _chat.deleteMessageForMe(message);
                  if (!mounted) return;
                  setState(() {
                    _messages.removeWhere((m) => m.id == message.id);
                  });
                },
              ),
              if (isMine &&
                  message.status != MessageStatus.sending &&
                  message.status != MessageStatus.failed &&
                  !message.id.startsWith('opt_'))
                _messageActionTile(
                  icon: Icons.delete_forever_outlined,
                  label: 'Delete for everyone',
                  destructive: true,
                  onTap: () async {
                    Navigator.pop(context);
                    try {
                      await _chat.deleteMessageForEveryone(message);
                      if (!mounted) return;
                      setState(
                        () => _upsertMessage(
                          message.copyWith(
                            content: '',
                            isDeletedForEveryone: true,
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Could not delete message: $e'),
                          backgroundColor: Colors.redAccent,
                        ),
                      );
                    }
                  },
                ),
              if (message.status == MessageStatus.sending)
                _messageActionTile(
                  icon: Icons.close,
                  label: 'Cancel',
                  onTap: () async {
                    Navigator.pop(context);
                    await _chat.cancelLocalMessage(message);
                    if (!mounted) return;
                    setState(() {
                      _messages.removeWhere((m) => m.id == message.id);
                    });
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _messageActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final color = destructive ? const Color(0xFFFF6B6B) : Colors.white;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }

  Future<void> _promptForward(ChatMessage message) async {
    final controller = TextEditingController();
    final receiver = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF181B22),
            title: const Text(
              'Forward message',
              style: TextStyle(color: Colors.white),
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Phone, Wrytte ID, or Matrix ID',
                hintStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF4DA3FF)),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: const Text('Forward'),
              ),
            ],
          ),
    );
    controller.dispose();
    if (receiver == null || receiver.isEmpty) return;

    try {
      await _chat.forwardMessage(original: message, receiverId: receiver);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Message forwarded')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not forward message: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  // ─── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final double statusBarH = _stableStatusBarH ?? mediaQuery.viewPadding.top;
    final double appBarH = statusBarH + kToolbarHeight;
    final double keyboardInset =
        _focusNode.hasFocus ? mediaQuery.viewInsets.bottom : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      extendBody: true,
      resizeToAvoidBottomInset: false,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Color(0xFF08090B),
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        child: ScrollConfiguration(
          behavior: const _ChatScrollBehavior(),
          child: Stack(
            children: [
              Column(
                children: [
                  _buildAppBar(statusBarH),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: keyboardInset),
                      child: Column(
                        children: [
                          Expanded(child: _buildMessageList()),
                          if (_replyingTo != null) _buildReplyComposerBanner(),
                          MessageInputField(
                            controller: _controller,
                            focusNode: _focusNode,
                            isSending: _isSending,
                            onSend: _send,
                            inputPillHeight: _kInputPillH,
                            onVoiceMessage: _sendVoiceNote,
                            onVideoMessage: _recordAndSendVideoMessage,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              // ── debug overlay ─────────────────────────────────────────────
              if (_showDebug) _buildDebugOverlay(appBarH),

              // ── debug toggle button ───────────────────────────────────────
              Positioned(
                bottom: 120 + keyboardInset,
                right: 12,
                child: GestureDetector(
                  onTap: () => setState(() => _showDebug = !_showDebug),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color:
                          _showDebug
                              ? Colors.orangeAccent
                              : Colors.grey.withOpacity(0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Text('🐛', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── DEBUG OVERLAY ─────────────────────────────────────────────────────────

  Widget _buildDebugOverlay(double topOffset) {
    final lines = _logger.lines;

    return Positioned(
      top: topOffset + 4,
      left: 4,
      right: 4,
      bottom: 140,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.88),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orangeAccent, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── header ───────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: const BoxDecoration(
                color: Colors.orangeAccent,
                borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'APK DEBUG LOG',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  // Copy all logs button
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: lines.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Logs copied to clipboard'),
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'COPY',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  // Clear button
                  GestureDetector(
                    onTap: () {
                      _logger.clear();
                      setState(() {});
                    },
                    child: const Text(
                      'CLR',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Close button
                  GestureDetector(
                    onTap: () => setState(() => _showDebug = false),
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),

            // ── log lines ────────────────────────────────────────────────────
            Expanded(
              child:
                  lines.isEmpty
                      ? const Center(
                        child: Text(
                          'No logs yet.\nTry sending a message.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      )
                      : ListView.builder(
                        controller: _debugScrollCtrl,
                        padding: const EdgeInsets.all(6),
                        itemCount: lines.length,
                        itemBuilder: (_, i) {
                          final line = lines[i];
                          // Colour-code by severity
                          Color c = Colors.white70;
                          if (line.contains('❌') ||
                              line.contains('🚨') ||
                              line.contains('FAIL') ||
                              line.contains('ERROR') ||
                              line.contains('TIMEOUT')) {
                            c = const Color(0xFFFF6B6B);
                          } else if (line.contains('⚠️') ||
                              line.contains('WARN') ||
                              line.contains('MISMATCH')) {
                            c = const Color(0xFFFFD93D);
                          } else if (line.contains('✅')) {
                            c = const Color(0xFF6BCB77);
                          } else if (line.contains('🔄') ||
                              line.contains('⏳')) {
                            c = const Color(0xFF4DA3FF);
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: SelectableText(
                              line,
                              style: TextStyle(
                                color: c,
                                fontSize: 10,
                                fontFamily: 'monospace',
                                height: 1.35,
                              ),
                            ),
                          );
                        },
                      ),
            ),

            // ── summary bar ──────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A2E),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(11),
                ),
              ),
              child: Text(
                'convId: ${_resolvedConversationId ?? "not resolved"}  '
                '|  receiver: ${_normaliseId(widget.receiverId)}  '
                '|  msgs: ${_messages.length}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── MESSAGE LIST ──────────────────────────────────────────────────────────

  Widget _buildMessageList() {
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              _messages.isEmpty && !_loadingInitial
                  ? Center(
                    child: Text(
                      'No messages yet.\nSay hello!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.3),
                        fontSize: 15,
                        height: 1.6,
                      ),
                    ),
                  )
                  : _messages.isEmpty
                  ? const SizedBox.expand()
                  : ListView.builder(
                    controller: _scrollCtrl,
                    reverse: true,
                    padding: const EdgeInsets.only(top: 150, bottom: 12),
                    physics: const ClampingScrollPhysics(),
                    itemCount:
                        _messages.length +
                        (_shouldLiftShortConversation ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (_shouldLiftShortConversation && index == 0) {
                        return const SizedBox(height: 96);
                      }

                      final adjustedIndex =
                          index - (_shouldLiftShortConversation ? 1 : 0);
                      final msgIndex = _messages.length - 1 - adjustedIndex;
                      final msg = _messages[msgIndex];
                      final isMine = _isMine(msg);
                      final previousChronological =
                          msgIndex > 0 ? _messages[msgIndex - 1] : null;
                      final showDate =
                          previousChronological == null ||
                          !_isSameDay(
                            previousChronological.timestamp,
                            msg.timestamp,
                          );
                      final showTail =
                          previousChronological == null ||
                          _isMine(previousChronological) != isMine;
                      return Column(
                        children: [
                          if (showDate)
                            _buildDateDivider(
                              _formatDateDivider(msg.timestamp),
                            ),
                          GestureDetector(
                            key: ValueKey(msg.id),
                            behavior: HitTestBehavior.opaque,
                            onLongPress: () => _showMessageActions(msg),
                            child: MessageBubble(
                              content: msg.content,
                              time: _formatTime(msg.timestamp),
                              isMine: isMine,
                              showTail: showTail,
                              status: isMine ? msg.status : null,
                              isVoiceNote: msg.isVoiceNote,
                              isVideoNote: msg.attachmentType == 'video',
                              voiceDuration: msg.voiceDuration,
                              audioUrl: msg.attachmentUrl,
                              isForwarded: msg.isForwarded,
                              isStarred: msg.isStarred,
                              isDeleted: msg.isDeleted,
                              replyPreview: _replyPreviewDisplayText(
                                msg.replyPreview,
                              ),
                              replySender: _replySenderDisplayName(msg),
                              animateOnMount: true,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
              if (_loadingOlder)
                const Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF4DA3FF),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── APP BAR ───────────────────────────────────────────────────────────────

  Widget _buildAppBar(double statusBarH) {
    final displayName = _resolvedHeaderName;
    final fallbackPhone =
        (_receiverIdentity?.phone?.trim().isNotEmpty == true)
            ? _receiverIdentity!.phone!.trim()
            : _firstPhoneFrom([
              widget.receiverId,
              widget.title,
              ..._messagePeerIdentifiers(),
            ]);
    final profileFallbackName =
        _receiverProfile?.displayName.trim().isNotEmpty == true
            ? _receiverProfile!.displayName.trim()
            : _receiverIdentity?.profileName?.trim().isNotEmpty == true
            ? _receiverIdentity!.profileName!.trim()
            : null;
    final avatarUrl =
        _receiverProfile?.hasProfileImage == true
            ? _receiverProfile!.profileImage
            : _receiverIdentity?.avatarUrl ?? _stableHeaderAvatarUrl;
    final localAvatarPath =
        _receiverProfile?.localProfileImagePath.trim().isNotEmpty == true
            ? _receiverProfile!.localProfileImagePath.trim()
            : null;

    return SizedBox(
      height: statusBarH + kToolbarHeight,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFF08090B)),
        child: Column(
          children: [
            SizedBox(height: statusBarH),
            SizedBox(
              height: kToolbarHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _glassPill(
                      width: _kHeaderPillH,
                      height: _kHeaderPillH,
                      child: const Icon(
                        Icons.arrow_back_ios_new,
                        color: Colors.white,
                        size: 16,
                      ),
                      onTap: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: () async {
                          final profileUid = _profilePeerId();
                          if (profileUid == null) return;
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder:
                                  (_) => ProfileScreen(
                                    uid: profileUid,
                                    fallbackName: profileFallbackName,
                                    fallbackPhone:
                                        fallbackPhone.isNotEmpty
                                            ? fallbackPhone
                                            : null,
                                    fallbackAvatarUrl: avatarUrl,
                                  ),
                            ),
                          );
                          if (mounted) _loadReceiverProfile();
                        },
                        child: SizedBox(
                          height: _kHeaderPillH,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xFF15181D),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFF23262C),
                                width: 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: _kHeaderPillH,
                                  height: _kHeaderPillH,
                                  child: Center(
                                    child: UserAvatar(
                                      size: _kHeaderPillH,
                                      imageUrl: avatarUrl,
                                      localImagePath: localAvatarPath,
                                      name: displayName,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        height: 18,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            displayName,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              height: 1.0,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      SizedBox(
                                        height: 14,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            'Online',
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.5,
                                              ),
                                              fontSize: 12,
                                              height: 1.0,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _glassPill(
                      width: _kHeaderPillH,
                      height: _kHeaderPillH,
                      child: const Icon(
                        Icons.videocam_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                      onTap: () => _startCall(CallType.video),
                    ),
                    const SizedBox(width: 8),
                    _glassPill(
                      width: _kHeaderPillH,
                      height: _kHeaderPillH,
                      child: const Icon(
                        Icons.call_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                      onTap: () => _startCall(CallType.voice),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── HELPERS ───────────────────────────────────────────────────────────────

  bool _isMine(ChatMessage message) {
    final current = widget.currentUserId.trim();
    final sender = message.senderId.trim();
    if (sender == current) return true;
    if (sender.startsWith('@') && sender.contains(':')) {
      return sender.substring(1, sender.indexOf(':')) == current;
    }
    return false;
  }

  String? _replySenderDisplayName(ChatMessage message) {
    final rawSender =
        message.replyToSenderId?.trim().isNotEmpty == true
            ? message.replyToSenderId!.trim()
            : _replySenderIdFromQuotedMessage(message);
    if (rawSender == null || rawSender.isEmpty) return null;

    if (_matrixLocalpart(rawSender) == _matrixLocalpart(widget.currentUserId)) {
      return 'You';
    }

    final receiverLocalpart = _matrixLocalpart(widget.receiverId);
    final senderLocalpart = _matrixLocalpart(rawSender);
    final isKnownPeer =
        senderLocalpart.isNotEmpty &&
        (senderLocalpart == receiverLocalpart ||
            senderLocalpart ==
                _matrixLocalpart(_receiverIdentity?.matrixUserId ?? ''));

    if (isKnownPeer) {
      final savedName = _cleanDisplayName(_receiverIdentity?.savedName);
      if (_receiverIsSavedContact && savedName.isNotEmpty) return savedName;

      final phone = _firstPhoneFrom([
        _receiverIdentity?.phone,
        _receiverProfile?.phone,
        widget.receiverId,
        widget.title,
        rawSender,
        ..._messagePeerIdentifiers(),
      ]);
      if (phone.isNotEmpty) return phone;

      final titleName = _cleanDisplayName(widget.title);
      if (titleName.isNotEmpty) return titleName;

      return null;
    }

    final phone = _firstPhoneFrom([rawSender]);
    if (phone.isNotEmpty) return phone;
    if (_looksLikeMatrixId(rawSender)) return null;

    final cleanName = _cleanDisplayName(rawSender);
    return cleanName.isNotEmpty ? cleanName : null;
  }

  String? _replySenderIdForOutgoingReply(ChatMessage? reply) {
    if (reply == null) return null;
    final sender = reply.senderId.trim();
    if (sender.isNotEmpty) return sender;
    return _isMine(reply) ? widget.currentUserId : widget.receiverId;
  }

  String? _replySenderIdFromQuotedMessage(ChatMessage message) {
    final replyToMessageId = message.replyToMessageId?.trim();
    if (replyToMessageId == null || replyToMessageId.isEmpty) return null;
    for (final candidate in _messages) {
      if (candidate.id != replyToMessageId) continue;
      final sender = candidate.senderId.trim();
      if (sender.isNotEmpty) return sender;
      return _isMine(candidate) ? widget.currentUserId : widget.receiverId;
    }
    return null;
  }

  String? _replyPreviewDisplayText(String? preview) {
    var text = preview?.trim() ?? '';
    if (text.isEmpty) return null;
    text = text.replaceFirst(RegExp(r'^<[^>]+>\s*'), '').trim();
    text =
        text.replaceFirst(RegExp(r'^@[A-Za-z0-9._=-]+:[^\s]+\s*'), '').trim();
    return text.isEmpty ? null : text;
  }

  bool _isValidMatrixUserId(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith('@')) return false;
    if (trimmed.startsWith('@!')) return false;
    return trimmed.split(':').length == 2 && trimmed.split(':').last.isNotEmpty;
  }

  bool _isOwnMatrixId(String value) =>
      _matrixLocalpart(value) == _matrixLocalpart(widget.currentUserId);

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _formatDateDivider(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(date).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';

    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    if (diff > 1 && diff < 7) return weekdays[dt.weekday - 1];

    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final year = dt.year == now.year ? '' : ' ${dt.year}';
    return '${dt.day} ${months[dt.month - 1]}$year';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $period';
  }

  Widget _buildReplyComposerBanner() {
    final message = _replyingTo!;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF181B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF4DA3FF),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isMine(message) ? 'You' : widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9BD2FF),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message.isVoiceNote ? 'Voice note' : message.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.68),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }

  Widget _buildDateDivider(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Divider(color: Colors.white.withOpacity(0.08), height: 1),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withOpacity(0.60),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(color: Colors.white.withOpacity(0.08), height: 1),
          ),
        ],
      ),
    );
  }

  Widget _glassPill({
    required double width,
    required double height,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withOpacity(0.30),
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(color: const Color(0xFF23262C), width: 1.0),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
