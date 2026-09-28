import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class EmailVerificationPage extends StatefulWidget {
  final String email;
  final String virtualNumber;

  const EmailVerificationPage({
    super.key,
    required this.email,
    required this.virtualNumber,
  });

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _otpCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  bool _loading = false;

  int _seconds = 60;
  bool _canResend = false;
  Timer? _timer;

  bool get _valid => _otpCtrl.text.trim().length == 6;

  @override
  void initState() {
    super.initState();

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -12), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -12, end: 12), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 12, end: -12), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -12, end: 0), weight: 1),
    ]).animate(_shakeController);

    _startTimer();

    // Autofocus input
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _startTimer() {
    _seconds = 60;
    _canResend = false;
    _timer?.cancel();

    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_seconds > 0) {
        if (mounted) setState(() => _seconds--);
      } else {
        if (mounted) setState(() => _canResend = true);
        t.cancel();
      }
    });
  }

  Future<void> _verify() async {
    if (!_valid || _loading) return;

    setState(() => _loading = true);
    HapticFeedback.lightImpact();

    try {
      await AuthService.instance.registerVirtualPhone(
        email: widget.email.trim(),
        code: _otpCtrl.text.trim(),
        phone: widget.virtualNumber,
        login: true,
      );

      if (!mounted) return;

      Navigator.pushNamedAndRemoveUntil(
        context,
        '/auth/profile',
        (_) => false,
      );
    } catch (e) {
      _shakeController.forward(from: 0);
      HapticFeedback.mediumImpact();
      _otpCtrl.clear(); // clear so user can retype

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Invalid or expired verification code"),
            backgroundColor: Colors.red,
          ),
        );
        // Re-focus so keyboard stays up for retry
        _focusNode.requestFocus();
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    if (!_canResend || _loading) return;

    setState(() => _loading = true);

    try {
      await AuthService.instance.sendEmailCode(widget.email.trim());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Verification code sent")),
        );
        _startTimer();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Failed to resend code"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _otpCtrl.dispose();
    _focusNode.dispose();
    _shakeController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  Widget _buildOtpBoxes() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final text = _otpCtrl.text;
        final screenWidth = constraints.maxWidth;
        final availableWidth = screenWidth - 40;
        final boxSize = (availableWidth - 40) / 6;
        final boxWidth = boxSize.clamp(36.0, 48.0);

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(6, (i) {
            final char = i < text.length ? text[i] : '';
            final isCurrent = i == text.length && text.length < 6;

            return Container(
              width: boxWidth,
              height: boxWidth + 10,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF0F1013),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: char.isNotEmpty || isCurrent
                      ? const Color(0xFF4DA3FF)
                      : Colors.white24,
                  width: isCurrent ? 2 : 1,
                ),
              ),
              child: Text(
                char,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            children: [
              /// Back
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),

              const SizedBox(height: 24),

              const Text(
                "Activate your account",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                "We've sent a code to email\n${widget.email}.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),

              const SizedBox(height: 32),

              AnimatedBuilder(
                animation: _shakeAnimation,
                builder: (_, child) => Transform.translate(
                  offset: Offset(_shakeAnimation.value, 0),
                  child: child,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF23262C),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        "Enter 6-digit code",
                        style: TextStyle(color: Colors.white54),
                      ),
                      const SizedBox(height: 16),

                      // ── FIX: GestureDetector requests focus when user taps
                      //    anywhere on the OTP boxes area, opening the keyboard.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _focusNode.requestFocus(),
                        child: _buildOtpBoxes(),
                      ),

                      // Hidden TextField — zero-height so it is invisible but
                      // still receives keyboard input.
                      SizedBox(
                        height: 0,
                        child: TextField(
                          controller: _otpCtrl,
                          focusNode: _focusNode,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            counterText: "",
                            border: InputBorder.none,
                          ),
                          style: const TextStyle(color: Colors.transparent),
                          cursorColor: Colors.transparent,
                          onChanged: (_) {
                            setState(() {});
                            if (_valid) _verify();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              Center(
                child: Text(
                  "00:${_seconds.toString().padLeft(2, '0')}",
                  style: const TextStyle(color: Colors.white54),
                ),
              ),

              const Spacer(),

              Center(
                child: TextButton(
                  onPressed: _canResend && !_loading ? _resend : null,
                  child: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF4DA3FF),
                          ),
                        )
                      : Text(
                          "Resend code",
                          style: TextStyle(
                            color: _canResend
                                ? const Color(0xFF4DA3FF)
                                : Colors.white24,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
