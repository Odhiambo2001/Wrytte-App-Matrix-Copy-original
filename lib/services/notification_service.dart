import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _messageChannelId = 'wrytte_messages';
  static const _callChannelId = 'wrytte_calls';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Set<String> _notifiedMessageIds = <String>{};
  final Set<String> _notifiedCallIds = <String>{};

  StreamSubscription<ChatMessage>? _messageSub;
  StreamSubscription<CallData>? _callSub;
  bool _initialized = false;
  String? _currentUserId;

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

    _initialized = true;
  }

  Future<void> start({required String currentUserId}) async {
    _currentUserId = currentUserId;
    await initialize();
    if (kIsWeb) return;

    _messageSub ??= ChatService().messageStream.listen(_showMessage);
    _callSub ??= CallService.instance.incomingCallStream.listen(_showCall);

    unawaited(ChatService().connect());
  }

  Future<void> stop() async {
    await _messageSub?.cancel();
    await _callSub?.cancel();
    _messageSub = null;
    _callSub = null;
    _currentUserId = null;
    _notifiedMessageIds.clear();
    _notifiedCallIds.clear();
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
}
