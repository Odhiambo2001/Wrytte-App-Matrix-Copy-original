import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/device_metadata_service.dart';
import 'package:wrytte/services/auth/real_number_service.dart';
import 'package:wrytte/ui/auth/widgets/auth_page_header.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

/// Completes a login using a one-time code displayed on an already-active
/// Wrytte app. No Twilio request is made on this route.
class ActiveDeviceLoginPage extends StatefulWidget {
  const ActiveDeviceLoginPage({super.key, required this.account, this.userId});

  final String account;
  final String? userId;

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
  Timer? _expiryTimer;

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
      final userId = widget.userId?.trim() ?? '';
      final deviceId =
          userId.isEmpty
              ? null
              : await DeviceMetadataService.instance.rememberedDeviceId(
                userId: userId,
              );
      final challenge = await _service.startActiveDeviceLogin(
        account: widget.account,
        requestingDeviceId: deviceId,
      );
      if (!mounted) return;
      setState(() {
        _challengeId = challenge.challengeId;
        _expiresAt = challenge.expiresAt;
        _loading = false;
      });
      _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
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
        await DeviceMetadataService.instance.registerWithBackend(
          userId: result.userId,
        );
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
    _expiryTimer?.cancel();
    super.dispose();
  }

  Widget _otpBoxes() => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 10.0;
      final boxWidth = ((constraints.maxWidth - gap * 5) / 6).clamp(38.0, 46.0);
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(6, (index) {
          final character =
              index < _codeController.text.length
                  ? _codeController.text[index]
                  : '';
          return Padding(
            padding: EdgeInsetsDirectional.only(end: index == 5 ? 0 : gap),
            child: Container(
              width: boxWidth,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: WrytteColors.background,
                border: Border.all(color: const Color(0xFF2D3138)),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                character.isEmpty ? '–' : character,
                style: TextStyle(
                  fontFamily: WrytteTypography.primaryFontFamily,
                  color:
                      character.isEmpty
                          ? WrytteColors.textSecondary
                          : WrytteColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  height: 1,
                ),
              ),
            ),
          );
        }),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final expires = _expiresAt;
    final expired = expires != null && expires.isBefore(DateTime.now());
    final remainingSeconds =
        expires == null
            ? 0
            : expires.difference(DateTime.now()).inSeconds.clamp(0, 5999);
    final timerText =
        '${(remainingSeconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(remainingSeconds % 60).toString().padLeft(2, '0')}';
    return Scaffold(
      backgroundColor: WrytteColors.background,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child:
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AuthPageHeader(
                          title: 'Activate account',
                          onBack: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                AuthPageSubtitle(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 310,
                                    ),
                                    child: Text(
                                      "We've sent a code to your an active device.",
                                      textAlign: TextAlign.center,
                                      textDirection: TextDirection.ltr,
                                      style: WrytteTypography.authSubtitle,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  _verifying
                                      ? 'Verifying…'
                                      : 'Enter 6-digit code',
                                  textAlign: TextAlign.center,
                                  style: WrytteTypography.authSubtitle,
                                ),
                                const SizedBox(height: 28),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _focusNode.requestFocus,
                                  child: _otpBoxes(),
                                ),
                                SizedBox(
                                  height: 1,
                                  child: Opacity(
                                    opacity: 0,
                                    child: TextField(
                                      controller: _codeController,
                                      focusNode: _focusNode,
                                      enabled: !_verifying,
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                      maxLength: 6,
                                      decoration: const InputDecoration(
                                        border: InputBorder.none,
                                        counterText: '',
                                        isCollapsed: true,
                                      ),
                                      onChanged: (_) {
                                        setState(() {});
                                        if (_codeController.text.length == 6) {
                                          unawaited(_verify());
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                if (_error != null) ...[
                                  const SizedBox(height: 10),
                                  Text(
                                    _error!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                ],
                                if (expired) ...[
                                  const SizedBox(height: 10),
                                  const Text(
                                    'This request expired. Go back and try again.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: WrytteColors.textMuted,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 40),
                                Text(
                                  timerText,
                                  textAlign: TextAlign.center,
                                  style: WrytteTypography.authSubtitle,
                                ),
                                const SizedBox(height: 34),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextButton(
                                        onPressed: null,
                                        child: Text(
                                          'Resend SMS',
                                          style: TextStyle(
                                            fontFamily:
                                                WrytteTypography
                                                    .primaryFontFamily,
                                            color:
                                                Theme.of(context).disabledColor,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: TextButton(
                                        onPressed: null,
                                        child: Text(
                                          'Activate via call',
                                          style: TextStyle(
                                            fontFamily:
                                                WrytteTypography
                                                    .primaryFontFamily,
                                            color:
                                                Theme.of(context).disabledColor,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
          ),
        ),
      ),
    );
  }
}
