import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';

class BottomNavBar extends StatefulWidget {
  final int currentIndex;
  final Function(int) onTap;
  final int totalUnreadCount;
  final Widget? userAvatar;
  final UserProfile? initialProfile;
  final bool fetchProfileFromBackend;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.totalUnreadCount,
    this.userAvatar,
    this.initialProfile,
    this.fetchProfileFromBackend = true,
  });

  @override
  State<BottomNavBar> createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<BottomNavBar> {
  UserProfile? _profile;
  StreamSubscription<UserProfile?>? _profileSub;

  @override
  void initState() {
    super.initState();

    final initial =
        widget.initialProfile ??
        (widget.fetchProfileFromBackend
            ? null
            : UserProfileService.instance.cachedProfile);
    _profile = _isDisplayReadyProfile(initial) ? initial : null;

    // Subscribe to profile changes; the service validates that cached data
    // belongs to the currently signed-in account before emitting it.
    _profileSub = UserProfileService.instance
        .getCurrentUserProfileStream(
          backendFirst: widget.fetchProfileFromBackend,
          refreshFromBackend: widget.fetchProfileFromBackend,
        )
        .listen((profile) {
          if (mounted && _isDisplayReadyProfile(profile)) {
            setState(() => _profile = profile);
          }
        });
  }

  @override
  void didUpdateWidget(covariant BottomNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialProfile == oldWidget.initialProfile) return;
    final initial =
        widget.initialProfile ?? UserProfileService.instance.cachedProfile;
    // The profile stream is authoritative after this widget has received a
    // profile. HomeScreen's one-time startup preload can finish late and pass
    // an older same-account profile through initialProfile; never let it
    // overwrite a newer live avatar from the stream.
    final currentUid = _profile?.uid.trim().toLowerCase();
    final initialUid = initial?.uid.trim().toLowerCase();
    final isDifferentAccount =
        currentUid != null && initialUid != null && currentUid != initialUid;
    if (_isDisplayReadyProfile(initial) &&
        (_profile == null || isDifferentAccount)) {
      _profile = initial;
    }
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Background gradient — fills the entire nav bar region
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF0F1013).withValues(alpha: 0.0),
                  const Color(0xFF0F1013).withValues(alpha: 0.80),
                ],
              ),
            ),
          ),
        ),

        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 12, bottom: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(33),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF23262C).withValues(alpha: 0.30),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: const Color(0xFF23262C),
                      width: 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                    ),
                    child: BottomNavigationBar(
                      type: BottomNavigationBarType.fixed,
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      currentIndex: widget.currentIndex,
                      onTap: widget.onTap,
                      selectedItemColor: Colors.white,
                      unselectedItemColor: const Color(0xFF7A7A7A),
                      iconSize: 26,
                      selectedLabelStyle: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                      ),
                      items: [
                        /// Shops
                        BottomNavigationBarItem(
                          icon: _NavIcon(
                            isActive: widget.currentIndex == 0,
                            child: Image.asset(
                              'assets/svg/coin_icon.png',
                              height: 26,
                              width: 26,
                              color:
                                  widget.currentIndex == 0
                                      ? Colors.white
                                      : const Color(0xFF7A7A7A),
                              colorBlendMode: BlendMode.srcIn,
                            ),
                          ),
                          label: 'Shops',
                        ),

                        /// Chats
                        BottomNavigationBarItem(
                          icon: _NavIcon(
                            isActive: widget.currentIndex == 1,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                SvgPicture.asset(
                                  widget.currentIndex == 1
                                      ? 'assets/svg/chat_filled.svg'
                                      : 'assets/svg/chat_icon.svg',
                                  height: 26,
                                  width: 26,
                                  colorFilter: ColorFilter.mode(
                                    widget.currentIndex == 1
                                        ? Colors.white
                                        : const Color(0xFF7A7A7A),
                                    BlendMode.srcIn,
                                  ),
                                ),
                                if (widget.totalUnreadCount > 0)
                                  Positioned(
                                    top: -4,
                                    right: -4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      constraints: const BoxConstraints(
                                        minWidth: 16,
                                        minHeight: 16,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.blue,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        widget.totalUnreadCount > 99
                                            ? '99+'
                                            : widget.totalUnreadCount
                                                .toString(),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          label: 'Chats',
                        ),

                        /// Posts
                        BottomNavigationBarItem(
                          icon: _NavIcon(
                            isActive: widget.currentIndex == 2,
                            child: Image.asset(
                              'assets/svg/posts_icon.png',
                              height: 26,
                              width: 26,
                              color:
                                  widget.currentIndex == 2
                                      ? Colors.white
                                      : const Color(0xFF7A7A7A),
                              colorBlendMode: BlendMode.srcIn,
                            ),
                          ),
                          label: 'Posts',
                        ),

                        /// Calls
                        BottomNavigationBarItem(
                          icon: _NavIcon(
                            isActive: widget.currentIndex == 3,
                            child: Icon(
                              widget.currentIndex == 3
                                  ? Icons.call
                                  : Icons.call_outlined,
                              size: 26,
                              color:
                                  widget.currentIndex == 3
                                      ? Colors.white
                                      : const Color(0xFF7A7A7A),
                            ),
                          ),
                          label: 'Calls',
                        ),

                        /// Profile — real profile avatar
                        BottomNavigationBarItem(
                          icon: _NavIcon(
                            isActive: widget.currentIndex == 4,
                            isAvatar: true,
                            child: UserAvatar(
                              size: 28,
                              imageUrl:
                                  _profile?.hasProfileImage == true
                                      ? _profile!.profileImage
                                      : null,
                              localImagePath: _profile?.localProfileImagePath,
                              name: _profileNameForAvatar(),
                              cacheIdentity:
                                  _profile == null
                                      ? null
                                      : 'account:${_profile!.uid.trim().toLowerCase()}'
                                          '|avatar:v${_profile!.avatarVersion}',
                            ),
                          ),
                          label: _profileTabLabel(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String? _profileNameForAvatar() {
    final name = _profileDisplayName();
    return name.isEmpty ? null : name;
  }

  String _profileTabLabel() {
    final name = _profileDisplayName();
    if (name.isEmpty) return 'Profile';
    return name.split(RegExp(r'\s+')).first;
  }

  String _profileDisplayName() {
    final name = _profile?.displayName.trim() ?? '';
    if (name.isEmpty || _looksLikePhone(name)) return '';
    return name;
  }

  bool _looksLikePhone(String value) {
    final stripped = value.trim().replaceAll(RegExp(r'[\s\-()+]'), '');
    return stripped.length >= 7 && RegExp(r'^\d+$').hasMatch(stripped);
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
}

class _NavIcon extends StatelessWidget {
  final Widget child;
  final bool isActive;
  final bool isAvatar;

  const _NavIcon({
    required this.child,
    required this.isActive,
    this.isAvatar = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isActive && !isAvatar) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: child,
      );
    }

    if (isAvatar) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: child,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: child,
    );
  }
}
