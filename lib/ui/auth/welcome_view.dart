import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/device_metadata_service.dart';
import 'package:wrytte/services/auth/device_region_service.dart';
import 'package:wrytte/ui/auth/auth_entry_screen.dart';
import 'package:wrytte/ui/auth/welcome_intro.dart';
import 'package:wrytte/ui/screens/terms_privacy_page.dart';

class WelcomeView extends StatelessWidget {
  const WelcomeView({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF08090B),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
        child: SizedBox(
          height: 56,
          child: ElevatedButton(
            onPressed: () {
              unawaited(_collectDeviceMetadata());
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const AuthEntryScreen()),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4DA3FF),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(38),
              ),
            ),
            child: const Text(
              'Agree and continue',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),
    ),
    body: SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    18,
                    ((constraints.maxHeight - 336) * .40).clamp(
                      24.0,
                      double.infinity,
                    ),
                    18,
                    4,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const WelcomeIntro(),
                      const SizedBox(height: 32),
                      _WelcomeLegal(
                        onOpenLegal: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const TermsPrivacyPage(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  static Future<void> _collectDeviceMetadata() async {
    try {
      await DeviceMetadataService.instance.collect();
      unawaited(DeviceRegionService.detectOnce());
    } catch (error) {
      debugPrint('[WelcomeView] device metadata collection failed: $error');
    }
  }
}

class _WelcomeLegal extends StatelessWidget {
  const _WelcomeLegal({required this.onOpenLegal});

  final VoidCallback onOpenLegal;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      link: true,
      label: 'Open Wrytte Terms of Service and App Privacy',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpenLegal,
          borderRadius: BorderRadius.circular(8),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: Text.rich(
                TextSpan(
                  style: TextStyle(color: Colors.white, fontSize: 16, height: 1.45),
                  children: [
                    TextSpan(text: 'By continuing, you agree to the '),
                    TextSpan(
                      text: 'Wrytte\nTerms of Service',
                      style: TextStyle(color: Color(0xFF4DA3FF)),
                    ),
                    TextSpan(
                      text: ' and App Privacy',
                      style: TextStyle(color: Color(0xFF4DA3FF)),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
