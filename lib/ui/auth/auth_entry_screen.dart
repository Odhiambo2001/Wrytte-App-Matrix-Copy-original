import 'package:flutter/material.dart';
import 'package:wrytte/core/theme.dart';
import 'package:wrytte/services/auth/device_region_service.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';
import 'package:wrytte/ui/auth/auth_entry_components.dart';
import 'package:wrytte/ui/auth/phone_auth_page.dart';
import 'package:wrytte/ui/auth/sign_in_page.dart';
import 'package:wrytte/ui/widgets/theme_wrapper.dart';

class AuthEntryScreen extends StatefulWidget {
  const AuthEntryScreen({super.key});

  @override
  State<AuthEntryScreen> createState() => _AuthEntryScreenState();
}

class _AuthEntryScreenState extends State<AuthEntryScreen> {
  Future<String>? _signupRegion;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: WrytteTheme.background,
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 350;
          final contentMinHeight = (constraints.maxHeight - 48).clamp(
            0.0,
            double.infinity,
          );
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 20),
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      sliver: SliverToBoxAdapter(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: contentMinHeight,
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                WrytteAuthOptions(
                                  onWrytteIdPressed: _openWrytteId,
                                  onPhonePressed: _openPhone,
                                ),
                                const SizedBox(height: 24),
                                WrytteAuthLoginFooter(
                                  onLogInPressed: _openSignIn,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Future<void> _openWrytteId() async {
    final regionCode =
        await (_signupRegion ??= DeviceRegionService.detectOnce());
    if (!mounted) return;
    Navigator.pushNamed(context, '/auth/wrytte-id', arguments: regionCode);
  }

  Future<void> _openPhone() async {
    await VirtualNumberService().clearPendingWrytteId();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PhoneAuthPage()),
    );
  }

  void _openSignIn() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ThemeWrapper(child: SignInPage(key: UniqueKey())),
      ),
    );
  }
}
