import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/auth/auth_entry_screen.dart';
import 'package:wrytte/utils/country_phone_number.dart';

class EditProfileScreen extends StatefulWidget {
  final UserProfile? initialProfile;

  const EditProfileScreen({super.key, this.initialProfile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _linkController = TextEditingController();

  bool _isLoading = false;
  bool _isSaving = false;
  bool _isLoggingOut = false;

  File? _pickedImageFile;
  final ImagePicker _picker = ImagePicker();

  UserProfile? _profile;
  String? _currentImageUrl;
  String? _currentLocalImagePath;
  int _avatarCacheRevision = 0;

  @override
  void initState() {
    super.initState();
    _seedProfile(
      widget.initialProfile ?? UserProfileService.instance.cachedProfile,
    );
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    if (_profile == null) {
      setState(() => _isLoading = true);
    }
    final profile = await UserProfileService.instance.getCurrentUserProfile(
      forceRefresh: true,
    );
    if (!mounted) return;
    if (profile != null) {
      _applyProfile(profile);
    }
    setState(() {
      _profile = profile;
      _isLoading = false;
    });
  }

  void _seedProfile(UserProfile? profile) {
    if (profile == null) return;
    _applyProfile(profile);
    _profile = profile;
    _isLoading = false;
  }

  void _applyProfile(UserProfile profile) {
    final nameParts = profile.name.trim().split(RegExp(r'\s+'));
    _firstNameController.text = nameParts.isNotEmpty ? nameParts[0] : '';
    _lastNameController.text =
        nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
    _bioController.text = profile.bio;
    _linkController.text = profile.links.isNotEmpty ? profile.links[0] : '';
    _currentImageUrl = profile.hasProfileImage ? profile.profileImage : null;
    _currentLocalImagePath =
        profile.localProfileImagePath.trim().isNotEmpty
            ? profile.localProfileImagePath
            : null;
    if (_currentImageUrl != null) {
      _avatarCacheRevision = DateTime.now().millisecondsSinceEpoch;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 85);
      if (picked == null) return;
      setState(() => _pickedImageFile = File(picked.path));
    } catch (_) {
      _showSnack('Could not select photo.', isError: true);
    }
  }

  void _showImageOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF23262C),
      builder:
          (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo, color: Colors.white),
                  title: const Text(
                    'Gallery',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage(ImageSource.gallery);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt, color: Colors.white),
                  title: const Text(
                    'Camera',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage(ImageSource.camera);
                  },
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _save() async {
    if (_isSaving) return;
    final uid = await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.isEmpty) {
      _showSnack('Not authenticated.', isError: true);
      return;
    }
    setState(() => _isSaving = true);
    try {
      String? newImageUrl = _currentImageUrl;
      var avatarUploadPending = false;
      if (_pickedImageFile != null) {
        try {
          newImageUrl = await UserProfileService.instance.uploadProfileImage(
            _pickedImageFile!,
          );
        } catch (e) {
          avatarUploadPending = true;
          debugPrint('[EditProfile] Avatar upload queued: $e');
        }
      }
      final firstName = _firstNameController.text.trim();
      final lastName = _lastNameController.text.trim();
      final fullName = [
        firstName,
        lastName,
      ].where((s) => s.isNotEmpty).join(' ');
      final bio = _bioController.text.trim();
      final link = _linkController.text.trim();
      final existingLinks = List<String>.from(_profile?.links ?? []);
      if (link.isNotEmpty) {
        if (existingLinks.isEmpty) {
          existingLinks.add(link);
        } else {
          existingLinks[0] = link;
        }
      } else {
        if (existingLinks.isNotEmpty) existingLinks.removeAt(0);
      }
      await UserProfileService.instance.updateProfile(
        name: fullName,
        firstName: firstName,
        lastName: lastName,
        profileImage: newImageUrl,
        bio: bio,
        links: existingLinks,
      );
      final refreshedProfile = await UserProfileService.instance
          .getCurrentUserProfile(forceRefresh: true);
      final displayImageUrl =
          newImageUrl?.trim().isNotEmpty == true
              ? newImageUrl
              : refreshedProfile?.profileImage;
      if (!mounted) return;
      setState(() {
        _profile = refreshedProfile ?? _profile;
        _currentImageUrl =
            displayImageUrl?.trim().isNotEmpty == true ? displayImageUrl : null;
        _currentLocalImagePath =
            refreshedProfile?.localProfileImagePath.trim().isNotEmpty == true
                ? refreshedProfile!.localProfileImagePath
                : _currentLocalImagePath;
        if (_currentImageUrl != null) {
          _avatarCacheRevision = DateTime.now().millisecondsSinceEpoch;
        }
        if (_currentLocalImagePath != null) {
          _pickedImageFile = null;
        }
        _isSaving = false;
      });
      Navigator.pop(
        context,
        avatarUploadPending
            ? 'Profile saved. Photo will upload when internet is back.'
            : 'Profile updated successfully.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _showSnack(e.toString(), isError: true);
    }
  }

  // ===========================================================================
  //  LOGOUT
  // ===========================================================================
  Future<void> _logout() async {
    if (_isLoggingOut) return;
    setState(() => _isLoggingOut = true);

    try {
      await AuthService.instance.logout();
      UserProfileService.instance.clearCache();
    } catch (e) {
      debugPrint('[Logout] Auth logout error (skipping): $e');
      UserProfileService.instance.clearCache();
    }

    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthEntryScreen()),
        (route) => false,
      );
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor:
            isError ? const Color(0xFFE05252) : const Color(0xFF4DA3FF),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }

  Widget _divider() => const Divider(
    height: 1,
    thickness: 0.4,
    color: Color(0xFF3A3D44),
    indent: 16,
  );

  Widget _inputRow(
    String hint,
    TextEditingController ctrl, {
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: ctrl,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF6B6E75), fontSize: 16),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
    );
  }

  String? _cacheBustedAvatarUrl(String? url) {
    final raw = url?.trim() ?? '';
    if (raw.isEmpty) return null;
    if (_avatarCacheRevision <= 0) return raw;
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme) return raw;
    final params = Map<String, String>.from(uri.queryParameters);
    params['v'] = _avatarCacheRevision.toString();
    return uri.replace(queryParameters: params).toString();
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF08090B);
    const cardBg = Color(0xFF23262C);
    const accent = Color(0xFF4DA3FF);

    Widget avatarWidget =
        _pickedImageFile != null
            ? GestureDetector(
              onTap: _showImageOptions,
              child: ClipOval(
                child: Image.file(
                  _pickedImageFile!,
                  width: 100,
                  height: 100,
                  fit: BoxFit.cover,
                ),
              ),
            )
            : GestureDetector(
              onTap: _showImageOptions,
              child: UserAvatar(
                size: 100,
                imageUrl: _cacheBustedAvatarUrl(_currentImageUrl),
                localImagePath: _currentLocalImagePath,
                name: _profile?.displayName,
              ),
            );

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white, fontSize: 17),
              ),
            ),
            TextButton(
              onPressed: _isSaving ? null : _save,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child:
                  _isSaving
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                      : const Text(
                        'Save',
                        style: TextStyle(color: Colors.white, fontSize: 17),
                      ),
            ),
          ],
        ),
      ),
      body:
          _isLoading
              ? const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF4DA3FF),
                  strokeWidth: 2,
                ),
              )
              : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 20),
                      avatarWidget,
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: _showImageOptions,
                        child: const Text(
                          'Set new photo',
                          style: TextStyle(color: accent, fontSize: 16),
                        ),
                      ),
                      const SizedBox(height: 28),

                      // Name
                      Container(
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          children: [
                            _inputRow('First name', _firstNameController),
                            _divider(),
                            _inputRow('Last name', _lastNameController),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Bio
                      Container(
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(25),
                        ),
                        child: _inputRow('Bio', _bioController),
                      ),
                      const SizedBox(height: 12),

                      // Link
                      Container(
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(25),
                        ),
                        child: _inputRow('Link', _linkController),
                      ),
                      const SizedBox(height: 12),

                      // Account info
                      Container(
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  const Text(
                                    'Change number',
                                    style: TextStyle(
                                      color: Color(0xFF6B6E75),
                                      fontSize: 16,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    CountryPhoneNumber.formatInternationalDisplay(
                                      _profile?.phone ?? '',
                                    ),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.chevron_right,
                                    color: Color(0xFF6B6E75),
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                            _divider(),
                            InkWell(
                              onTap: () {},
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: const [
                                    Text(
                                      'Channel',
                                      style: TextStyle(
                                        color: Color(0xFF6B6E75),
                                        fontSize: 16,
                                      ),
                                    ),
                                    Spacer(),
                                    Text(
                                      'Add',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                      ),
                                    ),
                                    SizedBox(width: 4),
                                    Icon(
                                      Icons.chevron_right,
                                      color: Color(0xFF6B6E75),
                                      size: 20,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            _divider(),
                            InkWell(
                              onTap: () {},
                              borderRadius: const BorderRadius.only(
                                bottomLeft: Radius.circular(14),
                                bottomRight: Radius.circular(14),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: const [
                                    Text(
                                      'Group',
                                      style: TextStyle(
                                        color: Color(0xFF6B6E75),
                                        fontSize: 16,
                                      ),
                                    ),
                                    Spacer(),
                                    Text(
                                      'Add',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                      ),
                                    ),
                                    SizedBox(width: 4),
                                    Icon(
                                      Icons.chevron_right,
                                      color: Color(0xFF6B6E75),
                                      size: 20,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),

                      // ── LOG OUT BUTTON ────────────────────────────────────
                      GestureDetector(
                        onTap: _isLoggingOut ? null : _logout,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: Center(
                            child:
                                _isLoggingOut
                                    ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFFE05252),
                                      ),
                                    )
                                    : const Text(
                                      'Log out',
                                      style: TextStyle(
                                        color: Color(0xFFE05252),
                                        fontSize: 16,
                                      ),
                                    ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _bioController.dispose();
    _linkController.dispose();
    super.dispose();
  }
}
