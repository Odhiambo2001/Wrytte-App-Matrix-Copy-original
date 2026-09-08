import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/face/biometric_enrollment_timing.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

class AddProfilePage extends StatefulWidget {
  final bool isNewUser;
  final Future<bool>? biometricSetup;
  final DateTime? navigationRequestedAt;
  final int? firstFrameToNavigationRequestMs;
  final bool lockNameAndDone;

  const AddProfilePage({
    super.key,
    this.isNewUser = false,
    this.biometricSetup,
    this.navigationRequestedAt,
    this.firstFrameToNavigationRequestMs,
    this.lockNameAndDone = false,
  });

  @override
  State<AddProfilePage> createState() => _AddProfilePageState();
}

class _AddProfilePageState extends State<AddProfilePage> {
  final TextEditingController _nicknameController = TextEditingController();
  final FocusNode _nicknameFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();

  bool _syncContacts = true;
  bool _isValid = false;
  bool _isSaving = false;
  bool _isLoading = true;
  late bool _biometricReady;
  bool _biometricFailed = false;

  String? _currentUserId;
  File? _pickedProfileImage;

  bool get _profileReady => _biometricReady && !_isLoading;
  bool get _nameAndDoneEnabled => _profileReady && !widget.lockNameAndDone;

  @override
  void initState() {
    super.initState();
    _biometricReady = widget.biometricSetup == null;
    UserProfileService.instance.setFirstSignupMode(widget.isNewUser);
    _nicknameController.addListener(_onTextChanged);
    _loadUserData();
    _waitForBiometricSetup();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final requestedAt = widget.navigationRequestedAt;
      if (requestedAt == null) return;
      final requestToFirstRenderMs =
          DateTime.now().difference(requestedAt).inMilliseconds;
      final firstFrameToRequestMs = widget.firstFrameToNavigationRequestMs;
      final firstFrameToFirstRenderMs =
          firstFrameToRequestMs == null
              ? null
              : firstFrameToRequestMs + requestToFirstRenderMs;
      debugPrint(
        '[KFace][Timing][Navigation] destination=PROFILE '
        'event=FIRST_RENDER requestToFirstRenderMs=$requestToFirstRenderMs '
        'firstFrameToFirstRenderMs=$firstFrameToFirstRenderMs',
      );
    });
  }

  Future<void> _waitForBiometricSetup() async {
    final setup = widget.biometricSetup;
    if (setup == null) return;
    var ready = false;
    try {
      ready = await setup;
    } catch (error) {
      debugPrint('[AddProfilePage] biometric setup failed: $error');
    }
    if (!mounted) return;
    setState(() {
      _biometricReady = ready;
      _biometricFailed = !ready;
    });
    if (ready && !widget.lockNameAndDone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nicknameFocusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _nicknameController
      ..removeListener(_onTextChanged)
      ..dispose();
    _nicknameFocusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final valid = _nicknameController.text.trim().length >= 2;
    if (valid != _isValid) setState(() => _isValid = valid);
  }

  Future<void> _loadUserData() async {
    try {
      final uid = await AuthService.instance.getCurrentUserId().timeout(
        const Duration(seconds: 3),
      );

      if (uid == null || uid.isEmpty) {
        debugPrint('[AddProfilePage] No uid found');
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      _currentUserId = uid;

      // Pre-fill name from local storage first, then heal from the persisted
      // profile document when this is a returning account on a fresh device.
      if (!widget.isNewUser) {
        var existingName = await AuthService.instance.getCurrentUsername();
        if (existingName == null ||
            existingName.trim().length < 2 ||
            _looksLikePhoneNumber(existingName.trim())) {
          final remoteProfile = await AuthService.instance.hydrateStoredProfile(
            uid,
          );
          existingName = remoteProfile?.username ?? existingName;
        }
        if (existingName != null &&
            existingName.trim().length >= 2 &&
            !_looksLikePhoneNumber(existingName.trim())) {
          _nicknameController.text = existingName.trim();
          _isValid = true;
          debugPrint(
            '[AddProfilePage] Pre-filled name from local storage: "$existingName"',
          );
        }
      }
    } catch (e) {
      debugPrint('[AddProfilePage] _loadUserData error: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  bool _looksLikePhoneNumber(String value) {
    final stripped = value.replaceAll(RegExp(r'[\s\-]'), '');
    return RegExp(r'^\+?\d{6,}$').hasMatch(stripped);
  }

  Future<void> _navigateHome(String uid) async {
    if (!mounted) return;
    final currentUser = await AuthService.instance.getCurrentUser();
    if (!mounted) return;
    if (widget.isNewUser) BiometricEnrollmentTiming.logHomeNavigation();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder:
            (_) => HomeScreen(
              currentUserId: uid,
              initialProfileName:
                  _nicknameController.text.trim().isNotEmpty
                      ? _nicknameController.text.trim()
                      : currentUser?.username,
              initialPhone: currentUser?.phone,
              isFirstSignup: widget.isNewUser,
            ),
      ),
      (route) => false,
    );
  }

  Future<void> _saveAndGoHome() async {
    if (!_nameAndDoneEnabled || !_isValid || _isSaving) return;

    final name = _nicknameController.text.trim();
    final uid = _currentUserId ?? await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.isEmpty) return;
    _currentUserId = uid;

    if (mounted) setState(() => _isSaving = true);

    await UserProfileService.instance.updateDisplayName(name);
    debugPrint('[AddProfilePage] Name saved locally: "$name"');

    final profileImage = _pickedProfileImage;
    if (profileImage != null) {
      unawaited(_uploadProfileImageInBackground(profileImage));
    }

    // Re-persist the local session quickly; Matrix can finish in the background.
    final secret = await AuthService.instance.getStoredSecret() ?? '';
    final phone = await AuthService.instance.getSavedPhone() ?? '';
    await AuthService.instance.persistPhoneSession(
      userId: uid,
      username: name, // explicit real name — bypasses the phone-number guard
      phone: phone,
      secret: secret,
      preferMatrixRegisterFirst: widget.isNewUser,
      deferNonEssentialInitialization: widget.isNewUser,
    );

    _syncProfileInBackground(name);
    await _navigateHome(uid);
  }

  Future<void> _pickProfileImage() async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      setState(() => _pickedProfileImage = File(picked.path));
    } catch (error) {
      debugPrint('[AddProfilePage] profile image selection failed: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not select a profile photo.')),
      );
    }
  }

  Future<void> _uploadProfileImageInBackground(File image) async {
    try {
      await UserProfileService.instance.uploadProfileImage(image);
      debugPrint('[AddProfilePage] profile image uploaded');
    } catch (error) {
      // The profile remains usable when an optional avatar upload is offline;
      // UserProfileService keeps the local image pending for retry.
      debugPrint('[AddProfilePage] profile image upload pending: $error');
    }
  }

  void _syncProfileInBackground(String name) {
    unawaited(() async {
      try {
        await _updateMatrixNicknameWithRetry(name);
      } catch (e) {
        debugPrint('[AddProfilePage] background profile sync error: $e');
      }
    }());
  }

  Future<void> _updateMatrixNicknameWithRetry(String name) async {
    const maxAttempts = 3;
    const retryDelay = Duration(seconds: 1);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await AuthService.instance
            .updateStoredUsername(name)
            .timeout(const Duration(seconds: 10));
        debugPrint('[AddProfilePage] Matrix display name updated: "$name"');
        return;
      } catch (e) {
        debugPrint(
          '[AddProfilePage] Matrix display-name attempt $attempt/$maxAttempts failed: $e',
        );
        if (attempt < maxAttempts) await Future.delayed(retryDelay);
      }
    }

    debugPrint(
      '[AddProfilePage] Matrix display-name update failed after $maxAttempts attempts — local name still saved',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && widget.biometricSetup == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF08090B),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF2AABEE)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Top bar — Done only ──────────────────────────────────────
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed:
                      (_nameAndDoneEnabled && _isValid && !_isSaving)
                          ? _saveAndGoHome
                          : null,
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
                          : Text(
                            'Done',
                            style: TextStyle(
                              color:
                                  _nameAndDoneEnabled && _isValid
                                      ? Colors.white
                                      : Colors.grey,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                ),
              ),

              const SizedBox(height: 40),

              // ── Avatar placeholder ───────────────────────────────────────
              GestureDetector(
                onTap: _profileReady ? _pickProfileImage : null,
                child: CircleAvatar(
                  radius: 50,
                  backgroundColor: const Color(0xFF1F4F7F),
                  backgroundImage:
                      _pickedProfileImage == null
                          ? null
                          : FileImage(_pickedProfileImage!),
                  child:
                      _pickedProfileImage == null
                          ? const Icon(
                            Icons.person,
                            size: 50,
                            color: Colors.white70,
                          )
                          : null,
                ),
              ),

              const SizedBox(height: 16),

              const Text(
                'Set profile photo',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),

              const SizedBox(height: 40),

              // ── Name field ───────────────────────────────────────────────
              TextField(
                controller: _nicknameController,
                focusNode: _nicknameFocusNode,
                enabled: _nameAndDoneEnabled,
                autofocus: _nameAndDoneEnabled,
                style: const TextStyle(color: Colors.white),
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (_nameAndDoneEnabled && _isValid && !_isSaving) {
                    _saveAndGoHome();
                  }
                },
                decoration: InputDecoration(
                  hintText: 'Enter Name',
                  hintStyle: const TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF23262C),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 18,
                  ),
                ),
              ),

              const SizedBox(height: 10),

              if (_biometricFailed)
                Align(
                  alignment: Alignment.centerLeft,
                  child: const Text(
                    'Secure face setup failed. Return and scan again.',
                    style: TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),

              if (_biometricFailed) const SizedBox(height: 10),

              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Your name must include at least 2 letters or symbols',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),

              const SizedBox(height: 30),

              // ── Sync contacts toggle ─────────────────────────────────────
              Row(
                children: [
                  Checkbox(
                    value: _syncContacts,
                    activeColor: const Color(0xFF2AABEE),
                    onChanged:
                        _profileReady
                            ? (value) =>
                                setState(() => _syncContacts = value ?? true)
                            : null,
                  ),
                  const Text(
                    'Sync contacts',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
