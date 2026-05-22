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

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.totalUnreadCount,
    this.userAvatar,
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

    // Subscribe to profile changes; the service validates that cached data
    // belongs to the currently signed-in account before emitting it.
    _profileSub = UserProfileService.instance
        .getCurrentUserProfileStream()
        .listen((profile) {
          if (mounted && profile != null) {
            setState(() => _profile = profile);
          }
        });
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
                  const Color(0xFF0F1013).withOpacity(0.0),
                  const Color(0xFF0F1013).withOpacity(0.80),
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
                    color: const Color(0xFF23262C).withOpacity(0.30),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: const Color(0xFF23262C),
                      width: 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
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
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      unselectedLabelStyle: const TextStyle(
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
                                  color:
                                      widget.currentIndex == 1
                                          ? Colors.white
                                          : const Color(0xFF7A7A7A),
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
                              name: _profile?.displayName,
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

  String _profileTabLabel() {
    final name = _profile?.displayName.trim() ?? '';
    if (name.isEmpty) return 'You';
    final firstName = name.split(RegExp(r'\s+')).first;
    if (firstName.length <= 10) return firstName;
    return '${firstName.substring(0, 10)}...';
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
          color: Colors.white.withOpacity(0.12),
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
