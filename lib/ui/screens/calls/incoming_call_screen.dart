import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/ui/screens/calls/call_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// IncomingCallScreen
//
// Full-screen takeover shown when a call arrives.
// Matches WhatsApp: blurred dark background, avatar, name, encrypted label,
// call type label, and two large action buttons (decline red, accept green).
// ─────────────────────────────────────────────────────────────────────────────

class IncomingCallScreen extends StatefulWidget {
  final CallData call;

  const IncomingCallScreen({super.key, required this.call});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  final CallService _callService = CallService.instance;

  // ── Pulse animation on the accept button ──────────────────────────────────
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  // ── Auto-dismiss timer (missed call after 60 s) ───────────────────────────
  Timer? _autoMissTimer;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(
      begin: 1.0,
      end: 1.12,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Auto-dismiss after 60 s (missed call)
    _autoMissTimer = Timer(const Duration(seconds: 60), () async {
      await _callService.rejectCall(widget.call.callId);
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _autoMissTimer?.cancel();
    super.dispose();
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _decline() async {
    await _callService.rejectCall(widget.call.callId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _accept() async {
    try {
      await _callService.acceptCall(widget.call);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not answer call: $error'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (!mounted) return;

    // Replace this screen with the active call screen
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder:
            (_) => CallScreen(
              remoteUserId: widget.call.callerId,
              remoteUserName: widget.call.callerName,
              remoteUserAvatar:
                  widget.call.callerAvatar.isEmpty
                      ? null
                      : widget.call.callerAvatar,
              type: widget.call.type,
              isCaller: false,
            ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.call.isVideo;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Background gradient ──────────────────────────────────────────
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.4),
                  radius: 1.4,
                  colors: [Color(0xFF1C2030), Color(0xFF08090B)],
                ),
              ),
            ),
          ),

          // ── Main content ─────────────────────────────────────────────────
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 32),

                // ── Name ──────────────────────────────────────────────────
                Text(
                  widget.call.callerName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 10),

                // ── Encrypted label ───────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'End-to-end encrypted',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),

                const Spacer(),

                // ── Avatar ────────────────────────────────────────────────
                UserAvatar(
                  size: 160,
                  imageUrl:
                      widget.call.callerAvatar.isEmpty
                          ? null
                          : widget.call.callerAvatar,
                  name: widget.call.callerName,
                ),

                const SizedBox(height: 28),

                // ── Call type label ───────────────────────────────────────
                Text(
                  isVideo ? 'Incoming video call…' : 'Incoming voice call…',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 16,
                  ),
                ),

                const Spacer(),

                // ── Action buttons ────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 60),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // ── Decline ──────────────────────────────────────
                      _ActionButton(
                        icon: Icons.call_end,
                        color: const Color(0xFFFF3B30),
                        label: 'Decline',
                        onTap: _decline,
                      ),

                      // ── Accept ────────────────────────────────────────
                      ScaleTransition(
                        scale: _pulseAnim,
                        child: _ActionButton(
                          icon: isVideo ? Icons.videocam : Icons.call,
                          color: const Color(0xFF34C759),
                          label: 'Accept',
                          onTap: _accept,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 48),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Action button (decline / accept) ──────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
