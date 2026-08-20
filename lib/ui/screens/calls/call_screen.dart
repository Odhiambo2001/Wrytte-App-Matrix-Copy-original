import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/services/call_service.dart';

class CallScreen extends StatefulWidget {
  final String remoteUserId;
  final String remoteUserName;
  final String? remoteUserAvatar;
  final CallType type;
  final bool isCaller;
  final bool startsConnected;

  const CallScreen({
    super.key,
    required this.remoteUserId,
    required this.remoteUserName,
    required this.type,
    required this.isCaller,
    this.startsConnected = false,
    this.remoteUserAvatar,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final CallService _callService = CallService.instance;

  // ── WebRTC renderers ───────────────────────────────────────────────────────
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  // ── Call state ─────────────────────────────────────────────────────────────
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isCameraOn = true;
  bool _isConnected = false;
  bool _isFrontCamera = true;
  bool _isLocalVideoPrimary = false;

  // ── Timer ──────────────────────────────────────────────────────────────────
  int _elapsedSeconds = 0;
  Timer? _timer;

  // ── Subscriptions ──────────────────────────────────────────────────────────
  StreamSubscription? _statusSub;
  StreamSubscription? _remoteStreamSub;
  StreamSubscription? _localStreamSub;

  @override
  void initState() {
    super.initState();
    _isConnected = widget.startsConnected;
    if (widget.startsConnected) _startTimer();
    _initRenderersAndStreams();
    _listenToCallStatus();
    _listenToRemoteStream();
    _listenToLocalStream();
    if (widget.type == CallType.video) {
      unawaited(_startVideoMedia());
    }

    // Caller plays ringing tone while waiting for answer
    if (widget.isCaller && !widget.startsConnected) {
      _startRinging();
    }
  }

  Future<void> _startVideoMedia() async {
    try {
      await _callService.ensureVideoEnabled();
      if (!mounted) return;
      setState(() {
        _isCameraOn = true;
        _isSpeakerOn = true;
      });
    } catch (error) {
      debugPrint('[CallScreen] Could not enable video: $error');
    }
  }

  // ── Renderer init ──────────────────────────────────────────────────────────

  Future<void> _initRenderersAndStreams() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    if (mounted) setState(() => _renderersReady = true);

    // Attach streams that may already be available (race-condition guard)
    final local = _callService.localStream;
    if (local != null && mounted) {
      setState(() => _localRenderer.srcObject = local);
    }

    final remote = _callService.remoteStream;
    if (remote != null && mounted) {
      setState(() => _remoteRenderer.srcObject = remote);
    }
  }

  // ── Listen for local stream (emitted by CallService._getLocalStream) ───────
  // This fires AFTER _initRenderersAndStreams completes so the renderer
  // is always initialized before we try to attach the stream.

  void _listenToLocalStream() {
    _localStreamSub = _callService.localStreamStream.listen((stream) async {
      // Wait for renderers to be ready before attaching
      if (!_renderersReady) {
        await _localRenderer.initialize();
        await _remoteRenderer.initialize();
        if (mounted) setState(() => _renderersReady = true);
      }
      if (mounted) {
        setState(() {
          _localRenderer.srcObject = stream;
          _isCameraOn = stream.getVideoTracks().isNotEmpty;
        });
      }
    });
  }

  // ── Listen for remote stream ───────────────────────────────────────────────

  void _listenToRemoteStream() {
    _remoteStreamSub = _callService.remoteStreamStream.listen((stream) {
      if (!mounted) return;
      setState(() {
        _remoteRenderer.srcObject = stream;
        _isConnected = true;
      });
      _stopRinging();
      _startTimer();
    });
  }

  // ── Listen for call status changes ────────────────────────────────────────

  void _listenToCallStatus() {
    _statusSub = _callService.callStatusStream.listen((status) {
      if (!mounted) return;
      switch (status) {
        case CallStatus.accepted:
          setState(() => _isConnected = true);
          _stopRinging();
          _startTimer();
          break;
        case CallStatus.ended:
        case CallStatus.rejected:
        case CallStatus.missed:
          _stopRinging();
          _timer?.cancel();
          if (mounted) Navigator.of(context).pop();
          break;
        default:
          break;
      }
    });
  }

  // ── Ringing ────────────────────────────────────────────────────────────────

  Future<void> _startRinging() async {
    try {
      await FlutterRingtonePlayer().playRingtone(looping: true);
    } catch (e) {
      debugPrint('[CallScreen] Ringtone error: $e');
    }
  }

  Future<void> _stopRinging() async {
    try {
      await FlutterRingtonePlayer().stop();
    } catch (_) {}
  }

  // ── Timer ──────────────────────────────────────────────────────────────────

  void _startTimer() {
    if (_timer != null && _timer!.isActive) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });
  }

  String get _timerLabel {
    final h = _elapsedSeconds ~/ 3600;
    final m = (_elapsedSeconds % 3600) ~/ 60;
    final s = _elapsedSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ── Dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _timer?.cancel();
    _statusSub?.cancel();
    _remoteStreamSub?.cancel();
    _localStreamSub?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  void _toggleMute() {
    setState(() => _isMuted = !_isMuted);
    _callService.setMicrophoneMuted(_isMuted);
  }

  void _toggleSpeaker() {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    _callService.setSpeakerOn(_isSpeakerOn);
  }

  void _flipCamera() {
    setState(() => _isFrontCamera = !_isFrontCamera);
    _callService.switchCamera();
  }

  void _swapPrimaryVideo() {
    setState(() => _isLocalVideoPrimary = !_isLocalVideoPrimary);
  }

  Future<void> _endCall() async {
    _stopRinging();
    await _callService.endCall();
    // CallStatus.ended closes this route. Popping here as well can accidentally
    // close the chat underneath the call screen.
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body:
          widget.type == CallType.video ? _buildVideoCall() : _buildVoiceCall(),
    );
  }

  // ── VOICE CALL ─────────────────────────────────────────────────────────────

  Widget _buildVoiceCall() {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.3),
                radius: 1.2,
                colors: [Color(0xFF1A1D24), Color(0xFF08090B)],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _glassPill(
                      size: 44,
                      child: const Icon(
                        Icons.fullscreen,
                        color: Colors.white,
                        size: 20,
                      ),
                      onTap: () {},
                    ),
                    const Spacer(),
                    _glassPill(
                      size: 44,
                      child: const Icon(
                        Icons.person_add_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                      onTap: () {},
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.remoteUserName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 13,
                    color: Colors.white.withOpacity(0.5),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'End-to-end encrypted',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              UserAvatar(
                size: 160,
                imageUrl: widget.remoteUserAvatar,
                name: widget.remoteUserName,
              ),
              const SizedBox(height: 24),
              Text(
                _isConnected
                    ? _timerLabel
                    : widget.isCaller
                    ? 'Calling…'
                    : 'Connecting…',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              _buildControlsRow(isVideo: false),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ],
    );
  }

  // ── VIDEO CALL ─────────────────────────────────────────────────────────────

  Widget _buildVideoCall() {
    final hasRemote = _remoteRenderer.srcObject != null;
    final hasLocal = _localRenderer.srcObject != null;
    final showLocalPrimary = _isLocalVideoPrimary && hasLocal && _isCameraOn;

    return Stack(
      children: [
        // ── Primary video ────────────────────────────────────────────────
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasLocal && hasRemote ? _swapPrimaryVideo : null,
            child:
                showLocalPrimary
                    ? RTCVideoView(
                      _localRenderer,
                      mirror: _isFrontCamera,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                    : hasRemote
                    ? RTCVideoView(
                      _remoteRenderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                    : Container(
                      color: const Color(0xFF1A1D24),
                      child: Center(
                        child: UserAvatar(
                          size: 120,
                          imageUrl: widget.remoteUserAvatar,
                          name: widget.remoteUserName,
                        ),
                      ),
                    ),
          ),
        ),

        // ── Gradients ────────────────────────────────────────────────────
        Positioned.fill(
          child: IgnorePointer(
            child: Column(
              children: [
                Expanded(
                  flex: 2,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.6),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
                const Expanded(flex: 3, child: SizedBox()),
                Expanded(
                  flex: 2,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.75),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Secondary video PiP ──────────────────────────────────────────
        Positioned(
          top: 60,
          right: 16,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasLocal && hasRemote ? _swapPrimaryVideo : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 100,
                height: 140,
                child:
                    showLocalPrimary
                        ? RTCVideoView(
                          _remoteRenderer,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        )
                        : hasLocal && _isCameraOn
                        ? RTCVideoView(
                          _localRenderer,
                          mirror: _isFrontCamera,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        )
                        : Container(
                          color: const Color(0xFF23262C),
                          child: const Icon(
                            Icons.videocam_off,
                            color: Colors.white54,
                            size: 32,
                          ),
                        ),
              ),
            ),
          ),
        ),

        // ── Top bar ───────────────────────────────────────────────────────
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _glassPill(
                    size: 44,
                    child: const Icon(
                      Icons.fullscreen_exit,
                      color: Colors.white,
                      size: 20,
                    ),
                    onTap: () {},
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.remoteUserName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 12,
                            color: Colors.white.withOpacity(0.6),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            'End-to-end encrypted',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.6),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (_isConnected)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _timerLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // ── Bottom controls ──────────────────────────────────────────────
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _buildControlsRow(isVideo: true),
            ),
          ),
        ),
      ],
    );
  }

  // ── Controls row ──────────────────────────────────────────────────────────

  Widget _buildControlsRow({required bool isVideo}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withOpacity(0.55),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _controlButton(icon: Icons.more_horiz, onTap: () {}),
                isVideo
                    ? _controlButton(
                      icon: Icons.flip_camera_ios_outlined,
                      onTap: _flipCamera,
                    )
                    : _controlButton(
                      icon: Icons.videocam_outlined,
                      onTap: () {},
                    ),
                _controlButton(
                  icon:
                      _isSpeakerOn
                          ? Icons.volume_up
                          : Icons.volume_down_outlined,
                  onTap: _toggleSpeaker,
                  active: _isSpeakerOn,
                ),
                _controlButton(
                  icon: _isMuted ? Icons.mic_off : Icons.mic_off_outlined,
                  onTap: _toggleMute,
                  active: _isMuted,
                ),
                _controlButton(
                  icon: Icons.call_end,
                  onTap: _endCall,
                  isEndCall: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
    bool isEndCall = false,
  }) {
    final Color bg =
        isEndCall
            ? const Color(0xFFFF3B30)
            : active
            ? Colors.white.withOpacity(0.25)
            : const Color(0xFF2C2F36);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(
          icon,
          color:
              isEndCall
                  ? Colors.white
                  : active
                  ? Colors.white
                  : Colors.white.withOpacity(0.85),
          size: 26,
        ),
      ),
    );
  }

  Widget _glassPill({
    required double size,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withOpacity(0.40),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.10)),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
