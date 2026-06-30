import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/new_contact_screen.dart';
import 'package:wrytte/ui/widgets/full_screen_image_viewer.dart';
import 'package:wrytte/ui/widgets/full_screen_video_viewer.dart';
import 'package:wrytte/ui/widgets/profile_tab_bar_section.dart';
import 'package:wrytte/ui/widgets/wrytte_file_card.dart';
import 'package:wrytte/ui/widgets/wrytte_link_preview.dart';
import 'package:wrytte/ui/widgets/wrytte_persistent_image.dart';
import 'package:wrytte/ui/widgets/wrytte_video_thumbnail.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  /// When null — shows the current logged-in user's own profile.
  /// When provided — shows another user's profile (read-only).
  final String? uid;
  final String? fallbackName;
  final String? fallbackPhone;
  final String? fallbackAvatarUrl;
  final String? conversationId;

  const ProfileScreen({
    super.key,
    this.uid,
    this.fallbackName,
    this.fallbackPhone,
    this.fallbackAvatarUrl,
    this.conversationId,
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
  ContactIdentity? _identity;
  String? _matrixDisplayName;
  String? _matrixAvatarUrl;
  bool _profileLoading = true;
  List<ChatMessage> _conversationMessages = const [];
  StreamSubscription<UserProfile?>? _profileSub;

  late final TabController _tabController;

  bool get _isOtherUser =>
      widget.uid != null &&
      widget.uid != UserProfileService.instance.cachedProfile?.uid;

  List<String> get _tabs =>
      _isOtherUser ? ['Media', 'Files', 'Feed', 'Links'] : ['Posts', 'Saved'];

  bool get _hasImmediateProfileSeed {
    return false;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _seedProfileForFirstPaint();
    if (!_isOtherUser) {
      _profileSub = UserProfileService.instance
          .getCurrentUserProfileStream()
          .listen((profile) {
            if (!mounted || profile == null) return;
            setState(() {
              _profile = profile;
              _profileLoading = false;
            });
          });
    }
    _loadProfile();
    _loadConversationMessages();
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final uid = _validProfileUid(widget.uid);
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    var identity =
        uid != null && ownerUserId != null && ownerUserId.isNotEmpty
            ? await ContactIdentityCache.instance.findByMatrixId(
              ownerUserId: ownerUserId,
              matrixUserId: uid,
            )
            : null;
    final savedContact = uid != null ? await _findSavedContact(uid) : null;
    if (mounted && (identity != null || savedContact != null)) {
      setState(() {
        _identity = identity;
        _savedContact = savedContact;
        _profile ??= _profileFromLocalProfileData(uid: uid, identity: identity);
        _profileLoading = false;
      });
    }
    final fallbackPhone =
        identity?.phone ?? _phoneFromIdentifier(widget.fallbackPhone);
    final profile =
        uid != null
            ? await UserProfileService.instance.getProfileByUid(
              uid,
              phone: fallbackPhone,
              forceRefresh: true,
            )
            : await UserProfileService.instance.getCurrentUserProfile(
              forceRefresh: true,
            );

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _savedContact = savedContact;
      _identity = identity;
      _profileLoading = false;
    });

    final matrixProfile = uid != null ? await _loadMatrixProfile(uid) : null;

    if (uid != null && ownerUserId != null && ownerUserId.isNotEmpty) {
      if (savedContact == null) {
        await ContactIdentityCache.instance.clearSavedName(
          ownerUserId: ownerUserId,
          matrixUserId: uid,
        );
      } else if (profile != null) {
        final nextAvatar =
            profile.hasProfileImage ? profile.profileImage : matrixProfile?.$2;
        if (nextAvatar?.trim().isNotEmpty == true) {
          unawaited(
            AvatarPreloadService.replace(
              oldUrl: identity?.avatarUrl,
              newUrl: nextAvatar,
            ),
          );
        }
        final refreshedContact =
            await ContactLocalDb.refreshPublicProfileFields(
              ownerUserId: ownerUserId,
              wrytteUserId: uid,
              phone: profile.phone.isNotEmpty ? profile.phone : fallbackPhone,
              avatarUrl: nextAvatar,
              bio: profile.bio,
            );
        if (refreshedContact != null) {
          await ChatService().applySavedContact(refreshedContact);
        }
      }
      await ContactIdentityCache.instance.upsert(
        ownerUserId: ownerUserId,
        matrixUserId: uid,
        phone: profile?.phone ?? fallbackPhone,
        profileName:
            _cleanName(profile?.displayName).isNotEmpty
                ? profile?.displayName
                : _cleanName(matrixProfile?.$1).isNotEmpty
                ? matrixProfile?.$1
                : identity?.profileName,
        savedName: savedContact?.formattedName,
        avatarUrl:
            profile?.hasProfileImage == true
                ? profile!.profileImage
                : matrixProfile?.$2,
        bio:
            profile?.bio.trim().isNotEmpty == true
                ? profile!.bio
                : identity?.bio,
      );
      identity = await ContactIdentityCache.instance.findByMatrixId(
        ownerUserId: ownerUserId,
        matrixUserId: uid,
      );
    }

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _savedContact = savedContact;
      _identity = identity;
      _matrixDisplayName = matrixProfile?.$1;
      _matrixAvatarUrl = matrixProfile?.$2;
      _profileLoading = false;
    });
  }

  Future<void> _loadConversationMessages() async {
    final conversationId = widget.conversationId?.trim() ?? '';
    if (conversationId.isEmpty) return;
    final cached = ChatService().cachedMessagesFor(conversationId);
    if (mounted && cached.isNotEmpty) {
      setState(() => _conversationMessages = cached);
    }
    final local = await ChatLocalDb.instance.loadMessages(conversationId);
    if (!mounted) return;
    setState(() {
      _conversationMessages =
          local.where((message) => !message.isDeleted).toList()
            ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    });
  }

  void _seedProfileForFirstPaint() {
    if (_isOtherUser) {
      final phone =
          _phoneFromIdentifier(widget.fallbackPhone).isNotEmpty
              ? _formatPhone(_phoneFromIdentifier(widget.fallbackPhone))
              : '';
      final uid = _validProfileUid(widget.uid) ?? '';
      final cached = UserProfileService.instance.cachedPublicProfileByUid(
        uid,
        phone: phone,
      );
      if (cached != null && _hasRenderableProfile(cached)) {
        _profile = cached;
        _profileLoading = false;
        return;
      }
      return;
    }

    final cached = UserProfileService.instance.cachedProfile;
    if (cached == null || !_hasRenderableProfile(cached)) return;
    _profile = cached;
    _profileLoading = false;
  }

  bool _hasRenderableProfile(UserProfile profile) {
    return _cleanName(profile.displayName).isNotEmpty ||
        profile.phone.trim().isNotEmpty ||
        profile.hasProfileImage ||
        profile.localProfileImagePath.trim().isNotEmpty ||
        profile.bio.trim().isNotEmpty;
  }

  UserProfile? _profileFromLocalProfileData({
    required String? uid,
    ContactIdentity? identity,
  }) {
    final name = _cleanName(identity?.profileName);
    final phone = _phoneFromIdentifier(identity?.phone);
    final avatar = identity?.avatarUrl?.trim() ?? '';
    final bio = identity?.bio?.trim() ?? '';
    if (name.isEmpty && phone.isEmpty && avatar.isEmpty && bio.isEmpty) {
      return null;
    }
    return UserProfile(
      uid: uid ?? _validProfileUid(widget.uid) ?? '',
      name: name,
      username: name,
      phone: phone.isNotEmpty ? _formatPhone(phone) : '',
      bio: bio,
      profileImage: avatar,
      links: const [],
    );
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

  String? _validProfileUid(String? uid) {
    final trimmed = uid?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('!')) return null;
    if (trimmed.startsWith('@!')) return null;
    return trimmed;
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
    final stripped = value.trim().replaceAll(RegExp(r'[\s\-()+]'), '');
    if (stripped.length < 7 || stripped.length > 15) return false;
    return stripped.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(stripped);
  }

  String _extractPhone(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return '';
    final match = RegExp(r'(\+?\d[\d\s\-()]{6,}\d)').firstMatch(raw);
    if (match == null) return '';
    final phone = match.group(1)?.trim() ?? '';
    return _looksLikePhone(phone) ? phone : '';
  }

  String _phoneFromIdentifier(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty || _looksLikeMatrixId(raw)) return '';

    final extracted = _extractPhone(value);
    if (extracted.isNotEmpty) return extracted;

    final localpart = _matrixLocalpart(raw);
    if (_looksLikeMatrixId(localpart)) return '';
    final digits = localpart.replaceAll(RegExp(r'[^\d]'), '');
    return RegExp(r'^\+?\d{7,15}$').hasMatch(localpart) ? digits : '';
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
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return '';
    }
    if (_looksLikePhone(trimmed) || _looksLikeMatrixId(trimmed)) return '';
    return trimmed;
  }

  String _profileDisplayName() {
    final savedName = _cleanName(_savedContact?.formattedName);
    if (savedName.isNotEmpty) return savedName;

    final savedIdentityName = _cleanName(_identity?.savedName);
    if (savedIdentityName.isNotEmpty) return savedIdentityName;

    return _cleanName(_profile?.displayName).isNotEmpty
        ? _cleanName(_profile?.displayName)
        : _cleanName(_identity?.profileName).isNotEmpty
        ? _cleanName(_identity?.profileName)
        : _cleanName(_matrixDisplayName).isNotEmpty
        ? _cleanName(_matrixDisplayName)
        : '';
  }

  String _profilePhone() {
    final candidates = [
      _savedContact?.primaryPhone,
      _profile?.phone,
      _identity?.phone,
    ];
    for (final value in candidates) {
      final phone = _phoneFromIdentifier(value);
      if (phone.isNotEmpty) {
        return _formatPhone(phone);
      }
    }
    return '';
  }

  String _formatPhone(String phone) {
    final digits = _stripInvalidNorthAmericaPrefix(
      phone.replaceAll(RegExp(r'[^\d+]'), ''),
    );
    final digitsOnly = digits.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.length < 7 || digitsOnly.length > 15) return '';
    if (digits.startsWith('+256') && digits.length == 13) {
      return '${digits.substring(0, 4)} ${digits.substring(4, 7)} ${digits.substring(7, 10)} ${digits.substring(10)}';
    }
    if (digits.startsWith('+1') && digits.length == 12) {
      return '${digits.substring(0, 2)} ${digits.substring(2, 5)} ${digits.substring(5, 8)} ${digits.substring(8)}';
    }
    if (digits.isNotEmpty && !digits.startsWith('+')) return '+$digits';
    return digits;
  }

  String _stripInvalidNorthAmericaPrefix(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (!phone.startsWith('+1')) return phone;
    if (digits.length <= 11) return phone;
    return '+${digits.substring(1)}';
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
              initialName: _profileDisplayName(),
              initialBio: _profileBio(),
            ),
      ),
    );
    if (mounted) _loadProfile();
  }

  Future<void> _deleteSavedContact() async {
    final contact = _savedContact;
    final ownerUserId = await AuthService.instance.getCurrentUserId();
    final uid = _validProfileUid(widget.uid);
    if (contact == null ||
        ownerUserId == null ||
        ownerUserId.isEmpty ||
        uid == null) {
      return;
    }

    await ContactLocalDb.removeContact(contact, ownerUserId: ownerUserId);
    unawaited(
      ContactService()
          .removeContactFromBackend(ownerUserId: ownerUserId, contact: contact)
          .catchError(
            (e) =>
                debugPrint('[ProfileScreen] backend contact remove failed: $e'),
          ),
    );
    await ContactIdentityCache.instance.clearSavedName(
      ownerUserId: ownerUserId,
      matrixUserId: uid,
    );
    await ChatService().applyUnsavedContact(contact);
    ContactService.invalidateMatrixContactsCache();
    ContactService().invalidateCache();

    final identity = await ContactIdentityCache.instance.findByMatrixId(
      ownerUserId: ownerUserId,
      matrixUserId: uid,
    );
    if (!mounted) return;
    setState(() {
      _savedContact = null;
      _identity = identity;
    });
  }

  Future<void> _showMoreActions() async {
    final isSaved = _savedContact != null;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1F25),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSaved)
                  ListTile(
                    leading: const Icon(
                      Icons.person_remove_outlined,
                      color: Color(0xFFFF6B6B),
                    ),
                    title: const Text(
                      'Delete contact',
                      style: TextStyle(color: Color(0xFFFF6B6B)),
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      await _deleteSavedContact();
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.close, color: Colors.white70),
                  title: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
    );
  }

  static const TextStyle _bioStyle = TextStyle(
    color: Colors.white,
    fontSize: 14,
    height: 1.4,
  );

  bool get _hasCard {
    final bio = _profileBio();
    final links = _profile?.links ?? [];
    return bio.isNotEmpty || links.isNotEmpty;
  }

  String _profileBio() {
    final profileBio = _profile?.bio.trim() ?? '';
    if (profileBio.isNotEmpty) return profileBio;
    return _identity?.bio?.trim() ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double topBarHeight = statusBarHeight + kToolbarHeight;

    final hasProfile =
        _profile != null ||
        _identity != null ||
        _cleanName(_matrixDisplayName).isNotEmpty ||
        _hasImmediateProfileSeed;
    final String displayName =
        _profileLoading && !hasProfile ? '' : _profileDisplayName();
    final String phone = _profileLoading && !hasProfile ? '' : _profilePhone();
    final String bioText = _profileBio();
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
                        _profileLoading && !hasProfile
                            ? _buildAvatarShimmer(100)
                            : UserAvatar(
                              size: 100,
                              imageUrl:
                                  _profile?.hasProfileImage == true
                                      ? _profile!.profileImage
                                      : (_identity?.avatarUrl ??
                                          _matrixAvatarUrl),
                              localImagePath: _profile?.localProfileImagePath,
                              name: displayName,
                            ),

                        const SizedBox(height: 12),

                        // ── Name ────────────────────────────────────────────
                        if (displayName.isNotEmpty)
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

                        if (!_profileLoading && bioText.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF23262C),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: _buildBio(bioText),
                            ),
                          ),
                        ],

                        const SizedBox(height: 16),

                        // ── Quick actions (other user only) ─────────────────
                        if (_isOtherUser) ...[
                          _buildQuickActions(),
                          const SizedBox(height: 20),
                        ],

                        // ── Links card (only when content exists) ───────────
                        if (!_profileLoading && links.isNotEmpty) ...[
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
                                children: [_buildLinks(links)],
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
                        _buildMediaTab(),
                        _buildFilesTab(),
                        _buildEmptyTab(Icons.dynamic_feed_outlined, 'No feed'),
                        _buildLinksTab(),
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
                      const Color(0xFF08090B).withValues(alpha: 0.95),
                      const Color(0xFF08090B).withValues(alpha: 0.75),
                      const Color(0xFF08090B).withValues(alpha: 0.0),
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
                          ? _glassButton(
                            icon: Icons.more_vert,
                            onTap: _showMoreActions,
                          )
                          : _glassTextButton(
                            text: "Edit",
                            onTap: () async {
                              final message = await Navigator.push<String>(
                                context,
                                MaterialPageRoute(
                                  builder:
                                      (_) => EditProfileScreen(
                                        initialProfile: _profile,
                                      ),
                                ),
                              );
                              if (!context.mounted) return;
                              unawaited(_loadProfile());
                              if (message?.trim().isNotEmpty == true) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(message!),
                                    backgroundColor: const Color(0xFF4DA3FF),
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                  ),
                                );
                              }
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
                color: Colors.white.withValues(alpha: 0.75),
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
                Icon(
                  icon,
                  size: 52,
                  color: Colors.white.withValues(alpha: 0.15),
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
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

  Widget _buildMediaTab() {
    final items =
        _conversationMessages
            .where(
              (message) =>
                  message.attachmentType == 'image' ||
                  message.attachmentType == 'video',
            )
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (items.isEmpty) {
      return _buildEmptyTab(Icons.photo_library_outlined, 'No media');
    }
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(14),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildMediaTile(items[index]),
              childCount: items.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilesTab() {
    final items =
        _conversationMessages
            .where((message) => message.attachmentType == 'file')
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (items.isEmpty) {
      return _buildEmptyTab(Icons.insert_drive_file_outlined, 'No files');
    }
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: WrytteFileCard(
                source: item.attachmentUrl ?? '',
                fileName: item.content.trim().isEmpty ? 'File' : item.content,
                profileStyle: true,
                trailing: Text(
                  _formatProfileMessageDate(item.timestamp),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 11,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildLinksTab() {
    final links =
        _conversationMessages
            .map(
              (message) => (
                link: _firstLinkIn(message.content),
                timestamp: message.timestamp,
              ),
            )
            .where((item) => item.link != null)
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (links.isEmpty) return _buildEmptyTab(Icons.link_outlined, 'No links');
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverList.builder(
          itemCount: links.length,
          itemBuilder: (context, index) {
            final item = links[index];
            final section = _linkSectionLabel(item.timestamp);
            final showSection =
                index == 0 ||
                _linkSectionLabel(links[index - 1].timestamp) != section;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSection)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 5),
                    child: Text(
                      section,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
                  child: WrytteLinkPreview(
                    url: item.link!,
                    showOriginalUrl: true,
                    compact: true,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  String _linkSectionLabel(DateTime timestamp) {
    final now = DateTime.now();
    final age = now.difference(timestamp);
    if (age.inDays < 7) return 'RECENT';
    if (age.inDays < 60) return 'LAST MONTH';
    const months = [
      'JANUARY',
      'FEBRUARY',
      'MARCH',
      'APRIL',
      'MAY',
      'JUNE',
      'JULY',
      'AUGUST',
      'SEPTEMBER',
      'OCTOBER',
      'NOVEMBER',
      'DECEMBER',
    ];
    return months[timestamp.month - 1];
  }

  Widget _buildMediaTile(ChatMessage message) {
    final url = message.attachmentUrl?.trim() ?? '';
    if (message.attachmentType == 'video') {
      return GestureDetector(
        onTap: () => FullScreenVideoViewer.open(context, url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              WrytteVideoThumbnail(source: url),
              IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.18),
                  child: const Center(
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final child = WryttePersistentImage(source: url, fit: BoxFit.cover);
    return GestureDetector(
      onTap: () => FullScreenImageViewer.open(context, url),
      child: ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
    );
  }

  String _formatProfileMessageDate(DateTime value) {
    final now = DateTime.now();
    if (now.year == value.year &&
        now.month == value.month &&
        now.day == value.day) {
      return 'Today';
    }
    return '${value.day}/${value.month}/${value.year}';
  }

  String? _firstLinkIn(String value) {
    final match = RegExp(r'https?://[^\s]+').firstMatch(value);
    return match?.group(0);
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
            color: const Color(0xFF23262C).withValues(alpha: 0.30),
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
            color: const Color(0xFF23262C).withValues(alpha: 0.30),
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
