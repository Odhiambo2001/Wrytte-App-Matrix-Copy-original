import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/real_number_service.dart';
import 'package:wrytte/ui/auth/add_profile_page.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

class OtpVerificationPage extends StatefulWidget {
  final String phoneNumber;
  final bool isSignInFlow;

  const OtpVerificationPage({
    super.key,
    required this.phoneNumber,
    this.isSignInFlow = false,
  });

  @override
  State<OtpVerificationPage> createState() => _OtpVerificationPageState();
}

class _OtpVerificationPageState extends State<OtpVerificationPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _otpController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  final RealNumberService _realNumberService = RealNumberService();

  bool _isLoading = false;
  String? _errorMessage;

  int _secondsRemaining = 60;
  bool _canResend = false;
  Timer? _timer;

  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  bool get _isValid => _otpController.text.length == 6;

  @override
  void initState() {
    super.initState();
    _startResendTimer();

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -10), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10, end: 10), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10, end: 0), weight: 1),
    ]).animate(_shakeController);

    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _startResendTimer() {
    _secondsRemaining = 60;
    _canResend = false;
    _timer?.cancel();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        if (mounted) setState(() => _secondsRemaining--);
      } else {
        if (mounted) setState(() => _canResend = true);
        timer.cancel();
      }
    });
  }

  Future<void> _verifyOtp() async {
    if (!_isValid || _isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    HapticFeedback.lightImpact();

    try {
      final result = await _realNumberService.registerRealPhone(
        fullPhone: widget.phoneNumber,
        code: _otpController.text,
        login: true,
      );

      if (!mounted) return;

      // ── Routing logic ────────────────────────────────────────────────────
      //
      // result.isNewUser = true  → first signup  → MUST set profile name
      // result.isNewUser = false → returning user → go straight to HomeScreen
      //
      // NOTE: isSignInFlow is kept for callers that explicitly set it, but
      // isNewUser from the server is the authoritative source of truth.
      // A phone that already has an account always skips AddProfilePage,
      // even if somehow routed through the signup UI.

      if (result.isNewUser) {
        // First-time signup only — must set profile name
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => const AddProfilePage(isNewUser: true),
          ),
          (_) => false,
        );
      } else {
        // Returning user (same number, second signup+) — skip profile page entirely
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => HomeScreen(currentUserId: result.userId),
          ),
          (_) => false,
        );
      }
  } catch (e) {
  HapticFeedback.heavyImpact();
  _shakeController.forward(from: 0);

  if (!mounted) return;

  // Convert raw API errors into user friendly messages
  String friendlyMessage;
  final raw = e.toString().toLowerCase();

  if (raw.contains('invalid') ||
      raw.contains('incorrect') ||
      raw.contains('wrong') ||
      raw.contains('code') ||
      raw.contains('forbidden') ||
      raw.contains('401') ||
      raw.contains('400')) {
    friendlyMessage = 'Incorrect code. Please enter the correct 6-digit code.';
  } else if (raw.contains('network') ||
             raw.contains('socket') ||
             raw.contains('timeout') ||
             raw.contains('connection')) {
    friendlyMessage = 'No internet connection. Please check your network and try again.';
  } else if (raw.contains('not found') || raw.contains('404')) {
    friendlyMessage = 'Account not found. Please check your phone number.';
  } else {
    friendlyMessage = 'Something went wrong. Please try again.';
  }

  setState(() {
    _errorMessage = friendlyMessage;
    _otpController.clear();
  });

    debugPrint('OTP ERROR: $e');
  } finally {
    if (mounted) setState(() => _isLoading = false);
  }
  }

  Future<void> _resendCode() async {
    if (!_canResend || _isLoading) return;

    setState(() => _isLoading = true);

    try {
      await _realNumberService.sendSmsCode(widget.phoneNumber);
      _startResendTimer();
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = 'Failed to resend code');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildOtpBoxes() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final boxSize = (screenWidth - 48) / 6;
        final boxWidth = boxSize.clamp(36.0, 48.0);

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(6, (index) {
            final char =
                index < _otpController.text.length
                    ? _otpController.text[index]
                    : '';

            return Container(
              width: boxWidth,
              height: boxWidth + 10,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF23262C),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                char.isEmpty ? '—' : char,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
            );
          }),
        );
      },
    );
  }

  @override
  void dispose() {
    _otpController.dispose();
    _focusNode.dispose();
    _timer?.cancel();
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: keyboardHeight),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),

              const SizedBox(height: 40),

              const Text(
                'Activate your account',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),

              const SizedBox(height: 10),

              Text(
                'We\'ve sent a code by SMS to phone\nnumber ${widget.phoneNumber}.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),

              const SizedBox(height: 30),

              AnimatedBuilder(
                animation: _shakeAnimation,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(_shakeAnimation.value, 0),
                    child: child,
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    vertical: 18,
                    horizontal: 16,
                  ),
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF23262C),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Enter 6-digit code',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      _buildOtpBoxes(),
                      TextField(
                        controller: _otpController,
                        focusNode: _focusNode,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        maxLength: 6,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          counterText: '',
                        ),
                        style: const TextStyle(color: Colors.transparent),
                        cursorColor: Colors.transparent,
                        onChanged: (_) {
                          setState(() {});
                          if (_otpController.text.length == 6) {
                            _verifyOtp();
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),

              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),

              const SizedBox(height: 20),

              Text(
                '00:${_secondsRemaining.toString().padLeft(2, '0')}',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),

              const SizedBox(height: 40),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  TextButton(
                    onPressed: _canResend ? _resendCode : null,
                    child: const Text(
                      'Resend SMS',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                  const Text(
                    'Activate via call',
                    style: TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
