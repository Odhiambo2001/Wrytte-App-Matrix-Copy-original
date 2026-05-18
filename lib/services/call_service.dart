import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
// At the top of call_service.dart, add this import:
import 'package:webrtc_interface/webrtc_interface.dart' as webrtc_iface;
import 'package:matrix/matrix.dart' as mx;
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_call_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

enum CallType { voice, video }

enum CallStatus { ringing, accepted, rejected, ended, missed }

class CallData {
  final String callId;
  final String callerId;
  final String callerName;
  final String callerAvatar;
  final String receiverId;
  final CallType type;
  final mx.CallSession? matrixSession;
  CallStatus status;

  CallData({
    required this.callId,
    required this.callerId,
    required this.callerName,
    required this.callerAvatar,
    required this.receiverId,
    required this.type,
    required this.status,
    this.matrixSession,
  });

  bool get isVoice => type == CallType.voice;
  bool get isVideo => type == CallType.video;
}

class CallService {
  CallService._() {
    _delegate = _WrytteWebRtcDelegate(this);
  }
  static final CallService instance = CallService._();

  late final _WrytteWebRtcDelegate _delegate;

  mx.CallSession? _activeSession;
  webrtc.MediaStream? _localStream;
  webrtc.MediaStream? _remoteStream;
  StreamSubscription? _incomingCallSub;
  final Set<String> _attachedCallIds = {};

  final _incomingCallController = StreamController<CallData>.broadcast();
  final _callStatusController = StreamController<CallStatus>.broadcast();
  final _remoteStreamController =
      StreamController<webrtc.MediaStream>.broadcast();
  final _localStreamController =
      StreamController<webrtc.MediaStream>.broadcast();

  Stream<CallData> get incomingCallStream => _incomingCallController.stream;
  Stream<CallStatus> get callStatusStream => _callStatusController.stream;
  Stream<webrtc.MediaStream> get remoteStreamStream =>
      _remoteStreamController.stream;
  Stream<webrtc.MediaStream> get localStreamStream =>
      _localStreamController.stream;

  webrtc.MediaStream? get localStream => _localStream;
  webrtc.MediaStream? get remoteStream => _remoteStream;
  String? get currentCallId => _activeSession?.callId;

  Future<void> startListeningForIncomingCalls() async {
    final voip = await MatrixCallService.instance.ensureStarted(_delegate);
    _incomingCallSub ??= MatrixCallService.instance.incomingCalls.listen((call) {
      final session = call.session;
      _attachSession(session);
      _incomingCallController.add(
        CallData(
          callId: session.callId,
          callerId: session.remoteUserId ?? '',
          callerName: session.remoteUser?.displayName ??
              session.remoteUserId ??
              'Incoming call',
          callerAvatar: session.remoteUser?.avatarUrl?.toString() ?? '',
          receiverId: MatrixClientService.instance.userId ?? '',
          type: call.isVideo ? CallType.video : CallType.voice,
          status: CallStatus.ringing,
          matrixSession: session,
        ),
      );
    });
    debugPrint('[CallService] Matrix VoIP ready: ${voip.localPartyId}');
  }

  Future<void> stopListeningForIncomingCalls() async {
    await _incomingCallSub?.cancel();
    _incomingCallSub = null;
  }

  Future<String> makeCall({
    required String receiverId,
    required CallType type,
    required String callerName,
    String callerAvatar = '',
  }) async {
    await ChatService().connect();
    final roomId = await ChatService().getMatrixConversationId(receiverId);
    if (roomId == null || roomId.isEmpty) {
      throw Exception('Could not create Matrix direct room for $receiverId');
    }

    final session = await MatrixCallService.instance.invite(
      delegate: _delegate,
      roomId: roomId,
      video: type == CallType.video,
      userId: _toMatrixUserId(receiverId),
    );
    _attachSession(session);
    _callStatusController.add(CallStatus.ringing);
    return session.callId;
  }

  Future<void> acceptCall(CallData call) async {
    final session = call.matrixSession ?? _activeSession;
    if (session == null) throw Exception('No active Matrix call session');
    _attachSession(session);
    await MatrixCallService.instance.answer(session);
    _callStatusController.add(CallStatus.accepted);
  }

  Future<void> rejectCall(String callId) async {
    final session = _activeSession;
    if (session != null && session.callId == callId) {
      await MatrixCallService.instance.reject(session);
    }
    _callStatusController.add(CallStatus.rejected);
    await _cleanup();
  }

  Future<void> endCall() async {
    final session = _activeSession;
    if (session != null) {
      await MatrixCallService.instance.hangup(session);
    }
    _callStatusController.add(CallStatus.ended);
    await _cleanup();
  }

  void setMicrophoneMuted(bool muted) {
    final session = _activeSession;
    if (session != null) unawaited(session.setMicrophoneMuted(muted));
    _localStream?.getAudioTracks().forEach((track) => track.enabled = !muted);
  }

  void setCameraEnabled(bool enabled) {
    final session = _activeSession;
    if (session != null) unawaited(session.setLocalVideoMuted(!enabled));
    _localStream?.getVideoTracks().forEach((track) => track.enabled = enabled);
  }

  Future<void> setSpeakerOn(bool on) async {
    await webrtc.Helper.setSpeakerphoneOn(on);
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const [];
    final track = tracks.isEmpty ? null : tracks.first;
    if (track != null) await webrtc.Helper.switchCamera(track);
  }

  void _attachSession(mx.CallSession session) {
    _activeSession = session;
    if (_attachedCallIds.add(session.callId)) {
      _delegate.attach(session);
    }

    for (final stream in session.getLocalStreams) {
      _publishStream(stream);
    }
    for (final stream in session.getRemoteStreams) {
      _publishStream(stream);
    }
  }

  void _publishStream(mx.WrappedMediaStream wrapped) {
    final stream = wrapped.stream;
    if (stream == null) return;
    if (wrapped.isLocal()) {
      _localStream = stream as webrtc.MediaStream;
      _localStreamController.add(_localStream!);
    } else {
      _remoteStream = stream as webrtc.MediaStream;
      _remoteStreamController.add(_remoteStream!);
      _callStatusController.add(CallStatus.accepted);
    }
  }

  Future<void> _cleanup() async {
    _activeSession = null;
    _attachedCallIds.clear();
    _localStream = null;
    _remoteStream = null;
  }

  String _toMatrixUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    final own = MatrixClientService.instance.userId;
    final domain = own != null && own.contains(':')
        ? own.split(':').last
        : MatrixConfig.serverName;
    final localpart = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
    return '@$localpart:$domain';
  }

  void dispose() {
    stopListeningForIncomingCalls();
    _cleanup();
    _incomingCallController.close();
    _callStatusController.close();
    _remoteStreamController.close();
    _localStreamController.close();
  }
}

class _WrytteWebRtcDelegate implements mx.WebRTCDelegate {
  _WrytteWebRtcDelegate(this._service);

  final CallService _service;

  void attach(mx.CallSession session) {
    registerListeners(session);
  }

  @override
  webrtc_iface.MediaDevices get mediaDevices => webrtc.navigator.mediaDevices as webrtc_iface.MediaDevices;

  //@override
  //webrtc.MediaDevices get mediaDevices => webrtc.navigator.mediaDevices;

  @override
  Future<webrtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) {
    return webrtc.createPeerConnection(configuration, constraints);
  }

  @override
  Future<void> playRingtone() async {
    try {
      await FlutterRingtonePlayer().playRingtone(looping: true);
    } catch (_) {}
  }

  @override
  Future<void> stopRingtone() async {
    try {
      await FlutterRingtonePlayer().stop();
    } catch (_) {}
  }

  @override
  Future<void> registerListeners(mx.CallSession session) async {
    session.onStreamAdd.stream.listen(_service._publishStream);
    session.onStreamRemoved.stream.listen((_) {});
    session.onCallStateChanged.stream.listen((state) {
      switch (state) {
        case mx.CallState.kConnected:
          _service._callStatusController.add(CallStatus.accepted);
          break;
        case mx.CallState.kEnded:
        case mx.CallState.kEnding:
          _service._callStatusController.add(CallStatus.ended);
          break;
        default:
          break;
      }
    });
  }

  @override
  Future<void> handleNewCall(mx.CallSession session) async {
    _service._attachSession(session);
  }

  @override
  Future<void> handleCallEnded(mx.CallSession session) async {
    _service._callStatusController.add(CallStatus.ended);
  }

  @override
  Future<void> handleMissedCall(mx.CallSession session) async {
    _service._callStatusController.add(CallStatus.missed);
  }

  @override
  Future<void> handleNewGroupCall(mx.GroupCallSession groupCall) async {}

  @override
  Future<void> handleGroupCallEnded(mx.GroupCallSession groupCall) async {}

  @override
  bool get isWeb => kIsWeb;

  @override
  bool get canHandleNewCall => true;

  @override
  mx.EncryptionKeyProvider? get keyProvider => null;
}
