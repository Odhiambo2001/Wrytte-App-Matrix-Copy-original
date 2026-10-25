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
  static const Color _activeColor = Colors.white;
  static const Color _inactiveColor = Color(0xFF7A7A7A);

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
    debugPrint(
      '[BottomNavAvatar] init display=${_profile != null} '
      'uid="${_profile?.uid ?? ''}" has_avatar=${_profile?.hasProfileImage ?? false} '
      'url="${_profile?.profileImage ?? ''}"',
    );

    _profileSub = UserProfileService.instance
        .getCurrentUserProfileStream(
          backendFirst: widget.fetchProfileFromBackend,
          refreshFromBackend: widget.fetchProfileFromBackend,
        )
        .listen((profile) {
          debugPrint(
            '[BottomNavAvatar] stream profile=${profile != null} '
            'uid="${profile?.uid ?? ''}" has_avatar=${profile?.hasProfileImage ?? false} '
            'url="${profile?.profileImage ?? ''}" '
            'display_ready=${_isDisplayReadyProfile(profile)}',
          );
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
    final current = widget.currentIndex;
    debugPrint(
      '[BottomNavAvatar] build uid="${_profile?.uid ?? ''}" '
      'source=${_profile?.hasProfileImage == true ? 'profile_url' : (_profile?.localProfileImagePath.isNotEmpty == true ? 'local_file' : 'initials')} '
      'url="${_profile?.profileImage ?? ''}"',
    );

    return Stack(
      children: [
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
            padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF23262C).withValues(alpha: 0.30),
                    borderRadius: BorderRadius.circular(999),
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
                  child: Row(
                    children: [
                      /// Shops
                      _NavItem(
                        isActive: current == 0,
                        onTap: () => widget.onTap(0),
                        label: 'Shops',
                        icon: Image.asset(
                          'assets/svg/coin_icon.png',
                          height: 24,
                          width: 24,
                          color: current == 0 ? _activeColor : _inactiveColor,
                          colorBlendMode: BlendMode.srcIn,
                        ),
                      ),

                      /// Chats
                      _NavItem(
                        isActive: current == 1,
                        onTap: () => widget.onTap(1),
                        label: 'Chats',
                        icon: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            SvgPicture.asset(
                              current == 1
                                  ? 'assets/svg/chat_filled.svg'
                                  : 'assets/svg/chat_icon.svg',
                              height: 24,
                              width: 24,
                              colorFilter: ColorFilter.mode(
                                current == 1 ? _activeColor : _inactiveColor,
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
                                        : widget.totalUnreadCount.toString(),
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

                      /// Posts
                      _NavItem(
                        isActive: current == 2,
                        onTap: () => widget.onTap(2),
                        label: 'Posts',
                        icon: Image.asset(
                          'assets/svg/posts_icon.png',
                          height: 24,
                          width: 24,
                          color: current == 2 ? _activeColor : _inactiveColor,
                          colorBlendMode: BlendMode.srcIn,
                        ),
                      ),

                      /// Calls
                      _NavItem(
                        isActive: current == 3,
                        onTap: () => widget.onTap(3),
                        label: 'Calls',
                        icon: Icon(
                          current == 3 ? Icons.call : Icons.call_outlined,
                          size: 24,
                          color: current == 3 ? _activeColor : _inactiveColor,
                        ),
                      ),

                      /// Profile
                      _NavItem(
                        isActive: current == 4,
                        onTap: () => widget.onTap(4),
                        label: 'Profile',
                        labelVerticalOffset: -2,
                        icon: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: 0.75,
                            ),
                          ),
                          child: ClipOval(
                            child: UserAvatar(
                              size: 26,
                              imageUrl: _profile?.hasProfileImage == true
                                  ? _profile!.profileImage
                                  : null,
                              localImagePath: _profile?.localProfileImagePath,
                              // Do not flash the owner's initials while the
                              // locally cached avatar is still hydrating.
                              // Once the profile arrives, the real avatar is
                              // rendered through imageUrl/localImagePath.
                              name: null,
                              cacheIdentity: _profile == null
                                  ? null
                                  : 'account:${_profile!.uid.trim().toLowerCase()}'
                                        '|avatar:v${_profile!.avatarVersion}',
                            ),
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
      ],
    );
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

/// One tab. Takes an equal share of the row width (Expanded).
/// The active pill is switcher_icon.svg, stretched behind the icon + label.
/// The content decides the pill's size; the SVG is then enlarged past that
/// area by the "bleed" values to cover any empty margin inside the SVG file.
class _NavItem extends StatelessWidget {
  // Content area the pill must cover.
  static const double _contentHorizontalMargin = 2;
  static const double _contentVerticalPadding = 6;

  // How far the SVG extends beyond the content area on each side.
  // Raise these until the visible pill covers the avatar and "Profile".
  static const double _svgBleedX = 7;
  static const double _svgBleedY = 15;

  final Widget icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final double labelVerticalOffset;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.labelVerticalOffset = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        selected: isActive,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Center(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(
                horizontal: _contentHorizontalMargin,
              ),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  if (isActive)
                    Positioned(
                      left: -_svgBleedX,
                      right: -_svgBleedX,
                      top: -_svgBleedY,
                      bottom: -_svgBleedY,
                      child: SvgPicture.asset(
                        'assets/images/switcher_icon.svg',
                        fit: BoxFit.fill,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: _contentVerticalPadding,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        icon,
                        const SizedBox(height: 2),
                        Transform.translate(
                          offset: Offset(0, labelVerticalOffset),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 10,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: isActive
                                  ? Colors.white
                                  : const Color(0xFF7A7A7A),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
