import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:webrtc_interface/webrtc_interface.dart' as webrtc_iface;
import 'package:matrix/matrix.dart' as mx;
import 'package:permission_handler/permission_handler.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/matrix/matrix_call_service.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
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
  mx.GroupCallSession? _activeGroupSession;
  webrtc.MediaStream? _localStream;
  webrtc.MediaStream? _remoteStream;
  StreamSubscription? _incomingCallSub;
  StreamSubscription? _groupStreamAddSub;
  StreamSubscription? _groupStreamRemovedSub;
  StreamSubscription? _groupEventSub;
  final Set<String> _attachedCallIds = {};
  final Set<String> _announcedIncomingCallIds = {};
  final Map<String, List<StreamSubscription<dynamic>>> _sessionSubscriptions =
      {};

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
    _incomingCallSub ??= MatrixCallService.instance.incomingCalls.listen((
      call,
    ) {
      _handleIncomingSession(call.session);
    });
    final voip = await MatrixCallService.instance.ensureStarted(_delegate);
    debugPrint('[CallService] Matrix VoIP ready: ${voip.localPartyId}');
    unawaited(_logTurnAvailability(voip));
  }

  Future<void> _logTurnAvailability(mx.VoIP voip) async {
    final servers = await voip.getIceServers();
    if (servers.isEmpty) {
      debugPrint(
        '[CallService] TURN unavailable; calls require a direct peer connection',
      );
      return;
    }

    final uris = servers
        .expand((server) {
          final value = server['urls'] ?? server['url'];
          return value is Iterable ? value : [value];
        })
        .whereType<String>()
        .toList(growable: false);
    final hasTurn = uris.any(
      (uri) => uri.startsWith('turn:') || uri.startsWith('turns:'),
    );
    debugPrint(
      '[CallService] TURN ${hasTurn ? 'available' : 'missing'}; '
      'credentialEntries=${servers.length} uris=${uris.join(',')}',
    );
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
    await _requestMediaPermissions(type);
    await ChatService().connect();
    final roomId = await ChatService().getMatrixConversationId(receiverId);
    if (roomId == null || roomId.isEmpty) {
      throw Exception('Could not create Matrix direct room for $receiverId');
    }
    final room = MatrixChatService.instance.getRoomById(roomId);
    if (room == null || room.membership != mx.Membership.join) {
      throw StateError('The Matrix direct room is not joined or available.');
    }
    final matrixPeerId = _resolveDirectPeerId(room, receiverId);
    await _validateDirectCallRoom(room, matrixPeerId);

    final session = await MatrixCallService.instance.invite(
      delegate: _delegate,
      roomId: roomId,
      video: type == CallType.video,
      userId: matrixPeerId,
    );
    _attachSession(session);
    if (type == CallType.video) await ensureVideoEnabled();
    debugPrint(
      '[CallService] Outgoing ${type.name} call=${session.callId} room=$roomId peer=$matrixPeerId',
    );
    _callStatusController.add(CallStatus.ringing);
    return session.callId;
  }

  Future<String> makeGroupVoiceCall({required String roomId}) async {
    await _requestMediaPermissions(CallType.voice);
    await ChatService().connect();
    final room = MatrixChatService.instance.getRoomById(roomId);
    if (room == null || room.membership != mx.Membership.join) {
      throw StateError('The Matrix group room is not joined or available.');
    }
    final voip = await MatrixCallService.instance.ensureStarted(_delegate);
    final existing = voip.getGroupCallById(roomId, roomId);
    final session =
        existing ??
        await voip.fetchOrCreateGroupCall(
          roomId,
          room,
          mx.MeshBackend(),
          'm.call',
          'm.room',
          preShareKey: false,
        );
    await _attachGroupSession(session);
    if (session.state != mx.GroupCallState.entered) {
      await _enterGroupVoiceSession(session);
    }
    _publishGroupStreams(session);
    _callStatusController.add(CallStatus.accepted);
    return session.groupCallId;
  }

  Future<void> _attachGroupSession(mx.GroupCallSession session) async {
    if (identical(_activeGroupSession, session)) return;
    await _groupStreamAddSub?.cancel();
    await _groupStreamRemovedSub?.cancel();
    await _groupEventSub?.cancel();
    _activeGroupSession = session;
    _groupLog('session selected', session);
    final backend = session.backend;
    if (backend is mx.MeshBackend) {
      _groupStreamAddSub = backend.onStreamAdd.stream.listen(_publishStream);
      _groupStreamRemovedSub = backend.onStreamRemoved.stream.listen((wrapped) {
        if (wrapped.stream == _remoteStream) {
          _remoteStream = null;
        }
      });
    }
    _groupEventSub = session.matrixRTCEventStream.stream.listen((event) {
      if (event is mx.ParticipantsJoinEvent) {
        for (final participant in event.participants) {
          _groupLog(
            'participant joined',
            session,
            details: 'participant="${participant.id}"',
          );
        }
      } else if (event is mx.ParticipantsLeftEvent) {
        for (final participant in event.participants) {
          _groupLog(
            'participant left',
            session,
            details: 'participant="${participant.id}"',
          );
        }
      } else if (event is mx.GroupCallStateChanged) {
        _groupLog(
          'state changed',
          session,
          details: 'state="${event.state.name}"',
        );
      } else if (event is mx.GroupCallStateError) {
        _groupLog(
          'state error',
          session,
          details: 'message="${event.msg}" error="${event.err}"',
        );
      }
    });
  }

  Future<mx.WrappedMediaStream> _createGroupVoiceStream(
    mx.GroupCallSession session,
  ) async {
    final userId = session.client.userID?.trim() ?? '';
    final deviceId = session.client.deviceID?.trim() ?? '';
    if (userId.isEmpty) {
      throw StateError('Matrix user is not logged in for group voice chat.');
    }
    if (deviceId.isEmpty) {
      throw StateError(
        'Matrix device is not initialized for group voice chat. Please sign in again.',
      );
    }
    final stream = await webrtc.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    try {
      final participant = mx.CallParticipant(
        session.voip,
        userId: userId,
        deviceId: deviceId,
      );
      return mx.WrappedMediaStream(
        stream: stream,
        participant: participant,
        room: session.room,
        client: session.client,
        purpose: mx.SDPStreamMetadataPurpose.Usermedia,
        audioMuted: stream.getAudioTracks().isEmpty,
        videoMuted: true,
        isGroupCall: true,
        voip: session.voip,
      );
    } catch (_) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      await stream.dispose();
      rethrow;
    }
  }

  Future<void> _enterGroupVoiceSession(mx.GroupCallSession session) async {
    mx.WrappedMediaStream? voiceStream;
    if (session.state == mx.GroupCallState.localCallFeedUninitialized) {
      voiceStream = await _createGroupVoiceStream(session);
      _groupLog(
        'local audio stream created',
        session,
        details: 'stream_id="${voiceStream.stream?.id}"',
      );
    }
    try {
      await session.enter(stream: voiceStream);
    } catch (error) {
      final stream = voiceStream?.stream;
      if (stream != null) {
        for (final track in stream.getTracks()) {
          track.stop();
        }
        await stream.dispose();
      }
      _groupLog('session enter failed', session, details: 'error="$error"');
      rethrow;
    }
    String? membershipEventId;
    final userId = session.client.userID;
    final deviceId = session.client.deviceID;
    if (userId != null && deviceId != null) {
      for (final membership in session.room.getCallMembershipsForUser(
        userId,
        deviceId,
        session.voip,
      )) {
        if (membership.callId == session.groupCallId &&
            membership.roomId == session.room.id) {
          membershipEventId = membership.eventId;
          break;
        }
      }
    }
    _groupLog(
      'membership event sent',
      session,
      details: 'event_id="${membershipEventId ?? 'pending sync'}"',
    );
    _groupLog('session entered', session);
  }

  void _groupLog(
    String action,
    mx.GroupCallSession session, {
    String details = '',
  }) {
    debugPrint(
      '[CallService.group] $action call_id="${session.groupCallId}" '
      'room_id="${session.room.id}"${details.isEmpty ? '' : ' $details'}',
    );
  }

  void _publishGroupStreams(mx.GroupCallSession session) {
    final backend = session.backend;
    if (backend is mx.MeshBackend) {
      final local = backend.localUserMediaStream;
      if (local != null) _publishStream(local);
      for (final remote in backend.userMediaStreams) {
        if (!remote.isLocal()) _publishStream(remote);
      }
    }
  }

  Future<void> joinGroupVoiceCall({
    required mx.GroupCallSession session,
  }) async {
    await _requestMediaPermissions(CallType.voice);
    await _attachGroupSession(session);
    if (session.state != mx.GroupCallState.entered) {
      await _enterGroupVoiceSession(session);
    }
    _publishGroupStreams(session);
    _callStatusController.add(CallStatus.accepted);
  }

  Future<void> leaveGroupVoiceCall() async {
    final session = _activeGroupSession;
    if (session != null && session.state == mx.GroupCallState.entered) {
      _groupLog('session leaving', session);
      await session.leave();
      _groupLog('session left', session);
    }
    await _groupStreamAddSub?.cancel();
    await _groupStreamRemovedSub?.cancel();
    await _groupEventSub?.cancel();
    _groupStreamAddSub = null;
    _groupStreamRemovedSub = null;
    _groupEventSub = null;
    _activeGroupSession = null;
    await _cleanup();
  }

  Future<void> acceptCall(CallData call) async {
    await _requestMediaPermissions(call.type);
    final session = call.matrixSession ?? _activeSession;
    if (session == null) throw Exception('No active Matrix call session');
    _attachSession(session);
    await MatrixCallService.instance.answer(session);
    if (call.type == CallType.video) await ensureVideoEnabled();
    debugPrint(
      '[CallService] Accepted ${call.type.name} call=${session.callId}',
    );
    _callStatusController.add(CallStatus.accepted);
  }

  Future<void> _requestMediaPermissions(CallType type) async {
    final permissions = <Permission>[Permission.microphone];
    if (type == CallType.video) permissions.add(Permission.camera);
    final statuses = await permissions.request();
    final denied = statuses.entries.where((entry) => !entry.value.isGranted);
    if (denied.isNotEmpty) {
      throw StateError(
        type == CallType.video
            ? 'Camera and microphone permissions are required for video calls'
            : 'Microphone permission is required for calls',
      );
    }
  }

  Future<void> ensureVideoEnabled() async {
    final session = _activeSession;
    if (session == null) throw StateError('No active video call session');
    await session.setLocalVideoMuted(false);
    for (final wrapped in session.getLocalStreams) {
      _publishStream(wrapped);
    }
    _localStream?.getVideoTracks().forEach((track) => track.enabled = true);
    await setSpeakerOn(true);
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
    if (_activeGroupSession != null) {
      await leaveGroupVoiceCall();
      return;
    }
    final session = _activeSession;
    if (session != null) {
      await MatrixCallService.instance.hangup(session);
    }
    _callStatusController.add(CallStatus.ended);
    await _cleanup();
  }

  void setMicrophoneMuted(bool muted) {
    final group = _activeGroupSession;
    if (group != null) {
      unawaited(
        group.backend.setDeviceMuted(
          group,
          muted,
          mx.MediaInputKind.audioinput,
        ),
      );
    }
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

  void _handleIncomingSession(mx.CallSession session) {
    if (session.direction != mx.CallDirection.kIncoming) return;
    if (!_announcedIncomingCallIds.add(session.callId)) return;
    if (_activeSession != null &&
        _activeSession!.callId != session.callId &&
        !_activeSession!.callHasEnded) {
      debugPrint(
        '[CallService] Rejecting incoming call ${session.callId}: busy with ${_activeSession!.callId}',
      );
      unawaited(session.reject(reason: mx.CallErrorCode.userBusy));
      return;
    }
    _attachSession(session);
    final type =
        session.type == mx.CallType.kVideo ? CallType.video : CallType.voice;
    debugPrint(
      '[CallService] Incoming ${type.name} call=${session.callId} room=${session.room.id} caller=${session.remoteUserId}',
    );
    _incomingCallController.add(
      CallData(
        callId: session.callId,
        callerId: session.remoteUserId ?? '',
        callerName:
            session.remoteUser?.displayName ??
            session.remoteUserId ??
            'Incoming call',
        callerAvatar: session.remoteUser?.avatarUrl?.toString() ?? '',
        receiverId: MatrixClientService.instance.userId ?? '',
        type: type,
        status: CallStatus.ringing,
        matrixSession: session,
      ),
    );
  }

  void _publishStream(mx.WrappedMediaStream wrapped) {
    final stream = wrapped.stream;
    if (stream == null) return;
    if (wrapped.isLocal()) {
      final group = _activeGroupSession;
      if (group != null) {
        _groupLog(
          'local audio stream published',
          group,
          details: 'stream_id="${stream.id}"',
        );
      }
      _localStream = stream;
      if (_activeSession?.type == mx.CallType.kVideo) {
        _localStream!.getVideoTracks().forEach((track) => track.enabled = true);
      }
      _localStreamController.add(_localStream!);
      debugPrint(
        '[CallService] Local media stream=${stream.id} audio=${stream.getAudioTracks().length} video=${stream.getVideoTracks().length}',
      );
    } else {
      final group = _activeGroupSession;
      if (group != null) {
        _groupLog(
          'remote audio stream received',
          group,
          details:
              'participant="${wrapped.participant.id}" stream_id="${stream.id}"',
        );
      }
      _remoteStream = stream;
      _remoteStreamController.add(_remoteStream!);
      debugPrint(
        '[CallService] Remote media stream=${stream.id} audio=${stream.getAudioTracks().length} video=${stream.getVideoTracks().length}',
      );
      _callStatusController.add(CallStatus.accepted);
    }
  }

  Future<void> _cleanup() async {
    final local = _localStream;
    if (local != null) {
      for (final track in local.getTracks()) {
        track.stop();
      }
      await local.dispose();
    }
    final activeCallId = _activeSession?.callId;
    if (activeCallId != null) {
      final subscriptions = _sessionSubscriptions.remove(activeCallId);
      if (subscriptions != null) {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      }
    }
    _activeSession = null;
    _attachedCallIds.clear();
    if (activeCallId != null) _announcedIncomingCallIds.remove(activeCallId);
    _localStream = null;
    _remoteStream = null;
  }

  String _toMatrixUserId(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    final own = MatrixClientService.instance.userId;
    final domain =
        own != null && own.contains(':')
            ? own.split(':').last
            : MatrixConfig.serverName;
    final localpart = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
    return '@$localpart:$domain';
  }

  String _resolveDirectPeerId(mx.Room room, String fallback) {
    final direct = room.directChatMatrixID?.trim();
    final own = MatrixClientService.instance.userId;
    if (direct != null &&
        direct.startsWith('@') &&
        direct.contains(':') &&
        direct != own) {
      return direct;
    }
    final joinedPeers =
        room
            .getParticipants(const [mx.Membership.join, mx.Membership.invite])
            .map((user) => user.id.trim())
            .where((userId) => userId != own)
            .where((userId) => userId.startsWith('@') && userId.contains(':'))
            .toSet();
    if (joinedPeers.length == 1) return joinedPeers.single;
    return _toMatrixUserId(fallback);
  }

  Future<void> _validateDirectCallRoom(
    mx.Room room,
    String matrixPeerId,
  ) async {
    var participants = room.getParticipants(const [
      mx.Membership.join,
      mx.Membership.invite,
    ]);
    mx.User? peer;
    for (final participant in participants) {
      if (participant.id == matrixPeerId) {
        peer = participant;
        break;
      }
    }
    if (peer == null) {
      participants = await room.requestParticipants(const [
        mx.Membership.join,
        mx.Membership.invite,
      ]);
      for (final participant in participants) {
        if (participant.id == matrixPeerId) {
          peer = participant;
          break;
        }
      }
    }
    if (peer == null) {
      throw StateError(
        'The selected Matrix room does not contain $matrixPeerId.',
      );
    }
    if (peer.membership != mx.Membership.join) {
      throw StateError(
        'The recipient has not joined the Matrix direct room yet.',
      );
    }
    debugPrint(
      '[CallService] Direct call room verified room=${room.id} caller=${MatrixClientService.instance.userId} receiver=$matrixPeerId membership=${peer.membership.name}',
    );
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
  _WrytteWebRtcDelegate(this._service)
    : _mediaDevices = _PermissionAwareMediaDevices(
        webrtc.navigator.mediaDevices,
      );

  final CallService _service;
  final webrtc_iface.MediaDevices _mediaDevices;

  void attach(mx.CallSession session) {
    unawaited(registerListeners(session));
  }

  @override
  webrtc_iface.MediaDevices get mediaDevices => _mediaDevices;

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
    if (_service._sessionSubscriptions.containsKey(session.callId)) return;
    final subscriptions = <StreamSubscription<dynamic>>[];
    _service._sessionSubscriptions[session.callId] = subscriptions;
    subscriptions.add(
      session.onStreamAdd.stream.listen(_service._publishStream),
    );
    subscriptions.add(session.onStreamRemoved.stream.listen((_) {}));
    subscriptions.add(
      session.onCallStateChanged.stream.listen((state) {
        debugPrint('[CallService] call=${session.callId} state=${state.name}');
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
      }),
    );
  }

  @override
  Future<void> handleNewCall(mx.CallSession session) async {
    _service._attachSession(session);
    _service._handleIncomingSession(session);
  }

  @override
  Future<void> handleCallEnded(mx.CallSession session) async {
    _service._callStatusController.add(CallStatus.ended);
    if (identical(_service._activeSession, session)) {
      await _service._cleanup();
    }
  }

  @override
  Future<void> handleMissedCall(mx.CallSession session) async {
    _service._callStatusController.add(CallStatus.missed);
  }

  @override
  Future<void> handleNewGroupCall(mx.GroupCallSession groupCall) async {}

  @override
  Future<void> handleGroupCallEnded(mx.GroupCallSession groupCall) async {
    if (identical(_service._activeGroupSession, groupCall)) {
      _service._activeGroupSession = null;
      _service._callStatusController.add(CallStatus.ended);
      await _service._cleanup();
    }
  }

  @override
  bool get isWeb => kIsWeb;

  @override
  bool get canHandleNewCall =>
      _service._activeSession == null || _service._activeSession!.callHasEnded;

  @override
  mx.EncryptionKeyProvider? get keyProvider => null;
}

class _PermissionAwareMediaDevices implements webrtc_iface.MediaDevices {
  _PermissionAwareMediaDevices(this._delegate);

  final webrtc_iface.MediaDevices _delegate;

  @override
  Function(dynamic event)? ondevicechange;

  @override
  Future<webrtc_iface.MediaStream> getUserMedia(
    Map<String, dynamic> mediaConstraints,
  ) async {
    final permissions = <Permission>[];
    final audio = mediaConstraints['audio'];
    final video = mediaConstraints['video'];
    if (audio != null && audio != false) permissions.add(Permission.microphone);
    if (video != null && video != false) permissions.add(Permission.camera);
    if (permissions.isNotEmpty) {
      final results = await permissions.request();
      if (results.values.any((status) => !status.isGranted)) {
        throw StateError('Camera or microphone permission was denied.');
      }
    }
    return _delegate.getUserMedia(mediaConstraints);
  }

  @override
  Future<webrtc_iface.MediaStream> getDisplayMedia(
    Map<String, dynamic> mediaConstraints,
  ) => _delegate.getDisplayMedia(mediaConstraints);

  @override
  Future<List<dynamic>> getSources() => _delegate.getSources();

  @override
  Future<List<webrtc_iface.MediaDeviceInfo>> enumerateDevices() =>
      _delegate.enumerateDevices();

  @override
  webrtc_iface.MediaTrackSupportedConstraints getSupportedConstraints() =>
      _delegate.getSupportedConstraints();

  @override
  Future<webrtc_iface.MediaDeviceInfo> selectAudioOutput([
    webrtc_iface.AudioOutputOptions? options,
  ]) => _delegate.selectAudioOutput(options);
}
