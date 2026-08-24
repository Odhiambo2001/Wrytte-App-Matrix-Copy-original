import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/matrix/matrixrtc_livekit_service.dart';

/// Media screen for a MatrixRTC call. Matrix carries membership/signalling;
/// this widget renders and controls the LiveKit media room.
class LiveKitCallScreen extends StatefulWidget {
  const LiveKitCallScreen({super.key, required this.call, this.title = 'Call'});

  final LiveKitCall call;
  final String title;

  @override
  State<LiveKitCallScreen> createState() => _LiveKitCallScreenState();
}

class _LiveKitCallScreenState extends State<LiveKitCallScreen> {
  bool _muted = false;
  bool _camera = true;
  bool _ended = false;

  lk.Room get _room => widget.call.room;

  @override
  void initState() {
    super.initState();
    // Room notifications cover remote publication, unpublication and
    // disconnects. The SDK also exposes createListener() for specific events;
    // the room notifier is sufficient for rebuilding the participant tracks.
    _room.addListener(_onRoomChanged);
  }

  void _onRoomChanged() {
    if (mounted) setState(() {});
  }

  lk.VideoTrack? _localVideo() {
    final participant = _room.localParticipant;
    if (participant == null) return null;
    for (final publication in participant.trackPublications.values) {
      final track = publication.track;
      if (track is lk.VideoTrack) return track as lk.VideoTrack;
    }
    return null;
  }

  lk.VideoTrack? _remoteVideo() {
    for (final participant in _room.remoteParticipants.values) {
      for (final publication in participant.trackPublications.values) {
        final track = publication.track;
        if (track is lk.VideoTrack) return track as lk.VideoTrack;
      }
    }
    return null;
  }

  Future<void> _toggleMute() async {
    await _room.localParticipant?.setMicrophoneEnabled(_muted);
    if (mounted) setState(() => _muted = !_muted);
  }

  Future<void> _toggleCamera() async {
    await _room.localParticipant?.setCameraEnabled(!_camera);
    if (mounted) setState(() => _camera = !_camera);
  }

  Future<void> _hangUp() async {
    if (_ended) return;
    _ended = true;
    await MatrixRtcLiveKitService.instance.end();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _room.removeListener(_onRoomChanged);
    if (!_ended) unawaited(MatrixRtcLiveKitService.instance.end());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = _remoteVideo();
    final local = _localVideo();
    final video = widget.call.type == CallType.video;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.title), backgroundColor: Colors.black),
      body: Stack(
        children: [
          if (video && remote != null)
            Positioned.fill(child: lk.VideoTrackRenderer(remote))
          else
            const Center(
              child: Icon(Icons.person, color: Colors.white54, size: 96),
            ),
          if (video && local != null)
            Positioned(
              right: 16,
              top: 16,
              width: 120,
              height: 180,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: lk.VideoTrackRenderer(local),
              ),
            ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FloatingActionButton(
                  heroTag: 'mute',
                  onPressed: _toggleMute,
                  child: Icon(_muted ? Icons.mic_off : Icons.mic),
                ),
                if (video)
                  FloatingActionButton(
                    heroTag: 'camera',
                    onPressed: _toggleCamera,
                    child: Icon(_camera ? Icons.videocam : Icons.videocam_off),
                  ),
                FloatingActionButton(
                  heroTag: 'hangup',
                  backgroundColor: Colors.red,
                  onPressed: _hangUp,
                  child: const Icon(Icons.call_end),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
