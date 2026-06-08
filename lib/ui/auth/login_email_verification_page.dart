import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

class LoginEmailVerificationPage extends StatefulWidget {
  final String email;
  final String virtualNumber;

  const LoginEmailVerificationPage({
    super.key,
    required this.email,
    required this.virtualNumber,
  });

  @override
  State<LoginEmailVerificationPage> createState() =>
      _LoginEmailVerificationPageState();
}

class _LoginEmailVerificationPageState extends State<LoginEmailVerificationPage>
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
        if (mounted) {
          setState(() => _seconds--);
        }
      } else {
        if (mounted) {
          setState(() => _canResend = true);
        }
        t.cancel();
      }
    });
  }

  /// LOGIN VERIFY
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

      /// Navigate to Home
      final currentUser = await AuthService.instance.getCurrentUser();
      if (!mounted) return;

      if (currentUser != null) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder:
                (_) => HomeScreen(
                  currentUserId:
                      currentUser.userId, // Pass the logged-in user ID
                  initialProfileName: currentUser.username,
                  initialPhone: currentUser.phone,
                ),
          ),
          (_) => false,
        );
      }
    } catch (e) {
      _shakeController.forward(from: 0);
      HapticFeedback.mediumImpact();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Invalid or expired verification code"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _resend() async {
    if (!_canResend || _loading) return;

    setState(() => _loading = true);

    try {
      await AuthService.instance.sendEmailCode(widget.email.trim());

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Verification code sent")));

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
        // Calculate responsive width based on available space
        final screenWidth = constraints.maxWidth;
        // 20px horizontal padding on container + spacing between boxes
        final availableWidth =
            screenWidth - 40; // 20px left + 20px right padding
        final boxSize =
            (availableWidth - 40) / 6; // 40 = total spacing (8px * 5 gaps)
        final boxWidth = boxSize.clamp(36.0, 48.0); // Min 36, max 48

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(6, (i) {
            final char = i < text.length ? text[i] : '';

            return Container(
              width: boxWidth,
              height: boxWidth + 10, // Proportional height
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF0F1013),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      char.isNotEmpty
                          ? const Color(0xFF4DA3FF)
                          : Colors.white24,
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
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),

              const SizedBox(height: 24),

              const Text(
                "Login verification",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                "We’ve sent a code to email\n${widget.email}.",
                style: const TextStyle(color: Colors.white54),
              ),

              const SizedBox(height: 32),

              AnimatedBuilder(
                animation: _shakeAnimation,
                builder:
                    (_, child) => Transform.translate(
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
                      _buildOtpBoxes(),

                      TextField(
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
                          if (_valid) {
                            _verify();
                          }
                        },
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
                  child:
                      _loading
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
                              color:
                                  _canResend
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
