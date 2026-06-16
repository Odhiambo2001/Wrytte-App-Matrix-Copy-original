import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
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
  final String? initialProfileName;
  final String? initialPhone;
  final List<Contact> initialSavedContacts;

  const HomeScreen({
    super.key,
    required this.currentUserId,
    this.initialProfileName,
    this.initialPhone,
    this.initialSavedContacts = const [],
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const Duration _fallbackBackendRefreshInterval = Duration(minutes: 30);

  int _currentIndex = 1; // Default to Chats
  int _totalUnreadCount = 0;
  late final List<Widget> _screens;
  Timer? _backendTokenTimer;
  bool _backendRefreshInFlight = false;
  UserProfile? _bottomNavProfile;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final cached = UserProfileService.instance.cachedProfile;
    if (_isDisplayReadyProfile(cached)) {
      _bottomNavProfile = cached;
    } else {
      final initialProfile = _initialSessionProfile();
      if (_isDisplayReadyProfile(initialProfile)) {
        _bottomNavProfile = initialProfile;
      }
    }
    unawaited(_primeBottomNavProfile());
    _refreshBackendTokenIfNeeded();
    _scheduleBackendTokenRefresh();
    unawaited(BackendRealtimeService.instance.connect());
    _screens = [
      const ShopsScreen(),
      ConversationsScreen(
        onUnreadCountUpdated: _updateUnreadCount,
        currentUserId: widget.currentUserId,
        initialSavedContacts: widget.initialSavedContacts,
      ),
      const PostScreen(),
      const CallsScreen(),
      const SettingsScreen(),
    ];
  }

  Future<void> _primeBottomNavProfile() async {
    final cached = UserProfileService.instance.cachedProfile;
    if (_isDisplayReadyProfile(cached)) {
      setState(() {
        _bottomNavProfile = cached;
      });
      unawaited(UserProfileService.instance.warmUp());
      return;
    }

    final profile = await UserProfileService.instance.getCurrentUserProfile(
      forceRefresh: true,
    );
    if (!mounted) return;
    setState(() {
      _bottomNavProfile = _isDisplayReadyProfile(profile) ? profile : null;
    });
  }

  bool _isDisplayReadyProfile(UserProfile? profile) {
    if (profile == null) return false;
    final name = profile.displayName.trim();
    final avatar = profile.profileImage.trim();
    final localAvatar = profile.localProfileImagePath.trim();
    return (name.isNotEmpty && !_looksLikePhone(name)) ||
        avatar.isNotEmpty ||
        localAvatar.isNotEmpty;
  }

  UserProfile? _initialSessionProfile() {
    final name = widget.initialProfileName?.trim() ?? '';
    if (name.isEmpty || _looksLikePhone(name)) return null;
    return UserProfile(
      uid: widget.currentUserId,
      name: name,
      username: name,
      phone: widget.initialPhone?.trim() ?? '',
      bio: '',
      profileImage: '',
      links: const [],
    );
  }

  bool _looksLikePhone(String value) {
    final stripped = value.trim().replaceAll(RegExp(r'[\s\-()+]'), '');
    return stripped.length >= 7 && RegExp(r'^\d+$').hasMatch(stripped);
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
    if (!mounted) return;
    if (_totalUnreadCount == count) return;

    final phase = WidgetsBinding.instance.schedulerPhase;
    final isBuilding =
        phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.transientCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
    if (isBuilding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _totalUnreadCount == count) return;
        setState(() {
          _totalUnreadCount = count;
        });
      });
      return;
    }

    setState(() {
      _totalUnreadCount = count;
    });
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
          Positioned.fill(
            child: IndexedStack(index: _currentIndex, children: _screens),
          ),
        ],
      ),
      // FLOATING GLASS NAV
      bottomNavigationBar: BottomNavBar(
        currentIndex: _currentIndex,
        onTap: _onTabTapped,
        totalUnreadCount: _totalUnreadCount,
        initialProfile: _bottomNavProfile,
      ),
    );
  }
}
