import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/user_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/matrix/mute_rooms_service.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _messageChannelId = 'wrytte_messages';
  static const _callChannelId = 'wrytte_calls';
  static const _authChannelId = 'wrytte_auth';
  static const _conversationNotificationIdsKey =
      'wrytte_conversation_notification_ids';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final Set<String> _notifiedMessageIds = <String>{};
  final Set<String> _notifiedCallIds = <String>{};
  final Set<String> _notifiedRemoteIds = <String>{};
  final Map<String, Set<int>> _notificationIdsByConversation = {};
  final Map<String, DateTime> _readMarkersByConversation = {};

  StreamSubscription<ChatMessage>? _messageSub;
  StreamSubscription<CallData>? _callSub;
  StreamSubscription<RemoteMessage>? _foregroundPushSub;
  StreamSubscription<RemoteMessage>? _openedPushSub;
  StreamSubscription<String>? _tokenRefreshSub;
  bool _initialized = false;
  String? _currentUserId;
  String? _lastRegisteredToken;
  DateTime? _localMessageNotificationsStartedAt;
  DateTime? _remoteMessageNotificationsStartedAt;
  bool _matrixPusherReady = false;

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    final androidPlugin =
        _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _messageChannelId,
        'Messages',
        description: 'Incoming chat message notifications',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _authChannelId,
        'Login approvals',
        description: 'One-time codes for approving a Wrytte login',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _callChannelId,
        'Calls',
        description: 'Incoming voice and video call notifications',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await androidPlugin?.requestNotificationsPermission();

    final iosPlugin =
        _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
    await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);

    await _messaging.requestPermission(alert: true, badge: true, sound: true);
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    _initialized = true;
  }

  Future<void> start({required String currentUserId}) async {
    _currentUserId = currentUserId;
    _localMessageNotificationsStartedAt = DateTime.now();
    _remoteMessageNotificationsStartedAt = DateTime.now();
    await initialize();
    if (kIsWeb) return;
    await _seedNotificationStateFromLocalDb();

    _messageSub ??= ChatService().messageStream.listen(_showMessage);
    _callSub ??= CallService.instance.incomingCallStream.listen(_showCall);
    _foregroundPushSub ??= FirebaseMessaging.onMessage.listen(
      showRemoteMessage,
    );
    _openedPushSub ??= FirebaseMessaging.onMessageOpenedApp.listen(
      _handleOpenedPush,
    );
    _tokenRefreshSub ??= _messaging.onTokenRefresh.listen(
      _registerFcmToken,
      onError: (Object e) {
        debugPrint('[NotificationService] FCM token refresh error: $e');
      },
    );

    final token = await _messaging.getToken();
    debugPrint('[NotificationService] FCM token: $token');
    if (token != null && token.isNotEmpty) {
      await _registerFcmToken(token);
    }

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _handleOpenedPush(initialMessage);
    }

    unawaited(_connectAndRegisterMatrixPusher(token));
  }

  Future<void> stop() async {
    final token = _lastRegisteredToken ?? await _messaging.getToken();
    if (token != null && token.isNotEmpty) {
      await _removeMatrixPusher(token);
      await UserService().removeFcmToken(fcmToken: token);
    }
    await _messageSub?.cancel();
    await _callSub?.cancel();
    await _foregroundPushSub?.cancel();
    await _openedPushSub?.cancel();
    await _tokenRefreshSub?.cancel();
    _messageSub = null;
    _callSub = null;
    _foregroundPushSub = null;
    _openedPushSub = null;
    _tokenRefreshSub = null;
    _currentUserId = null;
    _lastRegisteredToken = null;
    _localMessageNotificationsStartedAt = null;
    _remoteMessageNotificationsStartedAt = null;
    _matrixPusherReady = false;
    _notifiedMessageIds.clear();
    _notifiedCallIds.clear();
    _notifiedRemoteIds.clear();
    _notificationIdsByConversation.clear();
    _readMarkersByConversation.clear();
    unawaited(_saveConversationNotificationIds());
  }

  Future<void> _registerFcmToken(String token) async {
    final cleaned = token.trim();
    if (cleaned.isEmpty) return;
    try {
      if (_lastRegisteredToken != cleaned) {
        await UserService().updateFcmToken(cleaned);
        _lastRegisteredToken = cleaned;
      }
      if (_matrixPusherReady) {
        await _registerMatrixPusher(cleaned);
      }
    } catch (e) {
      debugPrint('[NotificationService] FCM token registration failed: $e');
    }
  }

  Future<void> _connectAndRegisterMatrixPusher(String? token) async {
    try {
      await ChatService().connect();
      _matrixPusherReady = true;
      _remoteMessageNotificationsStartedAt = DateTime.now();
      final cleaned = token?.trim();
      if (cleaned != null && cleaned.isNotEmpty) {
        await _registerMatrixPusher(cleaned);
      }
    } catch (e) {
      debugPrint('[NotificationService] Matrix push connect failed: $e');
    }
  }

  Future<void> _registerMatrixPusher(String token) async {
    try {
      if (!MatrixClientService.instance.isLoggedIn) {
        debugPrint(
          '[NotificationService] Matrix pusher skipped: Matrix not logged in',
        );
        return;
      }
      final client = MatrixClientService.instance.client;
      await client
          .postPusher(
            mx.Pusher(
              appId: MatrixConfig.pushAppId,
              pushkey: token,
              appDisplayName: 'Wrytte',
              deviceDisplayName: client.deviceID ?? 'Wrytte device',
              kind: 'http',
              lang: 'en',
              data: mx.PusherData(
                url: Uri.parse(MatrixConfig.pushGatewayUrl),
                format: 'event_id_only',
              ),
            ),
            append: true,
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('[NotificationService] Matrix pusher registered');
    } catch (e) {
      debugPrint('[NotificationService] Matrix pusher registration failed: $e');
    }
  }

  Future<void> _removeMatrixPusher(String token) async {
    try {
      if (!MatrixClientService.instance.isLoggedIn) return;
      await MatrixClientService.instance.client
          .deletePusher(
            mx.PusherId(appId: MatrixConfig.pushAppId, pushkey: token),
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('[NotificationService] Matrix pusher removed');
    } catch (e) {
      debugPrint('[NotificationService] Matrix pusher removal failed: $e');
    }
  }

  Future<void> showRemoteMessage(RemoteMessage message) async {
    await initialize();
    if (kIsWeb) return;

    final id = _remoteId(message);
    if (await _shouldIgnoreRemoteMessage(message, id)) return;
    if (!_notifiedRemoteIds.add(id) || !_notifiedMessageIds.add(id)) return;

    final notification = message.notification;
    final data = message.data;
    final title =
        notification?.title ??
        _firstNonEmpty([
          data['title'],
          data['senderName'],
          data['sender_name'],
          data['senderPhone'],
          data['sender_phone'],
        ]) ??
        'New message';
    final body =
        notification?.body ??
        _firstNonEmpty([
          data['body'],
          data['message'],
          data['content'],
          data['preview'],
        ]) ??
        'New message';
    final conversationId =
        _firstNonEmpty([data['conversationId'], data['conversation_id']]) ?? '';

    final notificationId = id.hashCode;
    _trackConversationNotification(conversationId, notificationId);

    await _plugin.show(
      notificationId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _messageChannelId,
          'Messages',
          channelDescription: 'Incoming chat message notifications',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          ticker: 'New message',
          playSound: true,
          enableVibration: true,
          visibility: NotificationVisibility.public,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
        ),
      ),
      payload: conversationId.isEmpty ? 'message' : 'message:$conversationId',
    );
  }

  Future<void> showActiveDeviceLoginCode(
    String code,
    String challengeId,
  ) async {
    await initialize();
    if (kIsWeb) return;
    final safeCode = code.trim();
    if (safeCode.isEmpty) return;
    await _plugin.show(
      challengeId.hashCode,
      'Wrytte login approval',
      'Use code $safeCode on the device signing in.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _authChannelId,
          'Login approvals',
          channelDescription: 'One-time codes for approving a Wrytte login',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.message,
          ticker: 'Wrytte login approval',
          playSound: true,
          enableVibration: true,
          visibility: NotificationVisibility.public,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
        ),
      ),
      payload: 'active-device-login:$challengeId',
    );
  }

  Future<void> _showMessage(ChatMessage message) async {
    if (!_initialized ||
        message.isDeleted ||
        !_notifiedMessageIds.add(message.id)) {
      return;
    }

    final matrixUserId = MatrixClientService.instance.userId ?? '';
    if (_isOwnSender(message.senderId, matrixUserId)) return;
    if (await _shouldIgnoreLocalMessage(message)) return;
    if (await MuteRoomsService.instance.isMuted(message.conversationId)) return;

    final sender = _displayName(
      message.senderName,
      message.senderPhone,
      message.senderId,
    );
    final preview = _messagePreview(message);

    final notificationId = message.id.hashCode;
    _trackConversationNotification(message.conversationId, notificationId);

    await _plugin.show(
      notificationId,
      sender,
      preview,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _messageChannelId,
          'Messages',
          channelDescription: 'Incoming chat message notifications',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          ticker: 'New message',
          playSound: true,
          enableVibration: true,
          visibility: NotificationVisibility.public,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
        ),
      ),
      payload: 'message:${message.conversationId}',
    );
  }

  Future<void> _showCall(CallData call) async {
    if (!_initialized || !_notifiedCallIds.add(call.callId)) return;

    final callType = call.isVideo ? 'video' : 'voice';
    final title = '${call.callerName} is calling';
    final body = 'Incoming $callType call';

    await _plugin.show(
      call.callId.hashCode,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _callChannelId,
          'Calls',
          channelDescription: 'Incoming voice and video call notifications',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          ticker: 'Incoming call',
          playSound: true,
          enableVibration: true,
          fullScreenIntent: true,
          visibility: NotificationVisibility.public,
          ongoing: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: 'call:${call.callId}',
    );
  }

  bool _isOwnSender(String senderId, String matrixUserId) {
    final localUserId = _currentUserId;
    if (senderId == matrixUserId || senderId == localUserId) return true;
    if (localUserId == null || localUserId.isEmpty) return false;
    if (senderId.startsWith('@') && senderId.contains(':')) {
      return senderId.substring(1, senderId.indexOf(':')) == localUserId;
    }
    return false;
  }

  Future<void> clearConversationNotifications(String conversationId) async {
    final cleaned = conversationId.trim();
    if (cleaned.isEmpty || kIsWeb) return;
    await _loadConversationNotificationIds();
    final ids = _notificationIdsByConversation.remove(cleaned);
    if (ids == null || ids.isEmpty) return;
    for (final id in ids) {
      await _plugin.cancel(id);
    }
    await _saveConversationNotificationIds();
  }

  void _trackConversationNotification(String conversationId, int id) {
    final cleaned = conversationId.trim();
    if (cleaned.isEmpty) return;
    _notificationIdsByConversation.putIfAbsent(cleaned, () => <int>{}).add(id);
    unawaited(_saveConversationNotificationIds());
  }

  Future<void> _loadConversationNotificationIds() async {
    if (_notificationIdsByConversation.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_conversationNotificationIdsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final conversationId = entry.key.toString().trim();
        if (conversationId.isEmpty || entry.value is! List) continue;
        final ids =
            (entry.value as List)
                .map((value) => int.tryParse(value.toString()))
                .whereType<int>()
                .toSet();
        if (ids.isNotEmpty) {
          _notificationIdsByConversation[conversationId] = ids;
        }
      }
    } catch (e) {
      debugPrint('[NotificationService] notification id cache read failed: $e');
    }
  }

  Future<void> _saveConversationNotificationIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_notificationIdsByConversation.isEmpty) {
        await prefs.remove(_conversationNotificationIdsKey);
        return;
      }
      final encoded = jsonEncode(
        _notificationIdsByConversation.map(
          (key, value) => MapEntry(key, value.toList()),
        ),
      );
      await prefs.setString(_conversationNotificationIdsKey, encoded);
    } catch (e) {
      debugPrint('[NotificationService] notification id cache save failed: $e');
    }
  }

  Future<void> _seedNotificationStateFromLocalDb() async {
    try {
      _readMarkersByConversation
        ..clear()
        ..addAll(await ChatLocalDb.instance.loadConversationReadMarkers());
      _notifiedMessageIds.addAll(
        await ChatLocalDb.instance.loadRecentMessageIds(),
      );
    } catch (e) {
      debugPrint('[NotificationService] local notification seed skipped: $e');
    }
  }

  Future<bool> _shouldIgnoreLocalMessage(ChatMessage message) async {
    if (!MatrixChatService.instance.initialSyncComplete) {
      return true;
    }

    if (!_isLiveIncomingMessage(message)) {
      return true;
    }

    final readAt = _readMarkersByConversation[message.conversationId];

    if (readAt != null && !message.timestamp.isAfter(readAt)) {
      return true;
    }

    return false;
  }

  bool _isLiveIncomingMessage(ChatMessage message) {
    final startedAt = _localMessageNotificationsStartedAt;
    if (startedAt == null) return false;

    // Matrix replays timeline/history during login and reinstall restore.
    // Those messages can be old and already read, so they must update chat UI
    // without producing fresh local notifications.
    return !message.timestamp.isBefore(startedAt);
  }

  String _messagePreview(ChatMessage message) {
    if (message.attachmentType == 'voice') return 'Voice message';
    if (message.attachmentType == 'video') return 'Video message';
    if (message.attachmentType == 'image') return 'Photo';
    if (message.attachmentType == 'file') return 'File';
    final content = message.content.trim();
    if (content.isEmpty) return 'New message';
    return content.length > 120 ? '${content.substring(0, 120)}...' : content;
  }

  String _displayName(String? name, String? phone, String fallback) {
    for (final value in [name, phone, fallback]) {
      final cleaned = value?.trim();
      if (cleaned != null && cleaned.isNotEmpty) return cleaned;
    }
    return 'New message';
  }

  String _remoteId(RemoteMessage message) {
    return _firstNonEmpty([
          message.messageId,
          message.data['event_id'],
          message.data['eventId'],
          message.data['message_id'],
          message.data['messageId'],
          message.data['conversationId'],
          message.data['conversation_id'],
        ]) ??
        DateTime.now().microsecondsSinceEpoch.toString();
  }

  Future<bool> _shouldIgnoreRemoteMessage(
    RemoteMessage message,
    String id,
  ) async {
    final data = message.data;
    final unread = int.tryParse(
      _firstNonEmpty([
            data['unread'],
            data['unreadCount'],
            data['unread_count'],
            data['counts.unread'],
          ]) ??
          '',
    );
    if (unread != null && unread <= 0) return true;

    final eventId =
        _firstNonEmpty([
          data['event_id'],
          data['eventId'],
          data['message_id'],
          data['messageId'],
          id,
        ]) ??
        '';
    if (eventId.isEmpty) return false;

    try {
      final conversationId =
          _firstNonEmpty([data['conversationId'], data['conversation_id']]) ??
          '';
      if (conversationId.isNotEmpty &&
          await MuteRoomsService.instance.isMuted(conversationId)) {
        debugPrint(
          '[NotificationService] remote push ignored; room is muted room="$conversationId"',
        );
        return true;
      }
      final eventTime = _remoteEventTime(data);
      final remoteStartedAt = _remoteMessageNotificationsStartedAt;
      if (remoteStartedAt != null) {
        if (eventTime != null && !eventTime.isAfter(remoteStartedAt)) {
          debugPrint(
            '[NotificationService] remote push ignored; event before login notification baseline id="$eventId"',
          );
          return true;
        }
        if (eventTime == null &&
            DateTime.now().difference(remoteStartedAt) <
                const Duration(seconds: 45)) {
          debugPrint(
            '[NotificationService] remote push ignored; missing timestamp during login baseline id="$eventId"',
          );
          return true;
        }
      }
      final readAt = _readMarkersByConversation[conversationId];
      if (eventTime != null && readAt != null && !eventTime.isAfter(readAt)) {
        debugPrint(
          '[NotificationService] remote push ignored; event already read id="$eventId"',
        );
        return true;
      }
      if (await ChatLocalDb.instance.hasMessage(eventId)) {
        debugPrint(
          '[NotificationService] remote push ignored; event already cached id="$eventId"',
        );
        return true;
      }
    } catch (e) {
      debugPrint('[NotificationService] remote read check skipped: $e');
    }
    return false;
  }

  DateTime? _remoteEventTime(Map<String, dynamic> data) {
    final raw = _firstNonEmpty([
      data['origin_server_ts'],
      data['originServerTs'],
      data['timestamp'],
      data['ts'],
      data['sent_at'],
      data['sentAt'],
    ]);
    if (raw == null) return null;
    final millis = int.tryParse(raw);
    if (millis != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        millis < 1000000000000 ? millis * 1000 : millis,
      );
    }
    return DateTime.tryParse(raw);
  }

  String? _firstNonEmpty(Iterable<Object?> values) {
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  void _handleOpenedPush(RemoteMessage message) {
    debugPrint(
      '[NotificationService] notification opened data=${message.data}',
    );
  }
}
