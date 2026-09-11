import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/device_metadata_service.dart';
import 'package:wrytte/services/auth/real_number_service.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

/// Completes a login using a one-time code displayed on an already-active
/// Wrytte app. No Twilio request is made on this route.
class ActiveDeviceLoginPage extends StatefulWidget {
  const ActiveDeviceLoginPage({super.key, required this.account});

  final String account;

  @override
  State<ActiveDeviceLoginPage> createState() => _ActiveDeviceLoginPageState();
}

class _ActiveDeviceLoginPageState extends State<ActiveDeviceLoginPage> {
  final _codeController = TextEditingController();
  final _focusNode = FocusNode();
  final _service = RealNumberService();
  String? _challengeId;
  DateTime? _expiresAt;
  String? _error;
  bool _loading = true;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  Future<void> _start() async {
    try {
      final metadata = await DeviceMetadataService.instance.collect();
      final challenge = await _service.startActiveDeviceLogin(
        account: widget.account,
        installationId: metadata.installationId,
      );
      if (!mounted) return;
      setState(() {
        _challengeId = challenge.challengeId;
        _expiresAt = challenge.expiresAt;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No active Wrytte device is available. Please use SMS.';
      });
    }
  }

  Future<void> _verify() async {
    if (_verifying ||
        _challengeId == null ||
        _codeController.text.length != 6) {
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final result = await _service.completeActiveDeviceLogin(
        challengeId: _challengeId!,
        code: _codeController.text,
        fallbackAccount: widget.account,
      );
      try {
        await DeviceMetadataService.instance.registerWithBackend();
      } catch (_) {
        // The session remains valid; registration can be retried on Home.
      }
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<void>(
          builder:
              (_) => HomeScreen(
                currentUserId: result.userId,
                initialProfileName: result.username,
                initialPhone:
                    result.username == widget.account ? null : widget.account,
              ),
        ),
        (_) => false,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _codeController.clear();
        _error =
            'Incorrect or expired code. Check your active device and try again.';
      });
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expires = _expiresAt;
    final expired = expires != null && expires.isBefore(DateTime.now());
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child:
            _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                  children: [
                    const SizedBox(height: 35),
                    const Icon(Icons.devices, color: Colors.white, size: 72),
                    const SizedBox(height: 24),
                    const Text(
                      'Approve on your active device',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Open Wrytte on an active device linked to this account. It will show a six-digit login code.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 16,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 30),
                    TextField(
                      controller: _codeController,
                      focusNode: _focusNode,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        letterSpacing: 8,
                      ),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      maxLength: 6,
                      decoration: const InputDecoration(
                        counterText: '',
                        hintText: '------',
                        hintStyle: TextStyle(
                          color: Colors.white24,
                          letterSpacing: 8,
                        ),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.blueAccent),
                        ),
                      ),
                      onChanged: (_) {
                        if (_codeController.text.length == 6) {
                          unawaited(_verify());
                        }
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                    if (expired) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'This request expired. Go back and try again.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                    const Spacer(),
                    if (_verifying) const CircularProgressIndicator(),
                  ],
                ),
      ),
    );
  }
}
