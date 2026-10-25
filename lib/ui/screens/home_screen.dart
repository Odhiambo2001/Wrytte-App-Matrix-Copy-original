import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/active_device_challenge_service.dart';
import 'package:wrytte/services/backend/backend_realtime_service.dart';
import 'package:wrytte/services/call_listener_service.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/chats/conversations_screen.dart'; // ← this one
import 'package:wrytte/ui/screens/profile_screen.dart';
import 'calls/calls_screen.dart';
import 'post/post_screen.dart';
import 'shops/shops_screen.dart';
import '../widgets/bottom_nav_bar.dart';

class HomeScreen extends StatefulWidget {
  final String currentUserId;
  final String? initialProfileName;
  final String? initialPhone;
  final List<Contact> initialSavedContacts;
  final bool isFirstSignup;

  const HomeScreen({
    super.key,
    required this.currentUserId,
    this.initialProfileName,
    this.initialPhone,
    this.initialSavedContacts = const [],
    this.isFirstSignup = false,
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
  final CallListenerService _callListener = CallListenerService();
  final ActiveDeviceChallengeService _activeDeviceChallenges =
      ActiveDeviceChallengeService();
  final Stopwatch _homeStartupClock = Stopwatch();

  @override
  void initState() {
    super.initState();
    _homeStartupClock.start();
    debugPrint('[HomeAvatar] home_init user="${widget.currentUserId}"');
    UserProfileService.instance.setFirstSignupMode(widget.isFirstSignup);
    WidgetsBinding.instance.addObserver(this);
    if (widget.isFirstSignup) {
      final initialProfile = _initialSessionProfile();
      if (_isDisplayReadyProfile(initialProfile)) {
        _bottomNavProfile = initialProfile;
      }
    }
    // A first signup must never inherit a profile/avatar from a previous
    // session on this device. Its first frame is built only from the newly
    // authenticated signup result. Returning login is backend-authoritative.
    if (!widget.isFirstSignup) {
      unawaited(_primeBottomNavProfile());
    }
    _refreshBackendTokenIfNeeded();
    _scheduleBackendTokenRefresh();
    unawaited(BackendRealtimeService.instance.connect());
    unawaited(_activeDeviceChallenges.start());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _callListener.startListening(context);
    });
    _screens = [
      const ShopsScreen(),
      ConversationsScreen(
        onUnreadCountUpdated: _updateUnreadCount,
        currentUserId: widget.currentUserId,
        initialSavedContacts: widget.initialSavedContacts,
      ),
      const PostScreen(),
      const CallsScreen(),
      ProfileScreen(
        embeddedInHome: true,
        initialProfileName: widget.initialProfileName,
      ),
    ];
  }

  Future<void> _primeBottomNavProfile() async {
    debugPrint(
      '[HomeAvatar] prime_start t_ms=${_homeStartupClock.elapsedMilliseconds} '
      'source=local_first',
    );
    if (!widget.isFirstSignup) {
      final localProfile = await UserProfileService.instance
          .getCurrentUserProfileLocalOnly();
      if (mounted && _isDisplayReadyProfile(localProfile)) {
        setState(() => _bottomNavProfile = localProfile);
        debugPrint(
          '[HomeAvatar] local_ready t_ms=${_homeStartupClock.elapsedMilliseconds} '
          'uid="${localProfile!.uid}" has_avatar=${localProfile.hasProfileImage} '
          'url="${localProfile.profileImage}"',
        );
        if (localProfile.hasProfileImage) {
          unawaited(
            AvatarPreloadService.warm(
              localProfile.profileImage,
              cacheIdentity:
                  'account:${localProfile.uid.trim().toLowerCase()}'
                  '|avatar:v${localProfile.avatarVersion}',
            ),
          );
        }
      }

      final refreshed = await UserProfileService.instance
          .getCurrentUserProfileForLogin();
      final localAvatar = localProfile?.profileImage.trim() ?? '';
      final profile =
          refreshed != null &&
              !refreshed.hasProfileImage &&
              localAvatar.isNotEmpty
          ? refreshed.copyWith(
              profileImage: localAvatar,
              localProfileImagePath: localProfile?.localProfileImagePath,
            )
          : refreshed;
      debugPrint(
        '[HomeAvatar] profile_ready t_ms=${_homeStartupClock.elapsedMilliseconds} '
        'uid="${profile?.uid ?? ''}" has_avatar=${profile?.hasProfileImage ?? false} '
        'url="${profile?.profileImage ?? ''}" local="${profile?.localProfileImagePath ?? ''}"',
      );
      if (profile?.hasProfileImage == true) {
        final preloadStarted = DateTime.now();
        await AvatarPreloadService.warm(
          profile!.profileImage,
          cacheIdentity:
              'account:${profile.uid.trim().toLowerCase()}'
              '|avatar:v${profile.avatarVersion}',
        );
        debugPrint(
          '[HomeAvatar] preload_done t_ms=${_homeStartupClock.elapsedMilliseconds} '
          'user_id="${profile.uid}" version=${profile.avatarVersion} '
          'elapsed_ms=${DateTime.now().difference(preloadStarted).inMilliseconds}',
        );
      }
      if (!mounted) return;
      setState(() {
        _bottomNavProfile = _isDisplayReadyProfile(profile) ? profile : null;
      });
      debugPrint(
        '[HomeAvatar] navbar_state t_ms=${_homeStartupClock.elapsedMilliseconds} '
        'display=${_bottomNavProfile != null}',
      );
      return;
    }

    // Signup intentionally performs no local profile/avatar lookup. The
    // caller-provided new-account identity was installed synchronously in
    // initState and the user can create an avatar after entering the account.
    return;
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
    _callListener.stopListening();
    unawaited(_activeDeviceChallenges.stop());
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
      unawaited(_activeDeviceChallenges.start());
    } else {
      _backendTokenTimer?.cancel();
      _backendTokenTimer = null;
      unawaited(BackendRealtimeService.instance.disconnect());
      unawaited(_activeDeviceChallenges.stop());
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
    final delay = expiresAt == null
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
        // Profile is primed in the background; the navbar paints immediately
        // and updates via setState when the backend profile arrives.
        fetchProfileFromBackend: false,
      ),
    );
  }
}
