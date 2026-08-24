import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wrytte/services/matrix/matrixrtc_livekit_service.dart';
import 'package:wrytte/ui/screens/calls/livekit_incoming_call_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CallListenerService
//
// Wires CallService.incomingCallStream → IncomingCallScreen.
// Started in AuthWrapper._onAuthSuccess() immediately after login.
// Stopped in AuthWrapper.dispose().
// ─────────────────────────────────────────────────────────────────────────────

class CallListenerService {
  StreamSubscription? _incomingCallSubscription;

  // ── Start ──────────────────────────────────────────────────────────────────

  void startListening(BuildContext context) {
    final service = MatrixRtcLiveKitService.instance;
    unawaited(
      service.startListening().catchError((error) {
        debugPrint('[CallListener] MatrixRTC LiveKit startup failed: $error');
      }),
    );
    _incomingCallSubscription ??= service.incomingCalls.listen((call) {
      if (!context.mounted) return;
      if (ModalRoute.of(context)?.settings.name == '/incoming_call') return;
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/incoming_call'),
          fullscreenDialog: true,
          builder: (_) => LiveKitIncomingCallScreen(call: call),
        ),
      );
    });
  }

  // ── Stop ───────────────────────────────────────────────────────────────────

  void stopListening() {
    _incomingCallSubscription?.cancel();
    _incomingCallSubscription = null;
  }
}
