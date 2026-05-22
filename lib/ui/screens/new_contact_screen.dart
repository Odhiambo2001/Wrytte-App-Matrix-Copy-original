import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/contacts/user_search_service.dart';
import 'package:wrytte/ui/screens/Country%20id%20picker%20page.dart';
import 'package:wrytte/utils/countries_id.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';

// ─────────────────────────────────────────────────────────────────
// Colours
// ─────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF08090B);
const _kCard = Color(0xFF23262C);
const _kBlue = Color(0xFF4DA3FF);
const _kDivider = Colors.white12;

// ─────────────────────────────────────────────────────────────────
// Enum for the three possible lookup states
// ─────────────────────────────────────────────────────────────────
enum _LookupState { idle, found, duplicate, notFound, error }

class NewContactPage extends StatefulWidget {
  /// Bearer token for the UserSearchService call.
  final String token;

  const NewContactPage({super.key, required this.token});

  @override
  State<NewContactPage> createState() => _NewContactPageState();
}

class _NewContactPageState extends State<NewContactPage> {
  // ── Controllers & focus ──────────────────────────────────────
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _numberCtrl = TextEditingController();

  final _codeFocusNode = FocusNode();
  final _numberFocusNode = FocusNode();

  // ── Country ───────────────────────────────────────────────────
  CountryId? _selectedCountry;
  bool _showDivider = false;
  bool _isAutoFilling = false;

  // ── Sync toggle ───────────────────────────────────────────────
  bool _syncToPhone = true;

  // ── Lookup ────────────────────────────────────────────────────
  final UserSearchService _searchService = UserSearchService();
  final ContactService _contactService = ContactService();
  Timer? _debounce;
  _LookupState _lookupState = _LookupState.idle;

  /// The wrytteUserId returned by the lookup — needed for addFriend.
  String? _resolvedUserId;
  bool _isRegisteredOnWrytte = false;
  String? _lookupError;

  // ── Saving ────────────────────────────────────────────────────
  bool _isSaving = false;
  String? _saveError;

  // ─────────────────────────────────────────────────────────────
  // Computed helpers
  // ─────────────────────────────────────────────────────────────
  bool get _isWrytteIdMode => _selectedCountry?.isoCode == 'WID';

  String get _fullIdentifier {
    if (_selectedCountry == null) return '';
    final raw = _numberCtrl.text.trim();
    if (_isWrytteIdMode) return raw;
    final normalized = raw.startsWith('0') ? raw.substring(1) : raw;
    return '+${_selectedCountry!.dialCode}$normalized';
  }

  bool get _canSave =>
      _firstNameCtrl.text.trim().isNotEmpty &&
      _selectedCountry != null &&
      _numberCtrl.text.trim().length >= 4;

  // ─────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _codeCtrl.text = '+';
      _codeCtrl.selection = TextSelection.fromPosition(
        const TextPosition(offset: 1),
      );
      _codeFocusNode.requestFocus();
    });
    _numberCtrl.addListener(_onNumberChanged);
    _firstNameCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _codeCtrl.dispose();
    _numberCtrl.dispose();
    _codeFocusNode.dispose();
    _numberFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────
  // Country picker
  // ─────────────────────────────────────────────────────────────
  Future<void> _pickCountry() async {
    final result = await Navigator.of(context).push<CountryId>(
      MaterialPageRoute(builder: (_) => const CountryIdPickerPage()),
    );

    if (result != null) {
      setState(() {
        _selectedCountry = result;
        _codeCtrl.text = '+${result.dialCode}';
        _showDivider = true;
        _lookupState = _LookupState.idle;
        _resolvedUserId = null;
        _isRegisteredOnWrytte = false;
        _lookupError = null;
        _saveError = null;
      });
      _numberFocusNode.requestFocus();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Auto-detect country from typed code
  // ─────────────────────────────────────────────────────────────
  void _detectCountryFromCode(String value) {
    if (_isAutoFilling) return;

    final digitsOnly = value.replaceAll(RegExp(r'[^\d]'), '');
    if (!value.startsWith('+') || value != '+$digitsOnly') {
      _codeCtrl.text = '+$digitsOnly';
      _codeCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _codeCtrl.text.length),
      );
    }

    final codeWithoutPlus = digitsOnly;

    for (final country in countriesId) {
      if (country.dialCode == codeWithoutPlus) {
        setState(() {
          _selectedCountry = country;
          _showDivider = true;
          _lookupState = _LookupState.idle;
          _resolvedUserId = null;
          _isRegisteredOnWrytte = false;
          _lookupError = null;
        });

        if (!_isAutoFilling && codeWithoutPlus.isNotEmpty) {
          _isAutoFilling = true;
          Future.delayed(const Duration(milliseconds: 100), () {
            _numberFocusNode.requestFocus();
            _isAutoFilling = false;
          });
        }
        break;
      }
    }
  }

  void _onCodeFieldTap() {
    if (_codeCtrl.text.isEmpty) {
      _codeCtrl.text = '+';
      _codeCtrl.selection = const TextSelection.collapsed(offset: 1);
    } else if (!_codeCtrl.text.startsWith('+')) {
      _codeCtrl.text = '+${_codeCtrl.text}';
      _codeCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _codeCtrl.text.length),
      );
    } else {
      _codeCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _codeCtrl.text.length),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Number field → debounced lookup
  // ─────────────────────────────────────────────────────────────
  void _onNumberChanged() {
    setState(() {
      _lookupState = _LookupState.idle;
      _resolvedUserId = null;
      _isRegisteredOnWrytte = false;
      _lookupError = null;
      _saveError = null;
    });
    _debounce?.cancel();

    final num = _numberCtrl.text.trim();
    if (_selectedCountry == null || num.length < 4) return;

    _debounce = Timer(const Duration(milliseconds: 600), _lookupUser);
  }

  Future<void> _lookupUser() async {
    final freshToken =
        await AuthService.instance.getMatrixAccessToken() ?? widget.token;
    debugPrint('🔍 _lookupUser called, identifier: $_fullIdentifier');
    final identifier = _fullIdentifier;
    if (identifier.isEmpty) return;

    try {
      final tokenPreviewLength =
          freshToken.length < 20 ? freshToken.length : 20;
      debugPrint(
        '🔑 token: ${freshToken.isEmpty ? "EMPTY" : freshToken.substring(0, tokenPreviewLength)}',
      );
      final Map<String, String> result;

      if (_isWrytteIdMode) {
        result = await _searchService.searchUsersByPhones(
          phoneNumbersC: identifier,
          token: freshToken,
        );
      } else {
        result = await _searchService.searchUsersByPhones(
          phoneNumbersA: [identifier],
          token: freshToken,
        );
      }

      debugPrint('Lookup result keys: ${result.keys.toList()}');
      debugPrint('Looking for identifier: $identifier');

      if (!mounted) return;

      final lookupValue =
          result[identifier] ??
          result[_normalizeIdentifier(identifier)] ??
          result[_digitsOnly(identifier)];

      if (lookupValue != null && lookupValue.isNotEmpty) {
        final matrixUserId =
            lookupValue == UserSearchService.registeredWithoutMatrixId
                ? null
                : lookupValue;
        setState(() {
          _lookupState = _LookupState.found;
          _resolvedUserId = matrixUserId;
          _isRegisteredOnWrytte = true;
          _lookupError = null;
        });
      } else {
        setState(() {
          _lookupState = _LookupState.notFound;
          _resolvedUserId = null;
          _isRegisteredOnWrytte = false;
          _lookupError = null;
        });
      }
    } catch (e) {
      debugPrint('🔴 Lookup error: $e');
      if (!mounted) return;
      setState(() {
        _lookupState = _LookupState.error;
        _resolvedUserId = null;
        _isRegisteredOnWrytte = false;
        _lookupError = _friendlyLookupError(e.toString());
      });
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Save — now fully wired to Matrix + device contacts
  // ─────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (!_canSave || _isSaving) return;

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      final String selfId = await AuthService.instance.getCurrentUserId() ?? '';
      apkLog(
        'NewContact.save',
        'save tapped self="$selfId" name="${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}" identifier="$_fullIdentifier" resolvedUserId="$_resolvedUserId" lookupState=$_lookupState',
      );
      debugPrint('🧑 selfUserId in _save: $selfId');
      debugPrint('identifier=$_fullIdentifier');
      debugPrint('resolvedUserId=$_resolvedUserId');
      if (_matrixLocalpart(_resolvedUserId) == selfId) {
        throw StateError(
          'You cannot add your own Wrytte account as a contact.',
        );
      }
      apkLog('NewContact.save', 'connecting Matrix before contact save');
      await ChatService().connect();
      apkLog('NewContact.save', 'Matrix connected; saving contact');

      final saved = await _contactService.saveManualContact(
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        fullIdentifier: _fullIdentifier,
        wrytteUserId: _resolvedUserId,
        isOnWrytte: _isRegisteredOnWrytte,
        syncToPhone: _syncToPhone,
        token:
            await AuthService.instance.getMatrixAccessToken() ?? widget.token,
        selfUserId: selfId,
      );

      if (!mounted) return;
      apkLog(
        'NewContact.save',
        'save success name="${saved.formattedName}" wrytteUserId="${saved.wrytteUserId}" phone="${saved.primaryPhone}"',
      );

      final receiverId = saved.wrytteUserId ?? '';
      final ids = [
        _conversationKey(selfId),
        _conversationKey(receiverId.isNotEmpty ? receiverId : _fullIdentifier),
      ]..sort();
      final conversationId = 'si_${ids[0]}_${ids[1]}';

      // Always navigate to chat — whether on Wrytte or not
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder:
              (_) => ChatScreen(
                conversationId: conversationId,
                receiverId:
                    receiverId.isNotEmpty ? receiverId : _fullIdentifier,
                currentUserId: selfId,
                title: saved.formattedName,
                avatarUrl: saved.avatarUrl,
              ),
        ),
      );
    } catch (e) {
      debugPrint('Save contact error: $e');
      apkLog('NewContact.save', 'save FAILED error="$e"');
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveError = _friendlyError(e.toString());
      });
    }
  }

  String _friendlyError(String raw) {
    if (raw.toLowerCase().contains('own wrytte account')) {
      return 'You cannot add yourself as a contact.';
    }
    if (raw.contains('1201')) return 'You are already friends with this user.';
    if (raw.contains('permission')) return 'Phone contacts permission denied.';
    if (raw.contains('not authenticated')) {
      return 'Session expired — please log in again.';
    }
    if (raw.toLowerCase().contains('matrix') ||
        raw.toLowerCase().contains('timeout')) {
      return 'Matrix contact save failed. Check connection and try again.';
    }
    return 'Something went wrong. Please try again.';
  }

  String? _matrixLocalpart(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  String _conversationKey(String value) {
    final localpart = _matrixLocalpart(value) ?? value.trim();
    return localpart.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
  }

  String _friendlyLookupError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('resolver endpoint') || lower.contains('404')) {
      return 'Could not verify this phone yet. Contact lookup is not available.';
    }
    if (lower.contains('backend session') ||
        lower.contains('session is missing') ||
        lower.contains('401') ||
        lower.contains('unauthorized')) {
      return 'Please sign in again so Wrytte can verify this phone number.';
    }
    if (lower.contains('network') ||
        lower.contains('socket') ||
        lower.contains('timeout') ||
        lower.contains('connection')) {
      return 'Could not verify this phone. Check your connection.';
    }
    return 'Could not verify this phone number right now.';
  }

  String _normalizeIdentifier(String identifier) {
    final trimmed = identifier.trim();
    final digits = _digitsOnly(trimmed);
    if (digits.length >= 6) return '+$digits';
    return trimmed;
  }

  String _digitsOnly(String identifier) =>
      identifier.replaceAll(RegExp(r'[^\d]'), '');

  // ─────────────────────────────────────────────────────────────
  // Status line below the number card
  // ─────────────────────────────────────────────────────────────
  Widget _buildStatusLine() {
    // Show a persistent error if saving failed
    if (_saveError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          _saveError!,
          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
        ),
      );
    }

    if (_lookupState == _LookupState.idle) return const SizedBox.shrink();

    final bool isWrytteId = _isWrytteIdMode;

    Widget statusRow(String text, {bool checkmark = false, Widget? trailing}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Text(
              text,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            if (checkmark) ...[
              const SizedBox(width: 4),
              const Text(
                '✓',
                style: TextStyle(color: Colors.green, fontSize: 13),
              ),
            ],
            if (trailing != null) trailing,
          ],
        ),
      );
    }

    switch (_lookupState) {
      case _LookupState.found:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: statusRow(
            isWrytteId
                ? 'Wrytte number is on Wrytte'
                : 'Phone number is on Wrytte',
            checkmark: true,
          ),
        );

      case _LookupState.duplicate:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              statusRow(
                isWrytteId
                    ? 'Wrytte number is already in your contacts.'
                    : 'Phone number is already in your contacts.',
                trailing: TextButton(
                  onPressed: () {
                    // TODO: navigate to existing contact
                  },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    ' View contact',
                    style: TextStyle(color: _kBlue, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        );

      case _LookupState.notFound:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child:
              isWrytteId
                  ? statusRow('Wrytte number is not on Wrytte.')
                  : Row(
                    children: [
                      const Text(
                        'Phone number is not on Wrytte. ',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      GestureDetector(
                        onTap: () {
                          // TODO: share invite link
                        },
                        child: const Text(
                          'Invite',
                          style: TextStyle(color: _kBlue, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
        );

      case _LookupState.error:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _lookupError ?? 'Could not verify this phone number right now.',
            style: const TextStyle(color: Colors.redAccent, fontSize: 13),
          ),
        );

      case _LookupState.idle:
        return const SizedBox.shrink();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        elevation: 0,
        leading: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
        leadingWidth: 80,
        centerTitle: true,
        title: const Text(
          'New contact',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          TextButton(
            onPressed: _canSave && !_isSaving ? _save : null,
            child:
                _isSaving
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _kBlue,
                      ),
                    )
                    : Text(
                      'Save',
                      style: TextStyle(
                        color: _canSave ? _kBlue : Colors.white38,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Name card ──────────────────────────────────────
              _Card(
                child: Column(
                  children: [
                    _NameField(
                      controller: _firstNameCtrl,
                      hint: 'First name',
                      onChanged: (_) => setState(() {}),
                    ),
                    const Divider(height: 1, color: _kDivider),
                    _NameField(
                      controller: _lastNameCtrl,
                      hint: 'Last name',
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // ── Label ─────────────────────────────────────────
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  'Add phone number or Wrytte number here',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),

              // ── Country + Phone card ───────────────────────────
              _Card(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Country selector row
                    ListTile(
                      onTap: _pickCountry,
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      title: Text(
                        _selectedCountry == null
                            ? 'Country'
                            : _isWrytteIdMode
                            ? 'Wrytte ID number'
                            : '${_selectedCountry!.flag} ${_selectedCountry!.name}',
                        style: TextStyle(
                          color:
                              _selectedCountry == null
                                  ? Colors.white38
                                  : Colors.white,
                          fontSize: 15,
                          fontWeight:
                              _selectedCountry != null
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Colors.white54,
                        size: 20,
                      ),
                    ),

                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Divider(color: _kDivider, height: 1),
                    ),

                    // Code + number row
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          // Dial-code field
                          SizedBox(
                            width: 68,
                            child: TextField(
                              controller: _codeCtrl,
                              focusNode: _codeFocusNode,
                              keyboardType: TextInputType.phone,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                              ),
                              onChanged:
                                  _isWrytteIdMode
                                      ? null
                                      : _detectCountryFromCode,
                              onTap: _onCodeFieldTap,
                              readOnly: _isWrytteIdMode,
                            ),
                          ),

                          // Blue vertical divider
                          if (_showDivider)
                            Container(
                              height: 22,
                              width: 1,
                              color: _kBlue,
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                            ),

                          // Number / ID field
                          Expanded(
                            child: TextField(
                              controller: _numberCtrl,
                              focusNode: _numberFocusNode,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                              decoration: InputDecoration(
                                hintText:
                                    _showDivider
                                        ? (_isWrytteIdMode
                                            ? 'Wrytte ID'
                                            : 'Phone number')
                                        : '',
                                hintStyle: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 15,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                              ),
                              enabled: _showDivider,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Status line ────────────────────────────────────
              _buildStatusLine(),

              const SizedBox(height: 22),

              // ── Sync to phone card ─────────────────────────────
              _Card(
                child: SwitchListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  title: const Text(
                    'Sync contact to phone',
                    style: TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  value: _syncToPhone,
                  activeThumbColor: _kBlue,
                  onChanged: (v) => setState(() => _syncToPhone = v),
                ),
              ),

              const SizedBox(height: 28),

              // ── Add via QR code ────────────────────────────────
              Center(
                child: GestureDetector(
                  onTap: () {
                    // TODO: open QR scanner
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.qr_code_2_rounded, color: _kBlue, size: 28),
                      SizedBox(width: 8),
                      Text(
                        'Add via QR code',
                        style: TextStyle(
                          color: _kBlue,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Reusable card wrapper
// ─────────────────────────────────────────────────────────────────
class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Reusable name text field
// ─────────────────────────────────────────────────────────────────
class _NameField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  const _NameField({
    required this.controller,
    required this.hint,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        cursorColor: _kBlue,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 15),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}
