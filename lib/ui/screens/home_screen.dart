import 'package:flutter/material.dart';
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

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 1; // Default to Chats
  int _totalUnreadCount = 0;

  @override
  void initState() {
    super.initState();
    // Warm up the profile cache immediately so the bottom nav avatar
    // is ready on the very first frame — no visible delay.
    UserProfileService.instance.warmUp();
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
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
