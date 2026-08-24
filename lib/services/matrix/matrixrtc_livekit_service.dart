import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' as mx;
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_call_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/call_service.dart' show CallService, CallType;

/// MatrixRTC + LiveKit call coordinator.
///
/// Matrix owns the call membership and ringing state. LiveKit owns the media
/// session. The JWT is requested from the MatrixRTC authorization service using
/// a short-lived Matrix OpenID token; the Matrix access token is never sent to
/// LiveKit.
class MatrixRtcLiveKitService {
  MatrixRtcLiveKitService._();
  static final instance = MatrixRtcLiveKitService._();

  static const _serviceUrl = 'https://matrix.wrytte.com/livekit/jwt';
  static const _sfuUrl = 'wss://matrix.wrytte.com/livekit/sfu';

  String get livekitServiceUrl => _serviceUrl;

  final _incoming = StreamController<LiveKitIncomingCall>.broadcast();
  StreamSubscription<mx.GroupCallSession>? _incomingSub;
  mx.VoIP? _voip;
  LiveKitCall? _active;
  Future<LiveKitCall>? _entering;

  Stream<LiveKitIncomingCall> get incomingCalls => _incoming.stream;
  LiveKitCall? get activeCall => _active;

  Future<void> startListening([mx.WebRTCDelegate? delegate]) async {
    final voip = await MatrixCallService.instance.ensureStarted(
      delegate ?? CallService.instance.matrixRtcDelegate,
    );
    if (identical(_voip, voip) && _incomingSub != null) return;
    await _incomingSub?.cancel();
    _voip = voip;
    _incomingSub = voip.onIncomingGroupCall.stream.listen((group) {
      if (group.backend is! mx.LiveKitBackend) return;
      if (_active != null) return;
      final backend = group.backend as mx.LiveKitBackend;
      _incoming.add(
        LiveKitIncomingCall(
          group: group,
          callerId:
              group.participants.isEmpty ? '' : group.participants.first.userId,
          serviceUrl: backend.livekitServiceUrl,
        ),
      );
    });
  }

  Future<LiveKitCall> startOutgoing({
    required mx.Room room,
    required CallType type,
  }) async {
    final voip = _voip ?? await _ensureVoip();
    final backend = mx.LiveKitBackend(
      livekitServiceUrl: _serviceUrl,
      livekitAlias: room.id,
      e2eeEnabled: false,
    );
    final group = await voip.fetchOrCreateGroupCall(
      room.id,
      room,
      backend,
      'm.call',
      'm.room',
      preShareKey: false,
    );
    return _enter(group, type);
  }

  Future<mx.VoIP> _ensureVoip() async {
    await startListening();
    final voip = _voip;
    if (voip == null) throw StateError('MatrixRTC client is not available.');
    return voip;
  }

  /// Resolves the existing Matrix direct room and starts a MatrixRTC call.
  /// No legacy `m.call.invite` event is sent by this path.
  Future<LiveKitCall> startDirectOutgoing({
    required String receiverId,
    required CallType type,
  }) async {
    await ChatService().connect();
    final roomId = await ChatService().getMatrixConversationId(receiverId);
    if (roomId == null || roomId.isEmpty) {
      throw StateError('Could not resolve a Matrix direct room.');
    }
    final room = MatrixChatService.instance.getRoomById(roomId);
    if (room == null || room.membership != mx.Membership.join) {
      throw StateError('The Matrix direct room is not joined or available.');
    }
    return startOutgoing(room: room, type: type);
  }

  Future<LiveKitCall> accept(
    LiveKitIncomingCall incoming, {
    required CallType type,
  }) => _enter(incoming.group, type);

  Future<LiveKitCall> _enter(mx.GroupCallSession group, CallType type) {
    if (_active != null) {
      return Future<LiveKitCall>.error(
        StateError('A call is already active on this device.'),
      );
    }
    if (_entering != null) {
      return Future<LiveKitCall>.error(
        StateError('Call setup is already in progress.'),
      );
    }

    final enterFuture = _enterInternal(group, type);
    _entering = enterFuture;
    return enterFuture.whenComplete(() {
      if (identical(_entering, enterFuture)) {
        _entering = null;
      }
    });
  }

  Future<LiveKitCall> _enterInternal(
    mx.GroupCallSession group,
    CallType type,
  ) async {
    // A failed earlier attempt may have published a local MatrixRTC membership
    // while never receiving a LiveKit token. Clear that stale local state
    // before entering again.
    if (group.state == mx.GroupCallState.entered) {
      await group.leave();
    }

    lk.Room? room;
    try {
      final backend = group.backend as mx.LiveKitBackend;
      // The legacy authorisation endpoint only needs the Matrix OpenID token.
      // Obtain it before publishing MatrixRTC membership. That way a rejected
      // JWT request cannot leave the group call state as `entered`.
      final token = await _requestToken(
        roomId: group.room.id,
        serviceUrl: backend.livekitServiceUrl,
      );
      await group.enter();
      room = lk.Room();
      await room.connect(
        token.url.isEmpty ? _sfuUrl : token.url,
        token.jwt,
        connectOptions: const lk.ConnectOptions(autoSubscribe: true),
      );
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (type == CallType.video) {
        await room.localParticipant?.setCameraEnabled(true);
      }
      final call = LiveKitCall(room: room, matrixGroup: group, type: type);
      _active = call;
      return call;
    } catch (_) {
      // Entering MatrixRTC succeeds before the token exchange and LiveKit
      // connection. Always unwind that membership if either later step fails;
      // otherwise the next attempt throws GroupCallState.entered.
      if (room != null) {
        try {
          await room.disconnect();
        } catch (_) {}
        try {
          await room.dispose();
        } catch (_) {}
      }
      if (group.state == mx.GroupCallState.entered) {
        try {
          await group.leave();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<_LiveKitToken> _requestToken({
    required String roomId,
    required String serviceUrl,
  }) async {
    final client = await MatrixAuthService.instance.restore();
    final userId = client.userID;
    if (userId == null || !client.isLogged()) {
      throw StateError('Matrix login is required before starting a call.');
    }
    final openId = await client.requestOpenIdToken(userId, const {});
    final endpoint = Uri.parse(
      '${serviceUrl.replaceAll(RegExp(r'/$'), '')}/sfu/get',
    );
    final response = await http.post(
      endpoint,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        // /sfu/get is the legacy MatrixRTC authorization endpoint. Older
        // lk-jwt-service versions reject unknown JSON fields, including the
        // MSC4195-only slot_id field. Use its established request shape.
        'room': roomId,
        'openid_token': openId.toJson(),
        'device_id': client.deviceID,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'MatrixRTC JWT service returned ${response.statusCode}: ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final jwt = json['jwt']?.toString();
    if (jwt == null || jwt.isEmpty) {
      throw StateError('JWT service returned no token.');
    }
    return _LiveKitToken(url: json['url']?.toString() ?? '', jwt: jwt);
  }

  Future<void> end() async {
    final call = _active;
    _active = null;
    if (call == null) return;
    try {
      await call.room.disconnect();
    } finally {
      try {
        await call.room.dispose();
      } finally {
        // Always remove MatrixRTC membership even if the network has already
        // dropped and LiveKit disconnect throws.
        if (call.matrixGroup.state == mx.GroupCallState.entered) {
          await call.matrixGroup.leave();
        }
      }
    }
  }

  Future<void> dispose() async {
    await _incomingSub?.cancel();
    await end();
    await _incoming.close();
  }
}

class LiveKitIncomingCall {
  const LiveKitIncomingCall({
    required this.group,
    required this.callerId,
    required this.serviceUrl,
  });
  final mx.GroupCallSession group;
  final String callerId;
  final String serviceUrl;
}

class LiveKitCall {
  const LiveKitCall({
    required this.room,
    required this.matrixGroup,
    required this.type,
  });
  final lk.Room room;
  final mx.GroupCallSession matrixGroup;
  final CallType type;
}

class _LiveKitToken {
  const _LiveKitToken({required this.url, required this.jwt});
  final String url;
  final String jwt;
}
