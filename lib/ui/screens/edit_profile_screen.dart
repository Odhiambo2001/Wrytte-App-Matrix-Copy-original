import 'dart:io';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/face/biometric_prewarm_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/auth/welcome_view.dart';
import 'package:wrytte/ui/screens/profile_room_picker_screen.dart';
import 'package:wrytte/domain/models/attachment_gallery_config.dart';
import 'package:wrytte/domain/models/attachment_gallery_result.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:wrytte/data/repositories/camera_repository_impl.dart';
import 'package:wrytte/data/repositories/media_library_repository_impl.dart';
import 'package:wrytte/data/services/camera_capabilities_service.dart';
import 'package:wrytte/data/services/camera_session_manager.dart';
import 'package:wrytte/data/services/device_camera_service.dart';
import 'package:wrytte/data/services/device_media_library_service.dart';
import 'package:wrytte/ui/camera/views/wrytte_camera_route.dart';
import 'package:wrytte/ui/camera/widgets/attachment_camera_preview.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/media/views/attachment_gallery_sheet.dart';
import 'package:wrytte/ui/media/views/profile_photo_crop_view.dart';
import 'package:wrytte/ui/media/views/full_screen_image_view.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'package:wrytte/utils/country_phone_number.dart';
import 'package:wrytte/utils/wrytte_id.dart';

class EditProfileScreen extends StatefulWidget {
  final UserProfile? initialProfile;

  const EditProfileScreen({super.key, this.initialProfile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _profilePhotoKey = GlobalKey();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _linkController = TextEditingController();
  final TextEditingController _channelAliasController = TextEditingController();
  final TextEditingController _groupAliasController = TextEditingController();

  bool _isLoading = false;
  bool _isSaving = false;
  bool _isLoggingOut = false;
  bool _showDiscardConfirmation = false;

  String _originalName = '';
  String _originalBio = '';
  String _originalLink = '';
  String _originalChannel = '';
  String _originalGroup = '';
  String? _originalImageUrl;
  String? _originalLocalImagePath;

  bool get _hasName => _nameController.text.trim().isNotEmpty;

  File? _pickedImageFile;
  final _fullScreenCameraOpen = ValueNotifier<bool>(false);

  UserProfile? _profile;
  String? _currentImageUrl;
  String? _currentLocalImagePath;
  int _avatarCacheRevision = 0;

  // ── Card style: outlines only ─────────────────────────────────────────────
  static const Color _bg = Color(0xFF08090B);
  static const Color _cardBg = Color(0x00000000); // transparent
  static const Color _cardBorder = Color(0xFF23262C);
  static const Color _accent = Color(0xFF249FF0);
  static const Color _hint = Color(0xFF6B6E75);
  static const Color _muted = Color(0xFFB9BBC1);
  static const Color _discardRed = Color(0xFFFF5C52);

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
    final display = profile.displayName.trim().isNotEmpty
        ? profile.displayName.trim()
        : profile.name.trim();
    _nameController.text = display;
    _bioController.text = profile.bio;
    _linkController.text = profile.links.isNotEmpty ? profile.links[0] : '';
    _channelAliasController.text = profile.channelAlias;
    _groupAliasController.text = profile.groupAlias;
    _currentImageUrl = profile.hasProfileImage ? profile.profileImage : null;
    _currentLocalImagePath =
        profile.localProfileImagePath.trim().isNotEmpty
            ? profile.localProfileImagePath
            : null;
    if (_currentImageUrl != null) {
      _avatarCacheRevision = DateTime.now().millisecondsSinceEpoch;
    }
    _originalName = _nameController.text;
    _originalBio = _bioController.text;
    _originalLink = _linkController.text;
    _originalChannel = _channelAliasController.text;
    _originalGroup = _groupAliasController.text;
    _originalImageUrl = _currentImageUrl;
    _originalLocalImagePath = _currentLocalImagePath;
  }

  bool get _hasUnsavedChanges {
    return _nameController.text != _originalName ||
        _bioController.text != _originalBio ||
        _linkController.text != _originalLink ||
        _channelAliasController.text != _originalChannel ||
        _groupAliasController.text != _originalGroup ||
        _pickedImageFile != null ||
        _currentImageUrl != _originalImageUrl ||
        _currentLocalImagePath != _originalLocalImagePath;
  }

  String _formatProfileNumber(String value, {String accountId = ''}) {
    final number = value.trim();
    if (number.isEmpty) return '';
    final wrytteId = WrytteId.forDisplay(number);
    if (wrytteId != null) return wrytteId;

    final accountWrytteId = WrytteId.forDisplay(accountId);
    final accountIdDigits = accountWrytteId
        ?.replaceAll(RegExp(r'[^0-9]'), '')
        .replaceFirst(RegExp(r'^00'), '');
    final numberDigits = number.replaceAll(RegExp(r'[^0-9]'), '');
    if (accountWrytteId != null && numberDigits == accountIdDigits) {
      return accountWrytteId;
    }

    return CountryPhoneNumber.formatInternationalDisplay(number);
  }

  String _formattedAccountNumber() {
    final profile = _profile;
    if (profile == null) return '';
    return _formatProfileNumber(profile.phone, accountId: profile.uid);
  }

  Future<void> _chooseProfilePhoto() async {
    // EditProfileScreen is also opened from routes that do not carry the
    // signup providers. Create the same repositories used by profile setup.
    final media = MediaLibraryRepositoryImpl(DeviceMediaLibraryService());
    final camera = CameraRepositoryImpl(
      DeviceCameraService(),
      const CameraCapabilitiesService(),
      CameraSessionManager(),
    );
    const cameraConfig = CameraSessionConfig.profilePhoto();
    final future = showWrytteAttachmentGallery(
      context,
      config: const AttachmentGalleryConfig.profilePhoto(),
      repository: media,
      cameraPreviewBuilder: (_) => AttachmentCameraPreview(
        repository: camera,
        fullScreenCameraOpen: _fullScreenCameraOpen,
      ),
      onMediaRequested: (asset, origin) async {
        final path = await media.loadFilePath(asset.id);
        if (!mounted || path == null) return null;
        final cropped = await showWrytteProfilePhotoCrop(
          context,
          sourcePath: path,
          sourcePixelSize: Size(asset.width.toDouble(), asset.height.toDouble()),
          origin: origin,
        );
        return cropped == null ? null : AttachmentGalleryResult.prepared(cropped);
      },
      onCameraRequested: (origin, _) async {
        if (!mounted) return null;
        _fullScreenCameraOpen.value = true;
        try {
          return await showWrytteCamera(
            context,
            repository: camera,
            config: cameraConfig,
            origin: origin,
            returnToGallery: true,
            keepSessionAliveOnExit: true,
          );
        } finally {
          _fullScreenCameraOpen.value = false;
        }
      },
    );
    unawaited(camera.open(cameraConfig));
    AttachmentGalleryResult? result;
    try {
      result = await future;
    } finally {
      await camera.close();
    }
    if (!mounted) return;
    final path = result?.preparedFilePath ?? result?.cameraCapture?.path;
    if (path == null) return;
    setState(() {
      _pickedImageFile = File(path);
      _showDiscardConfirmation = false;
    });
  }

  bool get _hasAvatarToRemove =>
      _currentImageUrl?.trim().isNotEmpty == true ||
      _currentLocalImagePath?.trim().isNotEmpty == true ||
      _profile?.hasProfileImage == true;

  Future<void> _removeAvatar() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await UserProfileService.instance.deleteProfileImage();
      if (!mounted) return;
      setState(() {
        _pickedImageFile = null;
        _currentImageUrl = null;
        _currentLocalImagePath = null;
        _avatarCacheRevision = DateTime.now().millisecondsSinceEpoch;
        _profile = UserProfileService.instance.cachedProfile ?? _profile;
        _isSaving = false;
      });
      _showSnack('Profile photo removed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _showSnack(e.toString(), isError: true);
    }
  }

  void _showImageOptions() {
    // Keep the existing picker/camera/crop logic, but do not expose an
    // intermediate Gallery/Camera/Remove action sheet.
    unawaited(_chooseProfilePhoto());
  }

  Future<void> _viewProfilePhoto() async {
    final path = _pickedImageFile?.path ?? _currentLocalImagePath;
    if (path == null || !await File(path).exists() || !mounted) return;
    final result = await showWrytteImageViewer(
      context,
      image: FileImage(File(path)),
      imageAspectRatio: 1,
      origin: ExpandingSurfaceOrigin.fromKey(
        _profilePhotoKey,
        borderRadius: BorderRadius.circular(1000),
      ),
      onShare: () => _showSnack('Profile photo sharing will be available here.'),
      allowDelete: true,
      showHeaderLabel: false,
      enableVerticalDragDismiss: true,
    );
    if (result == FullScreenImageResult.deleteRequested && mounted) {
      if (_pickedImageFile != null) {
        setState(() => _pickedImageFile = null);
      } else {
        await _removeAvatar();
      }
    }
  }

  Future<void> _save() async {
    if (_isSaving || !_hasName) return;
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

      final fullName = _nameController.text.trim();
      final nameParts = fullName.split(RegExp(r'\s+'));
      final firstName = nameParts.isNotEmpty ? nameParts[0] : '';
      final lastName =
          nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

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
        channelAlias: _profileRoomReferenceForSave(
          _channelAliasController.text,
          isChannel: true,
        ),
        groupAlias: _profileRoomReferenceForSave(
          _groupAliasController.text,
          isChannel: false,
        ),
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
    await BiometricPrewarmService.clearForLogout();

    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const WelcomeView()),
        (route) => false,
      );
    }
  }

  /// Logout confirmation dialog matching reference image 1:
  /// wider container, single-line title, longer/shorter-height buttons.
  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (context) {
        final screenW = MediaQuery.of(context).size.width;
        // Wider dialog like reference (~78% of screen width)
        final dialogW = screenW * 0.78;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: (screenW - dialogW) / 2,
          ),
          child: Container(
            width: dialogW,
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 22),
            decoration: BoxDecoration(
              color: const Color(0xFF171A20),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: _cardBorder, width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Are you sure you want to log out ?',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 24),
                _logoutDialogButton(
                  'Log out',
                  const Color(0xFFFF5C52),
                  () => Navigator.pop(context, true),
                ),
                const SizedBox(height: 12),
                _logoutDialogButton(
                  'Cancel',
                  Colors.white,
                  () => Navigator.pop(context, false),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed == true && mounted) await _logout();
  }

  /// Full-width stadium buttons matching reference (longer, height ~48).
  Widget _logoutDialogButton(
    String label,
    Color textColor,
    VoidCallback onTap,
  ) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFF23262C),
          foregroundColor: textColor,
          elevation: 0,
          shape: const StadiumBorder(),
          padding: EdgeInsets.zero,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? const Color(0xFFE05252) : _accent,
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

  Widget _outlinedCard({
    required Widget child,
    double radius = 24,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: _cardBorder, width: 1),
      ),
      child: child,
    );
  }

  Widget _inputRow(
    String hint,
    TextEditingController ctrl, {
    int maxLines = 1,
    int? maxLength,
    bool singleLineLink = false,
  }) {
    return TextFormField(
      controller: ctrl,
      maxLines: maxLines,
      maxLength: maxLength,
      inputFormatters:
          singleLineLink
              ? [FilteringTextInputFormatter.deny(RegExp(r'\s'))]
              : null,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      onChanged: (_) {
        if (_showDiscardConfirmation) {
          setState(() => _showDiscardConfirmation = false);
        }
      },
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _hint, fontSize: 16),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        counterText: '',
      ),
    );
  }

  mx.Room? _selectedProfileRoom(String value, {required bool isChannel}) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    for (final room in MatrixChatService.instance.rooms) {
      final roomMatches =
          room.id == normalized || room.canonicalAlias.trim() == normalized;
      final kindMatches =
          isChannel
              ? MatrixChatService.instance.isChannelRoom(room)
              : MatrixChatService.instance.isMatrixGroupRoom(room) &&
                  !MatrixChatService.instance.isChannelRoom(room);
      if (roomMatches && kindMatches) return room;
    }
    return null;
  }

  String _profileRoomReferenceForSave(String value, {required bool isChannel}) {
    final normalized = value.trim();
    if (normalized.isEmpty) return '';
    return _selectedProfileRoom(normalized, isChannel: isChannel)?.id.trim() ??
        normalized;
  }

  Future<void> _openProfileRoomPicker(
    TextEditingController controller, {
    required bool isChannel,
  }) async {
    final result = await Navigator.push<ProfileRoomPickerResult>(
      context,
      MaterialPageRoute(
        builder:
            (_) => ProfileRoomPickerScreen(
              isChannel: isChannel,
              selectedValue: controller.text,
            ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      controller.text = result.removed ? '' : (result.value ?? '');
      _showDiscardConfirmation = false;
    });
  }

  Widget _profileRoomRow(
    String label,
    TextEditingController controller, {
    required bool isChannel,
  }) {
    final room = _selectedProfileRoom(controller.text, isChannel: isChannel);
    final title = room?.getLocalizedDisplayname()?.trim();
    final displayLabel =
        (title != null && title.isNotEmpty) ? title : label;

    return InkWell(
      onTap: () => _openProfileRoomPicker(controller, isChannel: isChannel),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                displayLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
            const Text(
              'Add',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right,
              color: Color(0xFF9A9DA4),
              size: 20,
            ),
          ],
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

  Widget _closeButton() {
    return GestureDetector(
      onTap: () {
        if (!_hasUnsavedChanges) {
          Navigator.pop(context);
          return;
        }
        setState(() => _showDiscardConfirmation = true);
      },
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _cardBorder.withValues(alpha: 0.55),
              border: Border.all(color: _cardBorder, width: 1),
            ),
            child: const Icon(Icons.close, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }

  Widget _discardChangesButton() {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1D24).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _cardBorder, width: 1),
        ),
        alignment: Alignment.center,
        child: const Text(
          'Discard changes',
          style: TextStyle(
            color: _discardRed,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _saveButton() {
    return AnimatedBuilder(
      animation: _nameController,
      builder: (context, _) {
        final canSave = _hasName && !_isSaving;
        return GestureDetector(
          onTap: canSave ? _save : null,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: canSave ? _accent : const Color(0xFF3A3D44),
            ),
            child: Center(
              child: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check, color: Colors.white, size: 22),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.of(context).padding.top;
    final accountLabel =
        WrytteId.forDisplay(_profile?.phone ?? '') != null
            ? 'Wrytte ID'
            : 'Phone number';

    const topBarBlock = 40.0 + 16.0;
    const avatarTopGap = 12.0;
    const avatarSize = 100.0;
    final discardTop = statusBar + topBarBlock + avatarTopGap + 4;

    Widget avatarWidget = _pickedImageFile != null
        ? GestureDetector(
            key: _profilePhotoKey,
            onTap: _viewProfilePhoto,
            child: ClipOval(
              child: Image.file(
                _pickedImageFile!,
                width: avatarSize,
                height: avatarSize,
                fit: BoxFit.cover,
              ),
            ),
          )
        : GestureDetector(
            key: _profilePhotoKey,
            onTap: _hasAvatarToRemove ? _viewProfilePhoto : _chooseProfilePhoto,
            child: UserAvatar(
              size: avatarSize,
              imageUrl: _cacheBustedAvatarUrl(_currentImageUrl),
              localImagePath: _currentLocalImagePath,
              name: _profile?.displayName,
            ),
          );

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          _isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: _accent,
                    strokeWidth: 2,
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.only(
                        top: statusBar + 8,
                        left: 16,
                        right: 16,
                        bottom: 8,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _closeButton(),
                          _saveButton(),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const SizedBox(height: avatarTopGap),
                              avatarWidget,
                              const SizedBox(height: 12),
                              GestureDetector(
                                onTap: _showImageOptions,
                                child: const Text(
                                  'Edit Photo',
                                  style: TextStyle(
                                    color: _accent,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 28),
                              _outlinedCard(
                                child: _inputRow(
                                  'Name',
                                  _nameController,
                                  maxLength: 35,
                                ),
                              ),
                              const SizedBox(height: 12),
                              _outlinedCard(
                                child: _inputRow(
                                  'Bio',
                                  _bioController,
                                  maxLength: 110,
                                ),
                              ),
                              const SizedBox(height: 12),
                              _outlinedCard(
                                child: _inputRow(
                                  'Link',
                                  _linkController,
                                  singleLineLink: true,
                                ),
                              ),
                              const SizedBox(height: 12),
                              _outlinedCard(
                                radius: 20,
                                child: Column(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 14,
                                      ),
                                      child: Row(
                                        children: [
                                          Text(
                                            accountLabel,
                                            style: const TextStyle(
                                              color: _hint,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            _formattedAccountNumber(),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          const Icon(
                                            Icons.chevron_right,
                                            color: Color(0xFF9A9DA4),
                                            size: 20,
                                          ),
                                        ],
                                      ),
                                    ),
                                    _divider(),
                                    _profileRoomRow(
                                      'Channel',
                                      _channelAliasController,
                                      isChannel: true,
                                    ),
                                    _divider(),
                                    _profileRoomRow(
                                      'Group',
                                      _groupAliasController,
                                      isChannel: false,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              _outlinedCard(
                                child: InkWell(
                                  onTap: null,
                                  borderRadius: BorderRadius.circular(24),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 16),
                                    child: Center(
                                      child: Text(
                                        '+ Add Account',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _outlinedCard(
                                child: InkWell(
                                  onTap: _isLoggingOut ? null : _confirmLogout,
                                  borderRadius: BorderRadius.circular(24),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    child: Center(
                                      child: _isLoggingOut
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
                              ),
                              const SizedBox(height: 40),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

          if (_showDiscardConfirmation)
            Positioned(
              top: discardTop,
              left: 16,
              child: _discardChangesButton(),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _fullScreenCameraOpen.dispose();
    _nameController.dispose();
    _bioController.dispose();
    _linkController.dispose();
    _channelAliasController.dispose();
    _groupAliasController.dispose();
    super.dispose();
  }
}
