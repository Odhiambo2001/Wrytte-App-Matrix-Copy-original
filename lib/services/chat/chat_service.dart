// lib/services/chat/chat_service.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart'
    hide MessageStatus;

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

class ChatService {
  ChatService._internal();
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;

  final AuthService _authService = AuthService.instance;

  final _messageController =
      StreamController<ChatMessage>.broadcast();
  final _errorController =
      StreamController<String>.broadcast();
  final _connectionController =
      StreamController<bool>.broadcast();
  final _conversationsController =
      StreamController<List<ChatConversation>>.broadcast();

  Stream<ChatMessage>            get messageStream       =>
      _messageController.stream;
  Stream<String>                 get errorStream         =>
      _errorController.stream;
  Stream<bool>                   get connectionStream    =>
      _connectionController.stream;
  Stream<List<ChatConversation>> get conversationsStream =>
      _conversationsController.stream;

  String? _currentUserId;
  bool    _initialized  = false;
  bool    _isConnected  = false;
  bool    get isConnected => _isConnected;
  Future<void>? _connectFuture;

  final Set<String> _registeredUsers = {};

  String? get currentUserId => _currentUserId;

  final Map<String, ChatConversation>  _conversationsMap = {};
  final Map<String, List<ChatMessage>> _messagesCache    = {};

  // OpenIM returns login status as int:
  // 1 = logged out, 2 = logging in, 3 = logged in
  static const int _kLoginStatusLoggedIn = 3;

  Future<void> connect() async {
    apkLog('CS.connect', 'called  initialized=$_initialized  '
        'isConnected=$_isConnected  connectFutureNull=${_connectFuture == null}');

    if (_isConnected) return;
    if (_connectFuture != null) {
      await _connectFuture;
      return;
    }

    _connectFuture = _connect();
    try {
      await _connectFuture;
    } finally {
      _connectFuture = null;
      apkLog('CS.connect', 'connect() finished  isConnected=$_isConnected');
    }

    if (!_isConnected) {
      throw Exception('ChatService: connect() completed but isConnected=false');
    }
  }

  Future<void> _connect() async {
    apkLog('CS._connect', 'start');
    try {
      apkLog('CS._connect', '[1] calling getCurrentUser()');
      final user = await _authService.getCurrentUser();

      _currentUserId = user?.userId;

      String openImUserIdSafe;
      try {
        openImUserIdSafe = OpenIM.iMManager.userID;
      } catch (_) {
        openImUserIdSafe = '<not-initialised>';
      }
      apkLog('CS._connect', '[1] currentUserId="$_currentUserId"  '
          'OpenIMuserID="$openImUserIdSafe"');

      if (_currentUserId == null || _currentUserId!.isEmpty) {
        apkLog('CS._connect', '[1] no authenticated user — aborting');
        _errorController.add('User not authenticated');
        throw Exception('CS._connect: no authenticated user in secure storage');
      }

      apkLog('CS._connect', '[2] calling _ensureOpenImLoggedIn '
          'userId=$_currentUserId');
      await _ensureOpenImLoggedIn(
        userId: _currentUserId!,
        nickname: user?.username ?? _currentUserId!,
      );
      apkLog('CS._connect', '[2] _ensureOpenImLoggedIn returned');

      apkLog('CS._connect', '[3] registering message listener');
      OpenIM.iMManager.messageManager.setAdvancedMsgListener(
        OnAdvancedMsgListener(
          onRecvNewMessage: (Message msg) {
            apkLog('CS.onRecvNewMessage',
                'clientMsgID=${msg.clientMsgID}');
            final chatMsg = _toChat(msg);
            if (chatMsg != null) {
              _cacheMessage(chatMsg);
              _messageController.add(chatMsg);
            }
          },
          onNewRecvMessageRevoked: (RevokedInfo info) {
            final id = info.clientMsgID ?? '';
            for (final msgs in _messagesCache.values) {
              msgs.removeWhere((m) => m.id == id);
            }
            _emitConversations();
          },
          onMsgDeleted: (Message msg) {
            final id = msg.clientMsgID ?? '';
            for (final msgs in _messagesCache.values) {
              msgs.removeWhere((m) => m.id == id);
            }
            _emitConversations();
          },
          onRecvC2CReadReceipt: (List<ReadReceiptInfo> list) {
            for (final receipt in list) {
              for (final msgs in _messagesCache.values) {
                for (var i = 0; i < msgs.length; i++) {
                  if (receipt.msgIDList?.contains(msgs[i].id) == true) {
                    msgs[i] = msgs[i].copyWith(status: MessageStatus.read);
                  }
                }
              }
            }
            _emitConversations();
          },
        ),
      );

      apkLog('CS._connect', '[4] registering conversation listener');
      await OpenIM.iMManager.conversationManager.setConversationListener(
        OnConversationListener(
          onConversationChanged: (List<ConversationInfo> list) {
            apkLog('CS.convListener',
                'onConversationChanged count=${list.length}');
            _mergeOpenImConversations(list);
          },
          onNewConversation: (List<ConversationInfo> list) {
            apkLog('CS.convListener',
                'onNewConversation count=${list.length}');
            _mergeOpenImConversations(list);
          },
          onSyncServerStart: (_) =>
              apkLog('CS.convListener', 'onSyncServerStart'),
          onSyncServerFinish: (_) {
            apkLog('CS.convListener', 'onSyncServerFinish — refreshing');
            fetchConversations();
          },
          onSyncServerFailed: (_) =>
              apkLog('CS.convListener', 'onSyncServerFailed'),
          onTotalUnreadMessageCountChanged: (int count) =>
              apkLog('CS.convListener', 'unread=$count'),
        ),
      );

      _isConnected = true;
      _initialized = true;
      _connectionController.add(true);
      apkLog('CS._connect', '[5] connected  isConnected=$_isConnected');

      apkLog('CS._connect', '[6] fetchConversations()');
      await fetchConversations();
      apkLog('CS._connect', '[6] fetchConversations() done');

    } catch (e, st) {
      apkLog('CS._connect', 'EXCEPTION: $e');
      apkLog('CS._connect',
          'stacktrace: ${st.toString().split('\n').take(6).join(' | ')}');
      _isConnected = false;
      _errorController.add('Connection failed: $e');
      _connectionController.add(false);
      rethrow;
    }
  }

  Future<void> _waitForConnection() async {
    apkLog('CS._wait', 'start  isConnected=$_isConnected  '
        'connectFutureNull=${_connectFuture == null}');

    if (_isConnected) {
      apkLog('CS._wait', 'already connected');
      return;
    }

    if (_connectFuture != null) {
      apkLog('CS._wait', 'piggybacking on existing connectFuture (timeout 15s)');
      try {
        await _connectFuture!.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            apkLog('CS._wait', 'TIMEOUT waiting for existing connectFuture');
            throw TimeoutException(
              'Timed out waiting for existing connect() to finish',
            );
          },
        );
        apkLog('CS._wait', 'piggyback done  isConnected=$_isConnected');
        return;
      } catch (e) {
        apkLog('CS._wait', 'piggyback threw: $e');
        rethrow;
      }
    }

    apkLog('CS._wait', 'no connect in progress — calling connect() (timeout 15s)');
    try {
      await connect().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          apkLog('CS._wait', 'TIMEOUT in connect()');
          throw TimeoutException(
            'Timed out waiting for ChatService to connect',
          );
        },
      );
      apkLog('CS._wait', 'connect() done  isConnected=$_isConnected');
    } catch (e) {
      apkLog('CS._wait', 'connect() threw: $e');
      rethrow;
    }
  }

  Future<ChatMessage> sendMessage(ChatMessage message) async {
    apkLog('CS.send', 'receiverId="${message.receiverId}"  '
        'isConnected=$_isConnected');

    if (!_isConnected) {
      apkLog('CS.send', 'not connected — calling _waitForConnection');
      await _waitForConnection();
      apkLog('CS.send', 'after wait  isConnected=$_isConnected');
    }

    if (!_isConnected) {
      apkLog('CS.send', 'still not connected after waiting — THROWING');
      throw Exception('ChatService not connected after waiting');
    }

    try {
      final openImReceiverId = _toOpenImUserId(message.receiverId);
      apkLog('CS.send', 'rawReceiverId="${message.receiverId}"  '
          'openImId="$openImReceiverId"  '
          'sender="$_currentUserId"  '
          'OpenIMuser="${_safeOpenImUserId()}"');

      if (openImReceiverId.isEmpty) {
        apkLog('CS.send',
            'openImReceiverId is EMPTY after stripping — '
            'original was "${message.receiverId}". '
            'This will cause a 20s timeout.');
      }
      if (openImReceiverId != message.receiverId) {
        apkLog('CS.send',
            'ID was transformed: "${message.receiverId}" '
            'to "$openImReceiverId" — verify server stores this exact ID');
      }
      if (_currentUserId != _safeOpenImUserId()) {
        apkLog('CS.send',
            'MISMATCH: _currentUserId="$_currentUserId" vs '
            'OpenIM.iMManager.userID="${_safeOpenImUserId()}" — '
            'possible ghost login');
      }

      // getLoginStatus() returns int?  (1=logout, 2=logging, 3=logged)
      try {
        final int? loginStatus = await OpenIM.iMManager
            .getLoginStatus()
            .timeout(const Duration(seconds: 3));
        apkLog('CS.send', 'OpenIM loginStatus=$loginStatus  (3=logged)');
        if (loginStatus != _kLoginStatusLoggedIn) {
          apkLog('CS.send',
              'OpenIM is NOT fully logged in (status=$loginStatus)  '
              'sendMessage may hang.');
        }
      } catch (e) {
        apkLog('CS.send', 'getLoginStatus() threw: $e');
      }

      if (!_registeredUsers.contains(openImReceiverId)) {
        apkLog('CS.send',
            'registering receiver "$openImReceiverId" on backend...');
        final t0 = DateTime.now();
        try {
          await _authService.ensureOpenImUserExists(
            userId: openImReceiverId,
            nickname: message.receiverId,
          );
          final ms = DateTime.now().difference(t0).inMilliseconds;
          _registeredUsers.add(openImReceiverId);
          apkLog('CS.send', 'receiver registered in ${ms}ms');
        } catch (e) {
          final ms = DateTime.now().difference(t0).inMilliseconds;
          apkLog('CS.send',
              'ensureOpenImUserExists threw after ${ms}ms: $e '
              '(continuing anyway)');
          _registeredUsers.add(openImReceiverId);
        }
      } else {
        apkLog('CS.send',
            'receiver "$openImReceiverId" already registered — skipping');
      }

      apkLog('CS.send', 'calling createTextMessage...');
      final t1 = DateTime.now();
      final openImMsg = await OpenIM.iMManager.messageManager
          .createTextMessage(text: message.content);
      apkLog('CS.send',
          'createTextMessage done in '
          '${DateTime.now().difference(t1).inMilliseconds}ms  '
          'clientMsgID=${openImMsg.clientMsgID}');

      apkLog('CS.send', 'calling OpenIM.sendMessage to "$openImReceiverId"...');
      final t2 = DateTime.now();

      await OpenIM.iMManager.messageManager.sendMessage(
        message: openImMsg,
        userID: openImReceiverId,
        offlinePushInfo: OfflinePushInfo(
          title: 'New message',
          desc: message.content,
          iOSBadgeCount: true,
        ),
      );

      apkLog('CS.send',
          'sendMessage ACKed in '
          '${DateTime.now().difference(t2).inMilliseconds}ms');

      final convId = _deriveConvId(_currentUserId ?? '', openImReceiverId);
      final sent = ChatMessage(
        id: openImMsg.clientMsgID ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: convId,
        senderId: _currentUserId ?? '',
        receiverId: openImReceiverId,
        content: message.content,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      );

      _cacheMessage(sent);
      _messageController.add(sent);
      return sent;
    } catch (e, st) {
      apkLog('CS.send', 'ERROR: $e');
      apkLog('CS.send',
          'trace: ${st.toString().split('\n').take(4).join(' | ')}');
      _errorController.add('Failed to send: $e');
      rethrow;
    }
  }

  Future<void> sendVoiceMessage({
    required String receiverID,
    required String filePath,
    required int durationSeconds,
    String senderName = 'New voice message',
  }) async {
    apkLog('CS.sendVoice',
        'receiverID="$receiverID"  duration=${durationSeconds}s');

    if (!_isConnected) {
      apkLog('CS.sendVoice', 'not connected — calling _waitForConnection');
      await _waitForConnection();
    }

    if (!_isConnected) {
      throw Exception('ChatService not connected after waiting');
    }

    try {
      final openImReceiverId = _toOpenImUserId(receiverID);

      if (!_registeredUsers.contains(openImReceiverId)) {
        apkLog('CS.sendVoice',
            'registering receiver "$openImReceiverId" on backend...');
        try {
          await _authService.ensureOpenImUserExists(
            userId: openImReceiverId,
            nickname: receiverID,
          );
          _registeredUsers.add(openImReceiverId);
          apkLog('CS.sendVoice', 'receiver registered');
        } catch (e) {
          apkLog('CS.sendVoice',
              'ensureOpenImUserExists threw: $e (continuing anyway)');
          _registeredUsers.add(openImReceiverId);
        }
      } else {
        apkLog('CS.sendVoice',
            'receiver "$openImReceiverId" already registered — skipping');
      }

      apkLog('CS.sendVoice', 'creating sound message...');
      final openImMsg = await OpenIM.iMManager.messageManager
          .createSoundMessageFromFullPath(
            soundPath: filePath,
            duration: durationSeconds,
          );
      apkLog('CS.sendVoice',
          'sound message created: ${openImMsg.clientMsgID}');
      apkLog('CS.sendVoice',
          'logged-in user: ${_safeOpenImUserId()}  '
          'target user: $openImReceiverId');

      final t0 = DateTime.now();
      final result = await OpenIM.iMManager.messageManager.sendMessage(
        message: openImMsg,
        userID: openImReceiverId,
        offlinePushInfo: OfflinePushInfo(
          title: senderName,
          desc: 'Voice message',
          iOSBadgeCount: true,
        ),
      );
      apkLog('CS.sendVoice',
          'send result: $result  '
          'in ${DateTime.now().difference(t0).inMilliseconds}ms');

      final convId = _deriveConvId(_currentUserId ?? '', openImReceiverId);
      final local = ChatMessage(
        id: openImMsg.clientMsgID ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: convId,
        senderId: _currentUserId ?? '',
        receiverId: openImReceiverId,
        content: 'Voice message',
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        attachmentUrl: openImMsg.soundElem?.sourceUrl,
        attachmentType: 'voice',
        voiceDuration: durationSeconds,
      );

      _cacheMessage(local);
      _messageController.add(local);
      apkLog('CS.sendVoice', 'voice note sent (${durationSeconds}s)');
    } catch (e, st) {
      apkLog('CS.sendVoice', 'ERROR: $e');
      apkLog('CS.sendVoice',
          'trace: ${st.toString().split('\n').take(4).join(' | ')}');
      _errorController.add('Failed to send voice message: $e');
      rethrow;
    }
  }

  Future<void> _ensureOpenImLoggedIn({
    required String userId,
    required String nickname,
  }) async {
    apkLog('CS._ensureLogin', 'checking login for "$userId"');

    String openImUserIdSafe;
    try {
      openImUserIdSafe = OpenIM.iMManager.userID;
    } catch (_) {
      openImUserIdSafe = '';
    }

    if (openImUserIdSafe.isNotEmpty) {
      try {
        // getLoginStatus() returns int?  (1=logout, 2=logging, 3=logged)
        final int? status = await OpenIM.iMManager
            .getLoginStatus()
            .timeout(const Duration(seconds: 3));
        apkLog('CS._ensureLogin',
            'getLoginStatus=$status  OpenIM.userID="$openImUserIdSafe"');

        if (status == _kLoginStatusLoggedIn &&
            openImUserIdSafe == userId) {
          apkLog('CS._ensureLogin', 'already logged in as $userId');
          return;
        }
        apkLog('CS._ensureLogin',
            'not logged in or wrong user — '
            'status=$status  OpenIM.userID="$openImUserIdSafe"  '
            'expected="$userId"');
      } catch (e) {
        apkLog('CS._ensureLogin', 'getLoginStatus threw: $e');
      }
    } else {
      apkLog('CS._ensureLogin',
          'OpenIM not initialised yet — skipping getLoginStatus check');
    }

    apkLog('CS._ensureLogin', 'fetching OpenIM token...');
    final t0    = DateTime.now();
    final token = await _authService.getOpenImToken();
    apkLog('CS._ensureLogin',
        'getOpenImToken done in '
        '${DateTime.now().difference(t0).inMilliseconds}ms  '
        'tokenNull=${token == null}  tokenEmpty=${token?.isEmpty}');

    if (token == null || token.isEmpty) {
      apkLog('CS._ensureLogin', 'no token — cannot login');
      _errorController.add('No OpenIM token — cannot connect chat');
      throw Exception('_ensureOpenImLoggedIn: no OpenIM token in storage');
    }

    apkLog('CS._ensureLogin', 'calling loginToOpenIM for "$userId"...');
    final t1 = DateTime.now();
    try {
      await _authService.loginToOpenIM(
        userId:   userId,
        nickname: nickname,
        imToken:  token,
      );
      apkLog('CS._ensureLogin',
          'loginToOpenIM returned in '
          '${DateTime.now().difference(t1).inMilliseconds}ms');
    } catch (e) {
      apkLog('CS._ensureLogin', 'loginToOpenIM threw: $e');
      rethrow;
    }

    // Poll for login completion instead of a single hard timeout.
    // The SDK fires an async internal handshake after login() returns,
    // so a single check races and loses.
    apkLog('CS._ensureLogin', 'polling post-login status (up to 10s)...');
    int? finalStatus;
    for (var i = 0; i < 10; i++) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        finalStatus = await OpenIM.iMManager
            .getLoginStatus()
            .timeout(const Duration(seconds: 2));
        apkLog('CS._ensureLogin',
            'poll[$i] status=$finalStatus  '
            'OpenIM.userID="${_safeOpenImUserId()}"');
        if (finalStatus == _kLoginStatusLoggedIn) break;
      } catch (e) {
        apkLog('CS._ensureLogin', 'poll[$i] threw: $e — retrying');
      }
    }

    if (finalStatus != _kLoginStatusLoggedIn) {
      apkLog('CS._ensureLogin',
          'login did not complete after polling: status=$finalStatus');
      throw Exception(
          'OpenIM login did not complete after polling '
          '(status=$finalStatus)');
    }
    apkLog('CS._ensureLogin',
        'login complete for "$userId"  '
        'OpenIM.userID="${_safeOpenImUserId()}"');
  }

  String _safeOpenImUserId() {
    try {
      return OpenIM.iMManager.userID;
    } catch (_) {
      return '<not-initialised>';
    }
  }

  Future<List<ChatMessage>> fetchMessageHistory({
    required String conversationID,
    Message? startMsg,
    int count = 40,
  }) async {
    try {
      final AdvancedMessage result = await OpenIM
          .iMManager.messageManager
          .getAdvancedHistoryMessageList(
            conversationID: conversationID,
            startMsg: startMsg,
            count: count,
          );

      final List<ChatMessage> messages = [];
      for (final msg in result.messageList ?? <Message>[]) {
        final chatMsg = _toChat(msg);
        if (chatMsg != null) {
          messages.add(chatMsg);
          _cacheMessage(chatMsg);
        }
      }

      apkLog('CS.fetchHistory',
          '${messages.length} msgs for conv $conversationID');
      return messages;
    } catch (e) {
      apkLog('CS.fetchHistory', 'ERROR: $e');
      return [];
    }
  }

  Future<void> fetchConversations({int offset = 0, int count = 100}) async {
    try {
      final List<ConversationInfo> convs = await OpenIM
          .iMManager.conversationManager
          .getConversationListSplit(offset: offset, count: count);
      apkLog('CS.fetchConvs', '${convs.length} conversations loaded');
      _mergeOpenImConversations(convs);
    } catch (e) {
      apkLog('CS.fetchConvs', 'ERROR: $e');
    }
  }

  Future<void> markConversationAsRead(String conversationId) async {
    try {
      await OpenIM.iMManager.conversationManager
          .markConversationMessageAsRead(conversationID: conversationId);
      if (_conversationsMap.containsKey(conversationId)) {
        _conversationsMap[conversationId] =
            _conversationsMap[conversationId]!.copyWith(unreadCount: 0);
        _emitConversations();
      }
    } catch (e) {
      apkLog('CS.markRead', 'ERROR: $e');
    }
  }

  List<ChatMessage> getConversationMessages(String conversationId) {
    final msgs =
        List<ChatMessage>.from(_messagesCache[conversationId] ?? []);
    msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return msgs;
  }

  Future<String?> getOpenImConversationId(String otherUserId) async {
    try {
      final info = await OpenIM.iMManager.conversationManager
          .getOneConversation(
            sourceID: _toOpenImUserId(otherUserId),
            sessionType: ConversationType.single,
          );
      return info.conversationID;
    } catch (e) {
      apkLog('CS.getConvId', 'ERROR: $e');
      return null;
    }
  }

  Future<void> disconnect() async {
    if (!_isConnected) return;
    await reset();
  }

  Future<void> reset() async {
    apkLog('CS.reset', 'resetting ChatService');
    _isConnected   = false;
    _initialized   = false;
    _connectFuture = null;
    _currentUserId = null;
    _conversationsMap.clear();
    _messagesCache.clear();
    _registeredUsers.clear();
    _connectionController.add(false);
    apkLog('CS.reset', 'reset done');
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _errorController.close();
    _connectionController.close();
    _conversationsController.close();
  }

  ChatMessage? _toChat(Message msg) {
    final senderId   = msg.sendID ?? '';
    final receiverId = msg.recvID ?? '';
    final msgId      = msg.clientMsgID ?? msg.serverMsgID ?? '';
    if (senderId.isEmpty || msgId.isEmpty) return null;

    final convId = _deriveConvId(senderId, receiverId);
    final timestamp = msg.sendTime != null
        ? DateTime.fromMillisecondsSinceEpoch(msg.sendTime!)
        : DateTime.now();

    if (msg.contentType == 103 && msg.soundElem != null) {
      return ChatMessage(
        id: msgId,
        conversationId: convId,
        senderId: senderId,
        receiverId: receiverId,
        content: 'Voice message',
        timestamp: timestamp,
        status: _mapStatus(msg.status),
        attachmentUrl: msg.soundElem!.sourceUrl,
        attachmentType: 'voice',
        voiceDuration: msg.soundElem!.duration,
      );
    }

    return ChatMessage(
      id: msgId,
      conversationId: convId,
      senderId: senderId,
      receiverId: receiverId,
      content: msg.textElem?.content ?? '',
      timestamp: timestamp,
      status: _mapStatus(msg.status),
    );
  }

  ChatConversation _toConversation(ConversationInfo conv) {
    final convId  = conv.conversationID ?? '';
    final otherId = conv.userID ?? '';

    final lastTime = conv.latestMsgSendTime != null
        ? DateTime.fromMillisecondsSinceEpoch(conv.latestMsgSendTime!)
        : DateTime.now();

    String lastMsgContent = conv.showName ?? '';
    try {
      final latestMsg = conv.latestMsg;
      if (latestMsg != null) {
        if (latestMsg.contentType == 103) {
          lastMsgContent = 'Voice message';
        } else {
          final text = latestMsg.textElem?.content;
          if (text != null && text.isNotEmpty) lastMsgContent = text;
        }
      }
    } catch (_) {}

    return ChatConversation(
      id: convId,
      participants: [_currentUserId ?? '', otherId],
      otherUserId: otherId,
      lastMessage: lastMsgContent,
      lastMessageSenderId: '',
      lastMessageTime: lastTime,
      unreadCount: conv.unreadCount ?? 0,
      otherUserName: conv.showName,
      otherUserAvatar: conv.faceURL,
    );
  }

  void _mergeOpenImConversations(List<ConversationInfo> convs) {
    for (final conv in convs) {
      final convId = conv.conversationID ?? '';
      if (convId.isEmpty) continue;
      _conversationsMap[convId] = _toConversation(conv);
    }
    _emitConversations();
  }

  void _cacheMessage(ChatMessage message) {
    final convId = message.conversationId;
    if (_conversationsMap.containsKey(convId)) {
      _conversationsMap[convId] =
          _conversationsMap[convId]!.updateWithMessage(
            message, _currentUserId ?? '');
    } else {
      _conversationsMap[convId] =
          ChatConversation.fromMessage(message, _currentUserId ?? '');
    }
    _messagesCache.putIfAbsent(convId, () => []);
    if (!_messagesCache[convId]!.any((m) => m.id == message.id)) {
      _messagesCache[convId]!.add(message);
    }
    _emitConversations();
  }

  void _emitConversations() {
    final sorted = _conversationsMap.values.toList()
      ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    _conversationsController.add(sorted);
  }

  String _deriveConvId(String id1, String id2) {
    final ids = [id1, id2]..sort();
    return 'si_${ids[0]}_${ids[1]}';
  }

  String _toOpenImUserId(String id) {
    return id.replaceAll(RegExp(r'[^\d]'), '');
  }

  MessageStatus _mapStatus(int? status) {
    switch (status) {
      case 1:  return MessageStatus.sending;
      case 2:  return MessageStatus.sent;
      case 3:  return MessageStatus.failed;
      default: return MessageStatus.sent;
    }
  }
}
