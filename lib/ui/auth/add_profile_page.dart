import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

class AddProfilePage extends StatefulWidget {
  final bool isNewUser;

  const AddProfilePage({super.key, this.isNewUser = false});

  @override
  State<AddProfilePage> createState() => _AddProfilePageState();
}

class _AddProfilePageState extends State<AddProfilePage> {
  final TextEditingController _nicknameController = TextEditingController();

  bool _syncContacts = true;
  bool _isValid = false;
  bool _isSaving = false;
  bool _isLoading = true;

  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _nicknameController.addListener(_onTextChanged);
    _loadUserData();
  }

  @override
  void dispose() {
    _nicknameController
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final valid = _nicknameController.text.trim().length >= 2;
    if (valid != _isValid) setState(() => _isValid = valid);
  }

  /// Loads uid and optionally pre-fills existing name.
  /// Timeout reduced to 3s and uid + Firestore fetched concurrently.
  Future<void> _loadUserData() async {
    try {
      final uid = await AuthService.instance
          .getCurrentUserId()
          .timeout(const Duration(seconds: 3));

      if (uid == null || uid.isEmpty) {
        debugPrint('[AddProfilePage] No uid found');
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      _currentUserId = uid;

      if (!widget.isNewUser) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .get()
              .timeout(const Duration(seconds: 3)); // was 6s — halved

          final existingName = doc.data()?['name'] as String?;
          if (existingName != null &&
              existingName.trim().length >= 2 &&
              !_looksLikePhoneNumber(existingName.trim())) {
            _nicknameController.text = existingName.trim();
            _isValid = true;
          }
        } catch (e) {
          debugPrint('[AddProfilePage] Could not pre-fill name: $e');
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
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => HomeScreen(currentUserId: uid)),
      (route) => false,
    );
  }

  Future<void> _saveAndGoHome() async {
    if (!_isValid || _isSaving) return;

    final name = _nicknameController.text.trim();
    final uid =
        _currentUserId ?? await AuthService.instance.getCurrentUserId();

    if (uid == null || uid.isEmpty) {
      debugPrint('[AddProfilePage] _saveAndGoHome: uid is null, aborting');
      return;
    }
    _currentUserId = uid;

    if (mounted) setState(() => _isSaving = true);

    await AuthService.instance.updateStoredUsername(name);
    _syncProfileInBackground(uid, name);
    await _navigateHome(uid);
  }

  void _syncProfileInBackground(String uid, String name) {
    unawaited(() async {
      try {
        await AuthService.instance.ensureFirebaseAuth();

        final List<String?> errors = await Future.wait<String?>(
          [
            _updateFirestore(uid, name),
            _updateMatrixNicknameWithRetry(name),
          ],
          eagerError: false,
        );

        for (final error in errors) {
          if (error != null) debugPrint('[AddProfilePage] Save warning: $error');
        }
      } catch (e) {
        debugPrint('[AddProfilePage] background profile sync error: $e');
      }
    }());
  }

  Future<String?> _updateFirestore(String uid, String name) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set(
            {
              'name': name,
              'username': name,
              'updatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('[AddProfilePage] Firestore name updated → "$name"');
      return null;
    } catch (e) {
      return 'Firestore write failed: $e';
    }
  }

  Future<String?> _updateMatrixNicknameWithRetry(String name) async {
    const maxAttempts = 5;
    const retryDelay = Duration(milliseconds: 800);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await AuthService.instance.updateStoredUsername(name)
            .timeout(const Duration(seconds: 10));
        debugPrint('[AddProfilePage] Matrix nickname updated -> "$name"');
        return null;
      } catch (e) {
        debugPrint(
          '[AddProfilePage] Matrix display-name attempt $attempt/$maxAttempts '
          'failed: $e',
        );
        if (attempt < maxAttempts) await Future.delayed(retryDelay);
      }
    }

    return 'Matrix display-name update failed after $maxAttempts attempts';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
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
                  onPressed: (_isValid && !_isSaving) ? _saveAndGoHome : null,
                  child: _isSaving
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
                            color: _isValid ? Colors.white : Colors.grey,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 40),

              // ── Avatar placeholder ───────────────────────────────────────
              GestureDetector(
                onTap: () {
                  // TODO: open image picker.
                },
                child: const CircleAvatar(
                  radius: 50,
                  backgroundColor: Color(0xFF1F4F7F),
                  child: Icon(Icons.person, size: 50, color: Colors.white70),
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
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (_isValid && !_isSaving) _saveAndGoHome();
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
                    onChanged: (value) =>
                        setState(() => _syncContacts = value ?? true),
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
