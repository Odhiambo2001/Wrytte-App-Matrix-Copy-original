import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wrytte/services/auth/auth_service.dart';

enum BackendRealtimeStatus { disabled, connecting, connected, disconnected }

class BackendRealtimeEvent {
  final String type;
  final Map<String, dynamic> payload;

  const BackendRealtimeEvent({required this.type, required this.payload});
}

class BackendRealtimeService {
  BackendRealtimeService._();
  static final BackendRealtimeService instance = BackendRealtimeService._();

  static const _endpoint = String.fromEnvironment(
    'WRYTTE_BACKEND_WS_URL',
    defaultValue: '',
  );

  static const _heartbeatInterval = Duration(seconds: 25);
  static const _initialReconnectDelay = Duration(seconds: 2);
  static const _maxReconnectDelay = Duration(seconds: 30);

  final _eventController = StreamController<BackendRealtimeEvent>.broadcast();
  final _statusController = StreamController<BackendRealtimeStatus>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  Duration _reconnectDelay = _initialReconnectDelay;
  bool _shouldStayConnected = false;
  bool _connecting = false;
  BackendRealtimeStatus _status = BackendRealtimeStatus.disabled;

  Stream<BackendRealtimeEvent> get events => _eventController.stream;
  Stream<BackendRealtimeStatus> get statusStream => _statusController.stream;
  BackendRealtimeStatus get status => _status;
  bool get isEnabled => _endpoint.trim().isNotEmpty;

  Future<void> connect() async {
    if (!isEnabled) {
      _setStatus(BackendRealtimeStatus.disabled);
      return;
    }
    _shouldStayConnected = true;
    if (_connecting || _channel != null) return;

    _connecting = true;
    _setStatus(BackendRealtimeStatus.connecting);
    try {
      final token = await AuthService.instance.getValidBackendToken();
      if (token == null || token.trim().isEmpty) {
        throw StateError('Backend auth token is missing.');
      }

      final uri = _authenticatedUri(token);
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (error, stackTrace) {
          debugPrint('[BackendRealtime] socket error: $error');
          _handleDisconnect();
        },
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
      _reconnectDelay = _initialReconnectDelay;
      _startHeartbeat();
      _setStatus(BackendRealtimeStatus.connected);
      debugPrint('[BackendRealtime] connected $uri');
    } catch (e) {
      debugPrint('[BackendRealtime] connect failed: $e');
      await _closeChannel();
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  Future<void> disconnect() async {
    _shouldStayConnected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeChannel();
    _setStatus(
      isEnabled
          ? BackendRealtimeStatus.disconnected
          : BackendRealtimeStatus.disabled,
    );
  }

  void send(String type, [Map<String, dynamic> payload = const {}]) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode({'type': type, 'payload': payload}));
  }

  Uri _authenticatedUri(String token) {
    final raw = _endpoint.trim();
    final withToken =
        raw.contains('{token}')
            ? raw.replaceAll('{token}', Uri.encodeComponent(token))
            : raw;
    final uri = Uri.parse(withToken);
    if (raw.contains('{token}')) return uri;

    final query = Map<String, String>.from(uri.queryParameters);
    query.putIfAbsent('access_token', () => token);
    return uri.replace(queryParameters: query);
  }

  void _handleMessage(dynamic raw) {
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is! Map) return;
      final type = decoded['type']?.toString() ?? 'message';
      final payloadRaw = decoded['payload'];
      final payload =
          payloadRaw is Map
              ? payloadRaw.map((key, value) => MapEntry(key.toString(), value))
              : <String, dynamic>{'data': decoded};

      if (_isSessionEvent(type)) {
        unawaited(_reconnectWithFreshToken());
      }

      _eventController.add(BackendRealtimeEvent(type: type, payload: payload));
    } catch (e) {
      debugPrint('[BackendRealtime] bad message: $e');
    }
  }

  bool _isSessionEvent(String type) {
    final normalized = type.trim().toLowerCase();
    return normalized == 'token_invalidated' ||
        normalized == 'session_invalidated' ||
        normalized == 'auth_required';
  }

  Future<void> _reconnectWithFreshToken() async {
    if (!_shouldStayConnected) return;
    await _closeChannel();
    await connect();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      send('ping', {'sentAt': DateTime.now().toUtc().toIso8601String()});
    });
  }

  void _handleDisconnect() {
    unawaited(_closeChannel());
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_shouldStayConnected || !isEnabled) {
      _setStatus(BackendRealtimeStatus.disconnected);
      return;
    }
    _setStatus(BackendRealtimeStatus.disconnected);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, connect);
    final nextSeconds = (_reconnectDelay.inSeconds * 2).clamp(
      _initialReconnectDelay.inSeconds,
      _maxReconnectDelay.inSeconds,
    );
    _reconnectDelay = Duration(seconds: nextSeconds);
  }

  Future<void> _closeChannel() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
  }

  void _setStatus(BackendRealtimeStatus next) {
    if (_status == next) return;
    _status = next;
    _statusController.add(next);
  }
}
