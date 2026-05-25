import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';
import 'package:wrytte/ui/widgets/profile_tab_bar_section.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  /// When null — shows the current logged-in user's own profile.
  /// When provided — shows another user's profile (read-only).
  final String? uid;
  final String? fallbackName;
  final String? fallbackPhone;
  final String? fallbackAvatarUrl;

  const ProfileScreen({
    super.key,
    this.uid,
    this.fallbackName,
    this.fallbackPhone,
    this.fallbackAvatarUrl,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  bool _bioExpanded = false;
  bool _linksExpanded = false;

  UserProfile? _profile;
  Contact? _savedContact;
  String? _matrixDisplayName;
  String? _matrixAvatarUrl;
  bool _profileLoading = true;

  late final TabController _tabController;

  bool get _isOtherUser =>
      widget.uid != null &&
      widget.uid != UserProfileService.instance.cachedProfile?.uid;

  List<String> get _tabs =>
      _isOtherUser ? ['Media', 'Files', 'Feed', 'Links'] : ['Posts', 'Saved'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _loadProfile();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final profile =
        widget.uid != null
            ? await UserProfileService.instance.getProfileByUid(widget.uid!)
            : await UserProfileService.instance.getCurrentUserProfile();
    final savedContact =
        widget.uid != null ? await _findSavedContact(widget.uid!) : null;
    final matrixProfile =
        widget.uid != null ? await _loadMatrixProfile(widget.uid!) : null;

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _savedContact = savedContact;
      _matrixDisplayName = matrixProfile?.$1;
      _matrixAvatarUrl = matrixProfile?.$2;
      _profileLoading = false;
    });
  }

  Future<Contact?> _findSavedContact(String uid) async {
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    if (ownerUserId == null || ownerUserId.isEmpty) return null;

    final targetLocalpart = _matrixLocalpart(uid);
    final contacts = await ContactService().getMatrixContactsCached(
      ownerUserId,
    );
    for (final contact in contacts) {
      final contactId = contact.wrytteUserId;
      if (contactId == null || contactId.isEmpty) continue;
      if (_matrixLocalpart(contactId) == targetLocalpart) return contact;
    }
    return null;
  }

  Future<(String?, String?)?> _loadMatrixProfile(String uid) async {
    try {
      if (!MatrixClientService.instance.isLoggedIn) return null;
      final matrixUserId = _toMatrixUserId(uid);
      final profile = await MatrixClientService.instance.client
          .getProfileFromUserId(
            matrixUserId,
            timeout: const Duration(seconds: 5),
          );
      return (profile.displayName, profile.avatarUrl?.toString());
    } catch (_) {
      return null;
    }
  }

  String _toMatrixUserId(String uid) {
    final trimmed = uid.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    return '@${_matrixLocalpart(trimmed)}:${MatrixConfig.serverName}';
  }

  String _matrixLocalpart(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  bool _looksLikePhone(String value) {
    final stripped = value.trim().replaceAll(RegExp(r'[\s\-()]'), '');
    return stripped.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(stripped);
  }

  bool _looksLikeMatrixId(String value) {
    final trimmed = value.trim();
    final localpart = _matrixLocalpart(trimmed);
    final looksLikeGeneratedUid = RegExp(
      r'^[a-f0-9]{24,}$',
      caseSensitive: false,
    ).hasMatch(localpart);
    return trimmed.startsWith('@') ||
        trimmed.contains(':matrix.') ||
        looksLikeGeneratedUid;
  }

  String _cleanName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    if (_looksLikePhone(trimmed) || _looksLikeMatrixId(trimmed)) return '';
    return trimmed;
  }

  String _profileDisplayName() {
    return _cleanName(_savedContact?.formattedName).isNotEmpty
        ? _cleanName(_savedContact?.formattedName)
        : _cleanName(_profile?.displayName).isNotEmpty
        ? _cleanName(_profile?.displayName)
        : _cleanName(_matrixDisplayName).isNotEmpty
        ? _cleanName(_matrixDisplayName)
        : _cleanName(widget.fallbackName).isNotEmpty
        ? _cleanName(widget.fallbackName)
        : 'User';
  }

  String _profilePhone() {
    final candidates = [
      _profile?.phone,
      _savedContact?.primaryPhone,
      widget.fallbackPhone,
      widget.fallbackName,
    ];
    for (final value in candidates) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isNotEmpty && _looksLikePhone(trimmed)) {
        return _formatPhone(trimmed);
      }
    }
    return '';
  }

  String _formatPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.startsWith('+256') && digits.length == 13) {
      return '${digits.substring(0, 4)} ${digits.substring(4, 7)} ${digits.substring(7, 10)} ${digits.substring(10)}';
    }
    if (digits.startsWith('+1') && digits.length == 12) {
      return '${digits.substring(0, 2)} ${digits.substring(2, 5)} ${digits.substring(5, 8)} ${digits.substring(8)}';
    }
    return phone;
  }

  Future<void> _launchLink(String url) async {
    final raw = url.trim();
    final uri = Uri.parse(
      raw.startsWith('http://') || raw.startsWith('https://')
          ? raw
          : 'https://$raw',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open $raw'),
          backgroundColor: const Color(0xFF23262C),
        ),
      );
    }
  }

  Future<void> _openAddContact() async {
    if (widget.uid == null) return;
    final phone = _profilePhone();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => NewContactPage(
              token: '',
              initialIdentifier: phone.isNotEmpty ? phone : widget.uid,
              initialWrytteUserId: _toMatrixUserId(widget.uid!),
            ),
      ),
    );
    if (mounted) _loadProfile();
  }

  static const TextStyle _bioStyle = TextStyle(
    color: Colors.white,
    fontSize: 14,
    height: 1.4,
  );

  bool get _hasCard {
    final bio = _profile?.bio ?? '';
    final links = _profile?.links ?? [];
    return bio.isNotEmpty || links.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double topBarHeight = statusBarHeight + kToolbarHeight;

    final String displayName = _profileLoading ? '...' : _profileDisplayName();
    final String phone = _profileLoading ? '' : _profilePhone();
    final String bioText = _profile?.bio ?? '';
    final List<String> links = _profile?.links ?? [];

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          NestedScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            headerSliverBuilder:
                (context, innerBoxIsScrolled) => [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        SizedBox(height: topBarHeight + 20),

                        // ── Avatar ──────────────────────────────────────────
                        _profileLoading
                            ? _buildAvatarShimmer(100)
                            : UserAvatar(
                              size: 100,
                              imageUrl:
                                  _profile?.hasProfileImage == true
                                      ? _profile!.profileImage
                                      : (_matrixAvatarUrl ??
                                          widget.fallbackAvatarUrl),
                              name: displayName,
                            ),

                        const SizedBox(height: 12),

                        // ── Name ────────────────────────────────────────────
                        Text(
                          displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),

                        const SizedBox(height: 4),

                        // ── Phone ───────────────────────────────────────────
                        if (phone.isNotEmpty)
                          Text(
                            phone,
                            style: const TextStyle(
                              color: Color(0xFF4DA3FF),
                              fontSize: 16,
                            ),
                          ),

                        const SizedBox(height: 16),

                        // ── Quick actions (other user only) ─────────────────
                        if (_isOtherUser) ...[
                          _buildQuickActions(),
                          const SizedBox(height: 20),
                        ],

                        // ── Bio + links card (only when content exists) ─────
                        if (!_profileLoading && _hasCard) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFF23262C),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (bioText.isNotEmpty) _buildBio(bioText),
                                  if (links.isNotEmpty) ...[
                                    if (bioText.isNotEmpty)
                                      const SizedBox(height: 10),
                                    _buildLinks(links),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],

                        if (_profileLoading || !_hasCard)
                          const SizedBox(height: 4),
                      ],
                    ),
                  ),

                  // ── Sticky tab bar — pins just below the top app bar ──────
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _StickyTabBarDelegate(
                      topOffset: topBarHeight,
                      child: Container(
                        color: const Color(0xFF08090B),
                        child: ProfileTabBarSection(
                          controller: _tabController,
                          tabs: _tabs,
                        ),
                      ),
                    ),
                  ),
                ],
            body: TabBarView(
              controller: _tabController,
              physics: const BouncingScrollPhysics(),
              children:
                  _isOtherUser
                      ? [
                        _buildEmptyTab(
                          Icons.photo_library_outlined,
                          'No media',
                        ),
                        _buildEmptyTab(
                          Icons.insert_drive_file_outlined,
                          'No files',
                        ),
                        _buildEmptyTab(Icons.dynamic_feed_outlined, 'No feed'),
                        _buildEmptyTab(Icons.link_outlined, 'No links'),
                      ]
                      : [_buildPostsTab(), _buildSavedTab()],
            ),
          ),

          // ── Top gradient scrim ────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topBarHeight + 20,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.6, 1.0],
                    colors: [
                      const Color(0xFF08090B).withOpacity(0.95),
                      const Color(0xFF08090B).withOpacity(0.75),
                      const Color(0xFF08090B).withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Top bar ───────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Padding(
              padding: EdgeInsets.only(top: statusBarHeight),
              child: SizedBox(
                height: kToolbarHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      // ── Back button ──────────────────────────────────
                      _glassButton(
                        icon: Icons.arrow_back_ios,
                        onTap: () => Navigator.pop(context),
                      ),

                      // ── Title — only shown for own profile, truly centered ─
                      Expanded(
                        child:
                            _isOtherUser
                                ? const SizedBox.shrink()
                                : const Center(
                                  child: Text(
                                    "Profile",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                      ),

                      // ── Edit / action button ─────────────────────────
                      _isOtherUser
                          ? _glassButton(icon: Icons.more_vert, onTap: () {})
                          : _glassTextButton(
                            text: "Edit",
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const EditProfileScreen(),
                                ),
                              );
                            },
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Quick actions — solid background, no glass ────────────────────────────
  // CHANGE 3: Solid 0xFF23262C, no blur/opacity

  Widget _buildQuickActions() {
    final showAddContact = _savedContact == null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: _actionPill(Icons.call_outlined, 'Calls', onTap: () {}),
          ),
          const SizedBox(width: 10),
          if (showAddContact) ...[
            Expanded(
              child: _actionPill(
                Icons.person_add_alt_1_outlined,
                'Add',
                onTap: _openAddContact,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: _actionPill(Icons.videocam_outlined, 'Video', onTap: () {}),
          ),
          const SizedBox(width: 10),
          Expanded(child: _actionPill(Icons.search, 'Search', onTap: () {})),
          const SizedBox(width: 10),
          Expanded(child: _actionPill(Icons.more_horiz, 'More', onTap: () {})),
        ],
      ),
    );
  }

  Widget _actionPill(IconData icon, String label, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          // CHANGE 3: Solid color, no transparency, no BackdropFilter
          color: const Color(0xFF23262C),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF23262C), width: 1.0),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.75),
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Own profile tab content ────────────────────────────────────────────────

  Widget _buildPostsTab() {
    return ListView(
      padding: const EdgeInsets.only(top: 40, bottom: 120),
      // CHANGE 4: Bouncing physics so empty tabs have iOS-style spring bounce
      // without scrolling the header content away
      physics: const BouncingScrollPhysics(),
      children: [
        const Text(
          "Publish photo and video to\ndisplay on your profile page",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 120),
          child: ElevatedButton(
            onPressed: () {},
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4DA3FF),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              "Add storie",
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSavedTab() {
    // CHANGE 4: Wrap in a scrollable with bouncing physics so it feels iOS-native
    // but won't fully scroll the header away when there's no data
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: const Center(
            child: Text(
              "No saved posts yet",
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
      ],
    );
  }

  // ── Other user empty tab states ────────────────────────────────────────────
  // CHANGE 4: Each empty tab is a CustomScrollView with SliverFillRemaining
  // so it fills the space without allowing full header scroll-away,
  // but retains the iOS bounce animation on over-scroll.

  Widget _buildEmptyTab(IconData icon, String label) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 52, color: Colors.white.withOpacity(0.15)),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.35),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Avatar shimmer ─────────────────────────────────────────────────────────

  Widget _buildAvatarShimmer(double size) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF2A2D34),
      ),
    );
  }

  // ── Bio ────────────────────────────────────────────────────────────────────

  Widget _buildBio(String bioText) {
    if (_bioExpanded) {
      return GestureDetector(
        onTap: () => setState(() => _bioExpanded = false),
        child: Text(bioText, style: _bioStyle),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final fullPainter = TextPainter(
          text: TextSpan(text: bioText, style: _bioStyle),
          maxLines: 3,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        if (!fullPainter.didExceedMaxLines) {
          return Text(bioText, style: _bioStyle);
        }

        int lo = 0, hi = bioText.length;
        while (lo < hi) {
          final mid = (lo + hi + 1) ~/ 2;
          final candidate = '${bioText.substring(0, mid).trimRight()}... more';
          final p = TextPainter(
            text: TextSpan(text: candidate, style: _bioStyle),
            maxLines: 3,
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: constraints.maxWidth);
          if (p.didExceedMaxLines) {
            hi = mid - 1;
          } else {
            lo = mid;
          }
        }

        final visibleText = bioText.substring(0, lo).trimRight();

        return GestureDetector(
          onTap: () => setState(() => _bioExpanded = true),
          child: Text.rich(
            TextSpan(
              style: _bioStyle,
              children: [
                TextSpan(text: visibleText),
                const TextSpan(
                  text: '... ',
                  style: TextStyle(color: Colors.white),
                ),
                const TextSpan(
                  text: 'read more',
                  style: TextStyle(color: Color(0xFF4DA3FF)),
                ),
              ],
            ),
            maxLines: 3,
          ),
        );
      },
    );
  }

  // ── Links ──────────────────────────────────────────────────────────────────

  Widget _buildLinks(List<String> links) {
    final firstLink = links[0];
    final hasMore = links.length > 1;
    final remainingCount = links.length - 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => _launchLink(firstLink),
          child: Row(
            children: [
              const Icon(Icons.link, color: Color(0xFF4DA3FF), size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  firstLink,
                  style: const TextStyle(
                    color: Color(0xFF4DA3FF),
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              if (hasMore && !_linksExpanded) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => setState(() => _linksExpanded = true),
                  child: Text(
                    '$remainingCount more',
                    style: const TextStyle(
                      color: Color(0xFF4DA3FF),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_linksExpanded)
          ...links
              .skip(1)
              .map(
                (link) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: GestureDetector(
                    onTap: () => _launchLink(link),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.link,
                          color: Color(0xFF4DA3FF),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            link,
                            style: const TextStyle(
                              color: Color(0xFF4DA3FF),
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ],
    );
  }

  // ── Glass helpers ──────────────────────────────────────────────────────────

  Widget _glassButton({required IconData icon, required VoidCallback onTap}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withOpacity(0.30),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF23262C)),
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 16),
            onPressed: onTap,
          ),
        ),
      ),
    );
  }

  Widget _glassTextButton({required String text, required VoidCallback onTap}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF23262C).withOpacity(0.30),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF23262C)),
          ),
          child: GestureDetector(
            onTap: onTap,
            child: Center(
              child: Text(
                text,
                // CHANGE 1: Always white, for both own and other user
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sticky tab bar delegate ────────────────────────────────────────────────────
// CHANGE 5: topOffset is accepted but the delegate pins at its natural sliver
// position (just after the header slivers), which means the tab bar sticks
// right below where the header ends — and stays there on scroll.

class _StickyTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  // topOffset kept for reference / future use but pinning is handled by
  // SliverPersistentHeader(pinned: true) in the NestedScrollView header.
  final double topOffset;

  const _StickyTabBarDelegate({required this.child, this.topOffset = 0});

  static const double _height = 56.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  bool shouldRebuild(_StickyTabBarDelegate old) =>
      old.child != child || old.topOffset != topOffset;
}
