import 'dart:async';

import 'package:matrix/matrix.dart';

import 'matrix_auth_service.dart';
import 'matrix_chat_service.dart';

class MatrixIncomingCall {
  const MatrixIncomingCall(this.session);

  final CallSession session;

  String get callId => session.callId;
  String get callerId => session.remoteUserId ?? '';
  String get roomId => session.room.id;
  bool get isVideo => session.type == CallType.kVideo;
}

class MatrixCallService {
  MatrixCallService._();
  static final MatrixCallService instance = MatrixCallService._();

  VoIP? _voip;
  Future<VoIP>? _starting;
  final _incomingController = StreamController<MatrixIncomingCall>.broadcast();

  Stream<MatrixIncomingCall> get incomingCalls => _incomingController.stream;
  VoIP? get voip => _voip;

  Future<VoIP> ensureStarted(WebRTCDelegate delegate) async {
    final pending = _starting;
    if (pending != null) return pending;
    final future = _start(delegate);
    _starting = future;
    try {
      return await future;
    } finally {
      if (identical(_starting, future)) _starting = null;
    }
  }

  Future<VoIP> _start(WebRTCDelegate delegate) async {
    final client = await MatrixAuthService.instance.restore();
    final existing = _voip;
    if (existing != null && identical(existing.client, client)) return existing;
    final voip = VoIP(client, delegate);
    // This SDK stream is used for group-call setup. Direct calls arrive through
    // WebRTCDelegate.handleNewCall(), which CallService handles separately.
    voip.onIncomingCallStart.stream.listen(
      (session) => _incomingController.add(MatrixIncomingCall(session)),
    );
    _voip = voip;
    return voip;
  }

  Future<CallSession> invite({
    required WebRTCDelegate delegate,
    required String roomId,
    required bool video,
    String? userId,
  }) async {
    final voip = await ensureStarted(delegate);
    final room = MatrixChatService.instance.getRoomById(roomId);
    if (room == null) throw StateError('Unknown Matrix room: $roomId');
    return voip.inviteToCall(
      room,
      video ? CallType.kVideo : CallType.kVoice,
      userId: userId,
    );
  }

  Future<void> answer(CallSession session) => session.answer();

  Future<void> reject(CallSession session) => session.reject();

  Future<void> hangup(CallSession session) =>
      session.hangup(reason: CallErrorCode.userHangup);
}
