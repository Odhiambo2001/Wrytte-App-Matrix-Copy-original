import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MessageInputField
//
// Changes vs original:
//   • Converted from StatelessWidget → StatefulWidget (needed for recorder state)
//   • Added onVoiceMessage callback — called with (filePath, durationSeconds)
//     when the user lifts their finger off the mic button
//   • Mic button: tap-and-hold to record, release to send (exactly WhatsApp)
//   • Mic button shows a red pulsing dot + elapsed timer while recording
//   • All layout, colours, glass pill shapes, send button — UNTOUCHED
// ─────────────────────────────────────────────────────────────────────────────

class MessageInputField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isSending;
  final VoidCallback onSend;
  final double inputPillHeight;

  // ── NEW: called after a voice note is recorded ────────────────────────────
  // filePath        — absolute path to the .aac file
  // durationSeconds — length of the recording in whole seconds
  final Future<void> Function(String filePath, int durationSeconds)?
  onVoiceMessage;
  final Future<void> Function()? onVideoMessage;

  const MessageInputField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isSending,
    required this.onSend,
    this.inputPillHeight = 40.0,
    this.onVoiceMessage, // ← NEW (optional so existing callers don't break)
    this.onVideoMessage,
  });

  @override
  State<MessageInputField> createState() => _MessageInputFieldState();
}

class _MessageInputFieldState extends State<MessageInputField> {
  // ── flutter_sound recorder ─────────────────────────────────────────────────
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _recorderReady = false;

  // ── Recording state ────────────────────────────────────────────────────────
  bool _isRecording = false;
  bool _cameraMode = false;
  bool _cancelRecordingOnRelease = false;
  bool _videoRequestInFlight = false;
  int _elapsedSeconds = 0;
  Timer? _timer;
  String? _recordingPath;

  @override
  void initState() {
    super.initState();
    _openRecorder();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.closeRecorder();
    super.dispose();
  }

  // ── Init recorder (requests mic permission) ────────────────────────────────
  Future<void> _openRecorder() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) return;
    await _recorder.openRecorder();
    setState(() => _recorderReady = true);
  }

  // ── Start recording ────────────────────────────────────────────────────────
  Future<void> _startRecording() async {
    if (!_recorderReady || _isRecording) return;

    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';

    await _recorder.startRecorder(toFile: _recordingPath, codec: Codec.aacADTS);

    _elapsedSeconds = 0;
    _cancelRecordingOnRelease = false;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });

    setState(() => _isRecording = true);
  }

  // ── Stop recording and send ────────────────────────────────────────────────
  Future<void> _stopRecordingAndSend() async {
    if (!_isRecording) return;
    if (_cancelRecordingOnRelease) {
      await _cancelRecording();
      return;
    }

    _timer?.cancel();
    await _recorder.stopRecorder();

    final path = _recordingPath;
    final duration = _elapsedSeconds;

    setState(() {
      _isRecording = false;
      _cancelRecordingOnRelease = false;
      _elapsedSeconds = 0;
      _recordingPath = null;
    });

    // Discard recordings under 1 second (accidental taps)
    if (path == null || duration < 1) return;

    // Verify the file actually exists before handing it off
    if (!await File(path).exists()) return;

    await widget.onVoiceMessage?.call(path, duration);
  }

  // ── Cancel recording (swipe-to-cancel hook — extend here if needed) ────────
  Future<void> _cancelRecording() async {
    if (!_isRecording) return;
    _timer?.cancel();
    await _recorder.stopRecorder();
    if (_recordingPath != null) {
      final f = File(_recordingPath!);
      if (await f.exists()) await f.delete();
    }
    setState(() {
      _isRecording = false;
      _cancelRecordingOnRelease = false;
      _elapsedSeconds = 0;
      _recordingPath = null;
    });
  }

  void _handleRecordMove(LongPressMoveUpdateDetails details) {
    if (!_isRecording) return;
    final shouldCancel = details.offsetFromOrigin.dx < -80;
    if (shouldCancel != _cancelRecordingOnRelease && mounted) {
      setState(() => _cancelRecordingOnRelease = shouldCancel);
    }
  }

  Future<void> _recordVideoMessage() async {
    if (_isRecording || _videoRequestInFlight) return;
    setState(() => _videoRequestInFlight = true);
    try {
      await widget.onVideoMessage?.call();
    } finally {
      if (mounted) setState(() => _videoRequestInFlight = false);
    }
  }

  // ── Format mm:ss for the recording timer ───────────────────────────────────
  String get _timerLabel {
    final m = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final hasText = value.text.trim().isNotEmpty;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              stops: const [0.0, 0.7, 1.0],
              colors: [
                const Color(0xFF08090B).withOpacity(0.98),
                const Color(0xFF08090B).withOpacity(0.80),
                const Color(0xFF08090B).withOpacity(0.0),
              ],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // ── Attachment ──────────────────────────────────────────
                  _glassPill(
                    width: widget.inputPillHeight,
                    height: widget.inputPillHeight,
                    child: Icon(
                      Icons.add,
                      color: Colors.white.withOpacity(0.7),
                      size: 25,
                    ),
                    onTap: () {},
                  ),
                  const SizedBox(width: 8),

                  // ── Text field (hidden while recording) ─────────────────
                  Expanded(
                    child:
                        _isRecording
                            ? _buildRecordingIndicator()
                            : ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 24,
                                  sigmaY: 24,
                                ),
                                child: Container(
                                  constraints: BoxConstraints(
                                    minHeight: widget.inputPillHeight,
                                    maxHeight: 120,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF23262C,
                                    ).withOpacity(0.30),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(0xFF23262C),
                                      width: 1.0,
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: TextField(
                                          controller: widget.controller,
                                          focusNode: widget.focusNode,
                                          maxLines: null,
                                          minLines: 1,
                                          keyboardType: TextInputType.multiline,
                                          textInputAction:
                                              TextInputAction.newline,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            height: 1.4,
                                          ),
                                          decoration: InputDecoration(
                                            hintText: 'Message',
                                            hintStyle: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.3,
                                              ),
                                              fontSize: 15,
                                            ),
                                            border: InputBorder.none,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  vertical: 10,
                                                ),
                                            isDense: true,
                                          ),
                                        ),
                                      ),

                                      // ── Express / emoji SVG ─────────────
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 4,
                                          bottom: 4,
                                        ),
                                        child: GestureDetector(
                                          onTap: () {},
                                          child: SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: Center(
                                              child: SvgPicture.asset(
                                                'assets/svg/gif_icon.svg',
                                                width: 23,
                                                height: 23,
                                                colorFilter: ColorFilter.mode(
                                                  Colors.white.withOpacity(0.4),
                                                  BlendMode.srcIn,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                  ),
                  const SizedBox(width: 8),

                  // ── GIF SVG pill (hidden while recording) ───────────────
                  if (!_isRecording) ...[
                    _glassPill(
                      width: widget.inputPillHeight,
                      height: widget.inputPillHeight,
                      child: SvgPicture.asset(
                        'assets/svg/express_message.svg',
                        width: 40,
                        height: 40,
                        colorFilter: ColorFilter.mode(
                          Colors.white.withOpacity(0.7),
                          BlendMode.srcIn,
                        ),
                      ),
                      onTap: () {},
                    ),
                    const SizedBox(width: 8),
                  ],

                  // ── Send / mic button ───────────────────────────────────
                  hasText
                      ? GestureDetector(
                        onTap: widget.onSend,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: widget.inputPillHeight,
                          height: widget.inputPillHeight,
                          decoration: BoxDecoration(
                            color: const Color(0xFF4DA3FF),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child:
                              widget.isSending
                                  ? const Padding(
                                    padding: EdgeInsets.all(10),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                  : const Icon(
                                    Icons.send_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                        ),
                      )
                      // ── Mic pill — hold to record, release to send ──────
                      : GestureDetector(
                        onTap: () {
                          if (_isRecording) return;
                          setState(() => _cameraMode = !_cameraMode);
                        },
                        onLongPressStart:
                            (_) =>
                                _cameraMode
                                    ? _recordVideoMessage()
                                    : _startRecording(),
                        onLongPressMoveUpdate:
                            _cameraMode ? null : _handleRecordMove,
                        onLongPressEnd:
                            (_) => _cameraMode ? null : _stopRecordingAndSend(),
                        onLongPressCancel:
                            _cameraMode ? null : _cancelRecording,
                        child: _glassPill(
                          width: widget.inputPillHeight,
                          height: widget.inputPillHeight,
                          child: Icon(
                            _isRecording
                                ? Icons.mic
                                : _cameraMode
                                ? Icons.videocam_outlined
                                : Icons.mic_outlined,
                            color:
                                _isRecording
                                    ? Colors.redAccent
                                    : Colors.white.withOpacity(0.7),
                            size: 25,
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Recording indicator — replaces the text field while recording ──────────
  // Same glass pill style as the rest of the bar. Shows a red dot + timer.
  Widget _buildRecordingIndicator() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: widget.inputPillHeight,
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withOpacity(0.30),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF23262C), width: 1.0),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              // Pulsing red dot
              _PulsingDot(),
              const SizedBox(width: 10),
              Text(
                _timerLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              Text(
                _cancelRecordingOnRelease
                    ? 'Release to cancel'
                    : '<  Slide to cancel',
                style: TextStyle(
                  color:
                      _cancelRecordingOnRelease
                          ? Colors.redAccent
                          : Colors.white.withOpacity(0.4),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _glassPill({
    required double width,
    required double height,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withOpacity(0.30),
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(color: const Color(0xFF23262C), width: 1.0),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

// ── Pulsing red dot (recording indicator) ─────────────────────────────────────

class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: const Icon(Icons.circle, color: Colors.redAccent, size: 10),
    );
  }
}
