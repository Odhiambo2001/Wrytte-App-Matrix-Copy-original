import 'package:flutter/material.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/matrix/matrixrtc_livekit_service.dart';
import 'package:wrytte/ui/screens/calls/livekit_call_screen.dart';

class LiveKitIncomingCallScreen extends StatefulWidget {
  const LiveKitIncomingCallScreen({super.key, required this.call});

  final LiveKitIncomingCall call;

  @override
  State<LiveKitIncomingCallScreen> createState() =>
      _LiveKitIncomingCallScreenState();
}

class _LiveKitIncomingCallScreenState extends State<LiveKitIncomingCallScreen> {
  bool _busy = false;

  Future<void> _accept(CallType type) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final call = await MatrixRtcLiveKitService.instance.accept(
        widget.call,
        type: type,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => LiveKitCallScreen(call: call, title: 'Incoming call'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not answer call: $error')));
    }
  }

  Future<void> _reject() async {
    await widget.call.group.leave();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.call, color: Colors.white, size: 72),
          const SizedBox(height: 24),
          Text(
            widget.call.callerId.isEmpty
                ? 'Incoming call'
                : widget.call.callerId,
            style: const TextStyle(color: Colors.white, fontSize: 24),
          ),
          const SizedBox(height: 48),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FloatingActionButton(
                heroTag: 'reject',
                backgroundColor: Colors.red,
                onPressed: _busy ? null : _reject,
                child: const Icon(Icons.call_end),
              ),
                  FloatingActionButton(
                    heroTag: 'accept_voice',
                    backgroundColor: Colors.green,
                    onPressed: _busy ? null : () => _accept(CallType.voice),
                    child: const Icon(Icons.call),
                  ),
                  FloatingActionButton(
                    heroTag: 'accept_video',
                    backgroundColor: Colors.blue,
                    onPressed: _busy ? null : () => _accept(CallType.video),
                    child: const Icon(Icons.videocam),
                  ),
            ],
          ),
        ],
      ),
    ),
  );
}
