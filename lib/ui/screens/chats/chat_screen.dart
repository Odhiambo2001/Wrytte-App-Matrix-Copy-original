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
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/calls/call_screen.dart';
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

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.receiverId,
    required this.currentUserId,
    required this.title,
    this.avatarUrl,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _focusNode = FocusNode();

  final ChatService _chat = ChatService();
  final CallService _call = CallService.instance;

  StreamSubscription<ChatMessage>? _msgSub;

  final List<ChatMessage> _messages = [];
  final Map<String, String> _optimisticIdByContent = {};

  String? _resolvedConversationId;

  bool _loadingOlder = false;
  bool _hasMoreOlder = true;

  bool _isSending = false;
  bool _matrixAvailable = false;

  UserProfile? _receiverProfile;
  Contact? _savedContact;
  ContactIdentity? _receiverIdentity;
  ChatMessage? _replyingTo;

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
    apkLog(
      'ChatScreen',
      '── initState ──  '
          'convId="${widget.conversationId}"  '
          'receiverId="${widget.receiverId}"  '
          'currentUserId="${widget.currentUserId}"',
    );

    _logger.addListener(_onNewLog);
    _loadInitial();
    _loadReceiverProfile();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _logger.removeListener(_onNewLog);
    _msgSub?.cancel();
    _controller.dispose();
    _scrollCtrl.dispose();
    _debugScrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
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
    final extracted = _extractPhone(value);
    if (extracted.isNotEmpty) return extracted;

    final localpart = _matrixLocalpart(value ?? '');
    final digits = localpart.replaceAll(RegExp(r'[^\d]'), '');
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
    apkLog(
      'ChatScreen._resolveConv',
      'Matrix direct room -> "$_resolvedConversationId"',
    );

    return _resolvedConversationId!;
  }

  Future<String?> _resolveMatrixConversationIdForSend() async {
    if (widget.conversationId.startsWith('!')) {
      _resolvedConversationId = widget.conversationId;
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
    return matrixConversationId;
  }

  // ─── INIT ──────────────────────────────────────────────────────────────────

  Future<void> _loadInitial() async {
    _matrixAvailable = false;
    await _loadLocalMessages();

    apkLog('ChatScreen._loadInitial', 'calling chat.connect()…');

    try {
      await _chat.connect();
      _matrixAvailable = true;
      _resolvedConversationId = null;
    } catch (e) {
      _matrixAvailable = false;
      apkLog('ChatScreen._loadInitial', ' connect() FAILED: $e');
      return; // Matrix unavailable; keep the chat usable with local messages.
    }

    apkLog(
      'ChatScreen._loadInitial',
      'connect() done  isConnected=${_chat.isConnected}',
    ); // use actual flag

    final realConvId = await _resolveConversationId();
    apkLog('ChatScreen._loadInitial', 'realConvId="$realConvId"');

    await _chat.markConversationAsRead(realConvId);

    final msgs = await _chat.fetchMessageHistory(
      conversationID: realConvId,
      count: 40,
    );
    apkLog(
      'ChatScreen._loadInitial',
      'fetchMessageHistory returned ${msgs.length} msgs',
    );

    if (!mounted) return;
    setState(() => _mergeMessages(msgs));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    _msgSub = _chat.messageStream.listen((msg) {
      if (msg.conversationId != realConvId) return;
      if (!mounted) return;
      apkLog(
        'ChatScreen.msgStream',
        'new msg id=${msg.id}  convId=${msg.conversationId}',
      );
      if (_isMine(msg) && _isLocalOutgoingEchoId(msg.id)) {
        apkLog('ChatScreen.reconcile', 'skip local outgoing echo id=${msg.id}');
        return;
      }
      if (_isMine(msg)) {
        unawaited(ChatLocalDb.instance.deleteDuplicateOutgoingEchoesFor(msg));
      }
      setState(() => _upsertMessage(msg));
      if (!_isMine(msg)) {
        unawaited(_chat.markConversationAsRead(realConvId));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });
  }

  Future<void> _loadLocalMessages() async {
    final convId = await _resolveConversationId();
    final msgs = await _chat.loadCachedMessages(convId);
    apkLog(
      'ChatScreen._loadLocalMessages',
      'loaded ${msgs.length} local msgs for "$convId"',
    );
    if (!mounted) return;
    setState(() => _mergeMessages(msgs));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _loadReceiverProfile() async {
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    final profile = await UserProfileService.instance.getProfileByUid(
      widget.receiverId,
    );
    final saved =
        ownerUserId == null || ownerUserId.isEmpty
            ? null
            : await _findSavedContact(ownerUserId, widget.receiverId);
    var identity =
        ownerUserId == null || ownerUserId.isEmpty
            ? null
            : await ContactIdentityCache.instance.findByMatrixId(
              ownerUserId: ownerUserId,
              matrixUserId: widget.receiverId,
            );

    if (ownerUserId != null && ownerUserId.isNotEmpty) {
      final fallbackPhone = _firstPhoneFrom([widget.receiverId, widget.title]);
      await ContactIdentityCache.instance.upsert(
        ownerUserId: ownerUserId,
        matrixUserId: widget.receiverId,
        phone: profile?.phone ?? fallbackPhone,
        profileName: profile?.displayName,
        savedName: saved?.formattedName,
        avatarUrl:
            profile?.hasProfileImage == true
                ? profile!.profileImage
                : widget.avatarUrl,
      );
      identity = await ContactIdentityCache.instance.findByMatrixId(
        ownerUserId: ownerUserId,
        matrixUserId: widget.receiverId,
      );
    }

    if (!mounted) return;
    setState(() {
      _receiverProfile = profile;
      _savedContact = saved;
      _receiverIdentity = identity;
    });
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

  String _chatDisplayName() {
    final savedName = _cleanDisplayName(_savedContact?.formattedName);
    if (savedName.isNotEmpty) return savedName;

    final cachedSaved = _cleanDisplayName(_receiverIdentity?.savedName);
    if (cachedSaved.isNotEmpty) return cachedSaved;

    final cachedPhone = _extractPhone(_receiverIdentity?.phone);
    if (cachedPhone.isNotEmpty) return _formatPhone(cachedPhone);

    for (final candidate in [
      widget.title,
      widget.receiverId,
      ..._messagePeerIdentifiers(),
    ]) {
      final phone = _phoneFromIdentifier(candidate);
      if (phone.isNotEmpty) return _formatPhone(phone);
    }

    return '';
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
    if (_scrollCtrl.position.pixels <= 80 && !_loadingOlder && _hasMoreOlder) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || !_hasMoreOlder) return;
    if (!_matrixAvailable) {
      setState(() => _hasMoreOlder = false);
      return;
    }
    setState(() => _loadingOlder = true);

    final realConvId = await _resolveConversationId();

    try {
      final older = await _chat.fetchMessageHistory(
        conversationID: realConvId,
        count: 40,
      );

      if (older.isEmpty) {
        setState(() {
          _hasMoreOlder = false;
          _loadingOlder = false;
        });
        return;
      }

      final previousMaxScrollExtent =
          _scrollCtrl.hasClients ? _scrollCtrl.position.maxScrollExtent : 0.0;
      setState(() {
        final existingIds = _messages.map((m) => m.id).toSet();
        final newOnes =
            older.where((m) => !existingIds.contains(m.id)).toList();
        if (newOnes.isEmpty) {
          _hasMoreOlder = false;
        }
        _messages.insertAll(0, newOnes);
        _loadingOlder = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          final addedExtent =
              _scrollCtrl.position.maxScrollExtent - previousMaxScrollExtent;
          if (addedExtent > 0) {
            _scrollCtrl.jumpTo(_scrollCtrl.position.pixels + addedExtent);
          }
        }
      });
    } catch (e) {
      apkLog('ChatScreen.loadOlder', ' ERROR: $e');
      if (mounted) setState(() => _loadingOlder = false);
    }
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
      replyToSenderId: reply?.senderId,
      replyPreview:
          reply == null
              ? null
              : (reply.isVoiceNote ? 'Voice note' : reply.content),
    );

    setState(() => _messages.add(optimistic));
    _optimisticIdByContent['${normalisedReceiverId}_$text'] = optimistic.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

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
      attachmentType: 'voice',
      voiceDuration: durationSeconds,
    );

    setState(() => _messages.add(placeholder));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

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

  // ─── CALL ──────────────────────────────────────────────────────────────────

  Future<void> _startCall(CallType type) async {
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

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // ─── MESSAGE HELPERS ───────────────────────────────────────────────────────

  void _mergeMessages(List<ChatMessage> incoming) {
    for (final msg in incoming) {
      _upsertMessage(msg);
    }
    _removeDuplicateOutgoingEchoes();
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
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
    if (candidate.content != sent.content) return false;
    final sameConversation =
        candidate.conversationId == sent.conversationId ||
        candidate.conversationId == widget.conversationId ||
        candidate.conversationId == _resolvedConversationId;
    if (!sameConversation) return false;
    final closeInTime =
        candidate.timestamp.difference(sent.timestamp).inSeconds.abs() < 60;
    return closeInTime &&
        (candidate.status == MessageStatus.sending ||
            _isLocalOutgoingEchoId(candidate.id));
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
                icon:
                    message.isStarred
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                label: message.isStarred ? 'Unstar' : 'Star',
                onTap: () async {
                  Navigator.pop(context);
                  final updated = message.copyWith(
                    isStarred: !message.isStarred,
                  );
                  await _chat.starMessage(message, !message.isStarred);
                  if (!mounted) return;
                  setState(() => _upsertMessage(updated));
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
    final double statusBarH = MediaQuery.of(context).padding.top;
    final double appBarH = statusBarH + kToolbarHeight;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        children: [
          // ── main chat UI ──────────────────────────────────────────────────
          Column(
            children: [
              SizedBox(height: appBarH),
              Expanded(child: _buildMessageList()),
              if (_replyingTo != null) _buildReplyComposerBanner(),
              MessageInputField(
                controller: _controller,
                focusNode: _focusNode,
                isSending: _isSending,
                onSend: _send,
                inputPillHeight: _kInputPillH,
                onVoiceMessage: _sendVoiceNote,
              ),
            ],
          ),

          // ── gradient behind app bar ───────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: appBarH + 20,
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

          // ── app bar ───────────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildAppBar(statusBarH),
          ),

          // ── debug overlay ─────────────────────────────────────────────────
          if (_showDebug) _buildDebugOverlay(appBarH),

          // ── debug toggle button ───────────────────────────────────────────
          Positioned(
            bottom: 120,
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
              _messages.isEmpty
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
                  : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.only(top: 12, bottom: 8),
                    physics: const BouncingScrollPhysics(),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isMine = _isMine(msg);
                      final prev = index > 0 ? _messages[index - 1] : null;
                      final showDate =
                          prev == null ||
                          !_isSameDay(prev.timestamp, msg.timestamp);
                      final showTail = prev == null || _isMine(prev) != isMine;
                      return Column(
                        children: [
                          if (showDate)
                            _buildDateDivider(
                              _formatDateDivider(msg.timestamp),
                            ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onLongPress: () => _showMessageActions(msg),
                            child: MessageBubble(
                              content: msg.content,
                              time: _formatTime(msg.timestamp),
                              isMine: isMine,
                              showTail: showTail,
                              status: isMine ? msg.status : null,
                              isVoiceNote: msg.isVoiceNote,
                              voiceDuration: msg.voiceDuration,
                              audioUrl: msg.attachmentUrl,
                              isForwarded: msg.isForwarded,
                              isStarred: msg.isStarred,
                              isDeleted: msg.isDeleted,
                              replyPreview: msg.replyPreview,
                              replySender: msg.replyToSenderId,
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
    final displayName = _chatDisplayName();
    final fallbackPhone =
        (_receiverIdentity?.phone?.trim().isNotEmpty == true)
            ? _receiverIdentity!.phone!.trim()
            : _firstPhoneFrom([
              widget.receiverId,
              widget.title,
              ..._messagePeerIdentifiers(),
            ]);
    final profileFallbackName =
        _receiverIdentity?.profileName?.trim().isNotEmpty == true
            ? _receiverIdentity!.profileName!.trim()
            : widget.title;
    return Padding(
      padding: EdgeInsets.only(top: statusBarH),
      child: SizedBox(
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
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder:
                            (_) => ProfileScreen(
                              uid: widget.receiverId,
                              fallbackName: profileFallbackName,
                              fallbackPhone:
                                  fallbackPhone.isNotEmpty
                                      ? fallbackPhone
                                      : null,
                              fallbackAvatarUrl: widget.avatarUrl,
                            ),
                      ),
                    );
                    if (mounted) _loadReceiverProfile();
                  },
                  child: SizedBox(
                    height: _kHeaderPillH,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF23262C,
                                  ).withOpacity(0.30),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: const Color(0xFF23262C),
                                    width: 1.0,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 2,
                          top: -2,
                          bottom: -2,
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: UserAvatar(
                              size: _kHeaderPillH + 12,
                              imageUrl:
                                  _receiverProfile?.hasProfileImage == true
                                      ? _receiverProfile!.profileImage
                                      : widget.avatarUrl,
                              name: displayName,
                            ),
                          ),
                        ),
                        Positioned(
                          left: _kHeaderPillH + 14,
                          top: 0,
                          bottom: 0,
                          right: 12,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                'Online',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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
