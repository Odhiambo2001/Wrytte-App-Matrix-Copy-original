import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/user_service.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _messageChannelId = 'wrytte_messages';
  static const _callChannelId = 'wrytte_calls';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final Set<String> _notifiedMessageIds = <String>{};
  final Set<String> _notifiedCallIds = <String>{};
  final Set<String> _notifiedRemoteIds = <String>{};

  StreamSubscription<ChatMessage>? _messageSub;
  StreamSubscription<CallData>? _callSub;
  StreamSubscription<RemoteMessage>? _foregroundPushSub;
  StreamSubscription<RemoteMessage>? _openedPushSub;
  StreamSubscription<String>? _tokenRefreshSub;
  bool _initialized = false;
  String? _currentUserId;
  String? _lastRegisteredToken;

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
    await initialize();
    if (kIsWeb) return;

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

    unawaited(ChatService().connect());
  }

  Future<void> stop() async {
    final token = _lastRegisteredToken ?? await _messaging.getToken();
    if (token != null && token.isNotEmpty) {
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
    _notifiedMessageIds.clear();
    _notifiedCallIds.clear();
    _notifiedRemoteIds.clear();
  }

  Future<void> _registerFcmToken(String token) async {
    final cleaned = token.trim();
    if (cleaned.isEmpty) return;
    if (_lastRegisteredToken == cleaned) return;
    try {
      await UserService().updateFcmToken(cleaned);
      _lastRegisteredToken = cleaned;
    } catch (e) {
      debugPrint('[NotificationService] FCM token registration failed: $e');
    }
  }

  Future<void> showRemoteMessage(RemoteMessage message) async {
    await initialize();
    if (kIsWeb) return;

    final id = _remoteId(message);
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

    await _plugin.show(
      id.hashCode,
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

  Future<void> _showMessage(ChatMessage message) async {
    if (!_initialized ||
        message.isDeleted ||
        !_notifiedMessageIds.add(message.id)) {
      return;
    }

    final matrixUserId = MatrixClientService.instance.userId ?? '';
    if (_isOwnSender(message.senderId, matrixUserId)) return;

    final sender = _displayName(
      message.senderName,
      message.senderPhone,
      message.senderId,
    );
    final preview = _messagePreview(message);

    await _plugin.show(
      message.id.hashCode,
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
