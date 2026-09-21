import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/device_metadata_service.dart';
import 'package:wrytte/services/auth/device_region_service.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';
import 'package:wrytte/ui/auth/phone_auth_page.dart';
import 'package:wrytte/ui/auth/sign_in_page.dart';
import 'package:wrytte/ui/auth/virtual_number_page.dart';
import 'package:wrytte/ui/screens/terms_privacy_page.dart';

class AuthEntryScreen extends StatefulWidget {
  const AuthEntryScreen({super.key});

  @override
  State<AuthEntryScreen> createState() => _AuthEntryScreenState();
}

class _AuthEntryScreenState extends State<AuthEntryScreen> {
  Future<String>? _signupRegion;
  bool _agreed = false;

  @override
  Widget build(BuildContext context) {
    if (_agreed) return _buildSignupMethodPage(context);

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: SizedBox(
                height: math.max(constraints.maxHeight, 728),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Column(
                    children: [
                      const SizedBox(height: 120),
                      const _TtMark(),
                      const SizedBox(height: 52),
                      Text(
                        'Welcome to Wrytte',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          height: 1.1,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'A secure social messenger for chatting,\nsharing moments, creating communities, and\nstaying connected with the people who\nmatter most.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          height: 1.35,
                        ),
                      ),
                      const Spacer(),
                      _termsText(context),
                      const SizedBox(height: 24),
                      _buildPrimaryButton(
                        text: 'Agree and continue',
                        onTap: _agreeAndContinue,
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSignupMethodPage(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom,
            ),
            child: IntrinsicHeight(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 220,
                        child: Image.asset(
                          'assets/images/wrytte_logo.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: 1),
                      const Text(
                        'Sign Up',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 40),
                      _buildButton(
                        context: context,
                        text: 'Wrytte ID',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => VirtualNumberPage(
                                regionCodeFuture: _signupRegion ??=
                                    DeviceRegionService.detectOnce(),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      _buildButton(
                        context: context,
                        text: 'Phone number',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const PhoneAuthPage(),
                            ),
                          );
                          unawaited(
                            VirtualNumberService().clearPendingWrytteId(),
                          );
                        },
                      ),
                      const SizedBox(height: 40),
                      _loginLink(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _termsText(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.45),
        children: [
          const TextSpan(text: 'By continuing, you agree to the '),
          TextSpan(
            text: 'Wrytte Terms of Service',
            style: const TextStyle(color: Color(0xFF4DA3FF)),
            recognizer:
                TapGestureRecognizer()
                  ..onTap =
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TermsPrivacyPage(),
                        ),
                      ),
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'App Privacy',
            style: const TextStyle(color: Color(0xFF4DA3FF)),
            recognizer:
                TapGestureRecognizer()
                  ..onTap =
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TermsPrivacyPage(),
                        ),
                      ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _loginLink(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Already have an account? ',
          style: TextStyle(color: Colors.white70, fontSize: 16),
        ),
        GestureDetector(
          onTap:
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SignInPage()),
              ),
          child: const Text(
            'Log In',
            style: TextStyle(
              color: Color(0xFF4DA3FF),
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  void _agreeAndContinue() {
    if (_agreed) return;
    setState(() => _agreed = true);
    unawaited(_collectDeviceMetadata());
  }

  Future<void> _collectDeviceMetadata() async {
    try {
      await DeviceMetadataService.instance.collect();
      _signupRegion ??= DeviceRegionService.detectOnce();
    } catch (error) {
      debugPrint('[AuthEntryScreen] device metadata collection failed: $error');
    }
  }

  Widget _buildPrimaryButton({
    required String text,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF4DA3FF),
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(38),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  Widget _buildButton({
    required BuildContext context,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF23262C),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _TtMark extends StatelessWidget {
  const _TtMark();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 86,
      height: 84,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned(
            left: 0,
            bottom: 0,
            child: Text(
              'tt',
              style: TextStyle(
                color: Colors.white,
                fontSize: 78,
                height: .8,
                fontWeight: FontWeight.w900,
                letterSpacing: -12,
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: Color(0xFFFF5964),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
