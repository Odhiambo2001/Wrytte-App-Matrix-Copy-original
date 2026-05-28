import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/backend/backend_realtime_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/chats/conversations_screen.dart'; // ← this one
import 'calls/calls_screen.dart';
import 'post/post_screen.dart';
import 'shops/shops_screen.dart';
import 'settings/settings_screen.dart';
import '../widgets/bottom_nav_bar.dart';

class HomeScreen extends StatefulWidget {
  final String currentUserId;
  const HomeScreen({super.key, required this.currentUserId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const Duration _fallbackBackendRefreshInterval = Duration(minutes: 30);

  int _currentIndex = 1; // Default to Chats
  int _totalUnreadCount = 0;
  Timer? _backendTokenTimer;
  bool _backendRefreshInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Warm up the profile cache immediately so the bottom nav avatar
    // is ready on the very first frame — no visible delay.
    UserProfileService.instance.warmUp();
    _refreshBackendTokenIfNeeded();
    _scheduleBackendTokenRefresh();
    unawaited(BackendRealtimeService.instance.connect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backendTokenTimer?.cancel();
    unawaited(BackendRealtimeService.instance.disconnect());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshBackendTokenIfNeeded();
      _scheduleBackendTokenRefresh();
      unawaited(BackendRealtimeService.instance.connect());
    } else {
      _backendTokenTimer?.cancel();
      _backendTokenTimer = null;
      unawaited(BackendRealtimeService.instance.disconnect());
    }
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
    _refreshBackendTokenIfNeeded();
  }

  Future<void> _refreshBackendTokenIfNeeded() async {
    if (_backendRefreshInFlight) return;
    _backendRefreshInFlight = true;
    try {
      await AuthService.instance.getValidBackendToken();
    } catch (e) {
      debugPrint('[HomeScreen] Backend token refresh/check skipped: $e');
    } finally {
      _backendRefreshInFlight = false;
      if (mounted) _scheduleBackendTokenRefresh();
    }
  }

  Future<void> _scheduleBackendTokenRefresh() async {
    _backendTokenTimer?.cancel();
    if (!mounted) return;

    final expiresAt = await AuthService.instance.getBackendTokenExpiry();
    if (!mounted) return;

    final now = DateTime.now();
    final delay =
        expiresAt == null
            ? _fallbackBackendRefreshInterval
            : expiresAt.isAfter(now)
            ? expiresAt.difference(now) + const Duration(seconds: 1)
            : const Duration(minutes: 1);

    _backendTokenTimer = Timer(delay, _refreshBackendTokenIfNeeded);
  }

  void _updateUnreadCount(int count) {
    if (mounted) {
      setState(() {
        _totalUnreadCount = count;
      });
    }
  }

  Widget _buildCurrentScreen() {
    switch (_currentIndex) {
      case 0:
        return const ShopsScreen();
      case 1:
        return ConversationsScreen(
          onUnreadCountUpdated: _updateUnreadCount,
          currentUserId: widget.currentUserId,
        );
      case 2:
        return const PostScreen();
      case 3:
        return const CallsScreen();
      case 4:
        return const SettingsScreen();
      default:
        return ConversationsScreen(
          onUnreadCountUpdated: _updateUnreadCount,
          currentUserId: widget.currentUserId,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // CRITICAL FOR GLASS UI
      extendBody: true,
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      // REAL BACKGROUND (not Scaffold)
      body: Stack(
        children: [
          // Background layer
          Container(color: const Color(0xFF08090B)),
          // Screen content
          Positioned.fill(child: _buildCurrentScreen()),
        ],
      ),
      // FLOATING GLASS NAV
      bottomNavigationBar: BottomNavBar(
        currentIndex: _currentIndex,
        onTap: _onTabTapped,
        totalUnreadCount: _totalUnreadCount,
      ),
    );
  }
}
