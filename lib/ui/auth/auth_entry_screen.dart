import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/device_region_service.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';
import 'package:wrytte/ui/auth/phone_auth_page.dart';
import 'package:wrytte/ui/auth/sign_in_page.dart';
import 'package:wrytte/ui/auth/virtual_number_page.dart';

class AuthEntryScreen extends StatefulWidget {
  const AuthEntryScreen({super.key});

  @override
  State<AuthEntryScreen> createState() => _AuthEntryScreenState();
}

class _AuthEntryScreenState extends State<AuthEntryScreen> {
  late final Future<String> _signupRegion;

  @override
  void initState() {
    super.initState();
    // Start one SIM/network/locale detection when signup is first displayed.
    _signupRegion = DeviceRegionService.detectOnce();
  }

  @override
  Widget build(BuildContext context) {
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
                        "Sign Up",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w500,
                        ),
                      ),

                      const SizedBox(height: 40),

                      _buildButton(
                        context: context,
                        text: "Wrytte ID",
                        onTap: () async {
                          final regionCode = await _signupRegion;
                          if (!context.mounted) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder:
                                  (_) =>
                                      VirtualNumberPage(regionCode: regionCode),
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 20),

                      _buildButton(
                        context: context,
                        text: "Phone number",
                        onTap: () async {
                          await VirtualNumberService().clearPendingWrytteId();
                          if (!context.mounted) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const PhoneAuthPage(),
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 40),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            "Already have an account? ",
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const SignInPage(),
                                ),
                              );
                            },
                            child: const Text(
                              "Log In",
                              style: TextStyle(
                                color: Color(0xFF4DA3FF),
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
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

  Widget _buildButton({
    required BuildContext context,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
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
