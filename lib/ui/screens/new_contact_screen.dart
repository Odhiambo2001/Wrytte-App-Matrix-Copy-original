import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/contact_user_profiles.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/services/contacts/user_search_service.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/auth/widgets/wrytte_id_checkmark.dart';
import 'package:wrytte/ui/auth/widgets/sync_contacts_switch.dart';
import 'package:wrytte/ui/screens/Country%20id%20picker%20page.dart';
import 'package:wrytte/ui/screens/profile_screen.dart';
import 'package:wrytte/utils/countries_id.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'package:wrytte/utils/country_phone_number.dart';

// ─────────────────────────────────────────────────────────────────
// Colours
// ─────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF08090B);
const _kCard = Color(0xFF23262C);
const _kBlue = Color(0xFF4DA3FF);
const _kDivider = Colors.white12;
const _kMinPhoneLookupDigits = 8;
const _kMaxPhoneLookupDigits = 13;
const _kPhoneLookupDebounce = Duration(milliseconds: 500);
const _kWrytteIdLookupDebounce = Duration(milliseconds: 300);

String _formatWrytteIdBody(String value) {
  final digits = value.replaceAll(RegExp(r'[^\d]'), '');
  return digits.length > 12 ? digits.substring(0, 12) : digits;
}

String _formatWrytteIdInput(String digits) {
  final normalized = digits.replaceAll(RegExp(r'[^\d]'), '');
  if (normalized.length <= 2) return '+$normalized';
  return '+${normalized.substring(0, 2)} ${normalized.substring(2)}';
}

bool _isValidWrytteId(String value) {
  final digits = value.replaceAll(RegExp(r'[^\d]'), '');
  final bodyLength = digits.startsWith('00') ? digits.length - 2 : 0;
  return bodyLength >= 8 && bodyLength <= 12;
}

// ─────────────────────────────────────────────────────────────────
// Enum for the three possible lookup states
// ─────────────────────────────────────────────────────────────────
enum _LookupState { idle, found, duplicate, notFound, error }

enum _UnregisteredWrytteSaveChoice { saveAndInvite, saveOnly }

class NewContactPage extends StatefulWidget {
  /// Bearer token for the UserSearchService call.
  final String token;
  final String? initialIdentifier;
  final String? initialWrytteUserId;
  final String? initialName;
  final String? initialBio;
  final bool readOnlyIdentifier;

  const NewContactPage({
    super.key,
    required this.token,
    this.initialIdentifier,
    this.initialWrytteUserId,
    this.initialName,
    this.initialBio,
    this.readOnlyIdentifier = false,
  });

  @override
  State<NewContactPage> createState() => _NewContactPageState();
}

class _NewContactPageState extends State<NewContactPage> {
  bool get _isIdentityResolved => widget.readOnlyIdentifier;

  // ── Controllers & focus ──────────────────────────────────────
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _numberCtrl = TextEditingController();

  final _codeFocusNode = FocusNode();
  final _numberFocusNode = FocusNode();
  final _firstNameFocusNode = FocusNode();

  // ── Country ───────────────────────────────────────────────────
  CountryId? _selectedCountry;
  bool _showDivider = false;
  bool _isAutoFilling = false;
  bool _hasInvalidCountryCode = false;
  bool _isWrytteIdInput = false;

  // ── Sync toggle ───────────────────────────────────────────────
  bool _syncToPhone = true;

  // ── Lookup ────────────────────────────────────────────────────
  final UserSearchService _searchService = UserSearchService();
  final ContactService _contactService = ContactService();
  Future<List<Contact>>? _existingContactsFuture;
  Timer? _debounce;
  _LookupState _lookupState = _LookupState.idle;
  Contact? _duplicateContact;

  /// The wrytteUserId returned by the lookup — needed for addFriend.
  String? _resolvedUserId;
  ContactUserProfile1? _lookupProfile1;
  bool _isRegisteredOnWrytte = false;
  String? _lookupError;

  // ── Saving ────────────────────────────────────────────────────
  bool _isSaving = false;
  String? _saveError;

  // ─────────────────────────────────────────────────────────────
  // Computed helpers
  // ─────────────────────────────────────────────────────────────
  bool get _isWrytteIdMode =>
      _isWrytteIdInput || _selectedCountry?.isoCode == 'WID';

  String _callingCode(CountryId country) {
    final metadataCode = CountryPhoneNumber.callingCodeForRegion(
      country.isoCode,
    );
    return metadataCode.isEmpty ? country.dialCode : metadataCode;
  }

  String get _wrytteIdDigits {
    final digits = _phoneDigits;
    return '00$digits';
  }

  String get _fullIdentifier {
    if (_selectedCountry == null) return '';
    final raw = _numberCtrl.text.trim();
    if (_isWrytteIdMode) return _wrytteIdDigits;
    return CountryPhoneNumber.international(raw, _selectedCountry!.isoCode) ??
        '';
  }

  String get _resolvedIdentifierDisplay {
    final formatted =
        InternationalPhoneNumberInputFormatter()
            .formatEditUpdate(
              const TextEditingValue(),
              TextEditingValue(text: _fullIdentifier),
            )
            .text;
    return formatted.startsWith('+') ? formatted : '+$formatted';
  }

  bool get _hasContactName =>
      _firstNameCtrl.text.trim().isNotEmpty ||
      _lastNameCtrl.text.trim().isNotEmpty;

  bool get _canSave {
    if (!_hasContactName) return false;
    if (_numberCtrl.text.trim().isEmpty) return false;
    if (_isWrytteIdMode) {
      if (!_isValidWrytteId(_fullIdentifier)) return false;
      final canSaveUnregisteredId =
          !_isRegisteredOnWrytte && _lookupState == _LookupState.notFound;
      if (canSaveUnregisteredId) return true;
      final canSaveRegisteredId =
          _isRegisteredOnWrytte &&
          (_resolvedUserId?.trim().isNotEmpty ?? false) &&
          _isValidWrytteId(_fullIdentifier);
      return canSaveRegisteredId &&
          (_lookupState == _LookupState.found ||
              _lookupState == _LookupState.duplicate);
    }
    return _hasInvalidCountryCode ||
        (_selectedCountry != null && _fullIdentifier.isNotEmpty);
  }

  String get _phoneDigits => _numberCtrl.text.replaceAll(RegExp(r'[^\d]'), '');

  // ─────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _prefillInitialContact();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_firstNameCtrl.text.isNotEmpty) {
        _firstNameCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: _firstNameCtrl.text.length),
        );
      }
      if (widget.readOnlyIdentifier) {
        _firstNameFocusNode.requestFocus();
      } else {
        _onCodeFieldTap();
        _codeFocusNode.requestFocus();
      }
    });
    _numberCtrl.addListener(_onNumberChanged);
    _firstNameCtrl.addListener(() => setState(() {}));
  }

  void _prefillInitialContact() {
    final identifier = widget.initialIdentifier?.trim() ?? '';
    final wrytteUserId = widget.initialWrytteUserId?.trim() ?? '';
    final initialName = widget.initialName?.trim() ?? '';
    if (initialName.isNotEmpty) {
      _firstNameCtrl.text = initialName;
    }
    if (identifier.isEmpty && wrytteUserId.isEmpty) return;

    if (wrytteUserId.isNotEmpty) {
      _resolvedUserId = wrytteUserId;
      _isRegisteredOnWrytte = true;
      _lookupState = _LookupState.found;
    }

    if (identifier.isEmpty) return;
    final identifierDigits = identifier.replaceAll(RegExp(r'[^\d]'), '');
    if (!identifierDigits.startsWith('00') && _prefillPhone(identifier)) {
      return;
    }

    const wrytteMode = wryptteId;
    _selectedCountry = wrytteMode;
    _isWrytteIdInput = true;
    final body =
        identifierDigits.startsWith('00')
            ? identifierDigits.substring(2)
            : identifierDigits;
    _codeCtrl.text = _formatWrytteIdInput('00$body');
    _numberCtrl.text = _formatWrytteIdBody(body);
    _showDivider = true;
  }

  bool _prefillPhone(String identifier) {
    final digits = identifier.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length < 7) return false;

    final matches =
        countriesId
            .where((country) => digits.startsWith(country.dialCode))
            .toList()
          ..sort((a, b) => b.dialCode.length.compareTo(a.dialCode.length));
    if (matches.isEmpty) return false;

    final country = matches.first;
    var national = digits.substring(country.dialCode.length);
    if (national.isEmpty) return false;
    while (national.startsWith('0') && national.length > 1) {
      national = national.substring(1);
    }

    _selectedCountry = country;
    _codeCtrl.text = '+${country.dialCode}';
    _numberCtrl.text = CountryPhoneNumber.formatNational(
      national,
      country.isoCode,
    );
    _showDivider = true;
    return true;
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _codeCtrl.dispose();
    _numberCtrl.dispose();
    _codeFocusNode.dispose();
    _numberFocusNode.dispose();
    _firstNameFocusNode.dispose();
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
      final selectedWrytteId = result.isoCode == 'WID';
      final clearExistingNumber = _isWrytteIdMode != selectedWrytteId;
      setState(() {
        _selectedCountry = result;
        _isWrytteIdInput = selectedWrytteId;
        _hasInvalidCountryCode = false;
        _codeCtrl.text = '+${result.dialCode}';
        _showDivider = true;
        _lookupState = _LookupState.idle;
        _duplicateContact = null;
        _resolvedUserId = null;
        _lookupProfile1 = null;
        _isRegisteredOnWrytte = false;
        _lookupError = null;
        _saveError = null;
      });
      if (clearExistingNumber) _numberCtrl.clear();
      _numberFocusNode.requestFocus();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Auto-detect country from typed code
  // ─────────────────────────────────────────────────────────────
  void _detectCountryFromCode(String value) {
    if (_isAutoFilling) return;

    final incomingSelection = _codeCtrl.selection;
    final digitsOnly = value.replaceAll(RegExp(r'[^\d]'), '');
    if (!value.startsWith('+') || value != '+$digitsOnly') {
      _codeCtrl.text = '+$digitsOnly';
      _codeCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _codeCtrl.text.length),
      );
    }

    // Like sign-in, a leading zero switches immediately to Wrytte ID mode.
    // Keep the entire Wrytte ID in this same field while typing and deleting.
    if (digitsOnly.startsWith('0')) {
      final body = digitsOnly.startsWith('00') ? digitsOnly.substring(2) : '';
      const wrytteMode = wryptteId;
      final combinedValue = _formatWrytteIdInput(digitsOnly);
      final rawCaretOffset =
          incomingSelection.extentOffset.clamp(0, value.length).toInt();
      final digitsBeforeCaret =
          value
              .substring(0, rawCaretOffset)
              .replaceAll(RegExp(r'[^\d]'), '')
              .length;
      final caretOffset =
          (digitsBeforeCaret + 1 + (digitsBeforeCaret > 2 ? 1 : 0))
              .clamp(1, combinedValue.length)
              .toInt();
      _debounce?.cancel();
      setState(() {
        _isWrytteIdInput = true;
        _selectedCountry = wrytteMode;
        _hasInvalidCountryCode = false;
        _showDivider = false;
        _lookupState = _LookupState.idle;
        _duplicateContact = null;
        _resolvedUserId = null;
        _isRegisteredOnWrytte = false;
        _lookupError = null;
        _saveError = null;
        _codeCtrl.value = TextEditingValue(
          text: combinedValue,
          selection: TextSelection.collapsed(offset: caretOffset),
        );
      });
      _numberCtrl.text = _formatWrytteIdBody(body);
      return;
    }

    final codeWithoutPlus = digitsOnly;
    final phoneCountries =
        countriesId.where((country) => country.isoCode != 'WID').toList();
    final exactMatches =
        phoneCountries
            .where((country) => _callingCode(country) == codeWithoutPlus)
            .toList()
          ..sort((a, b) {
            final aCanonical = a.dialCode == codeWithoutPlus ? 0 : 1;
            final bCanonical = b.dialCode == codeWithoutPlus ? 0 : 1;
            return aCanonical.compareTo(bCanonical);
          });
    final couldBeLongerCode = phoneCountries.any(
      (country) =>
          _callingCode(country).length > codeWithoutPlus.length &&
          _callingCode(country).startsWith(codeWithoutPlus),
    );

    CountryId? detectedCountry;
    String? nationalDigitsFromCode;
    var moveCaretToPhone = false;
    if (exactMatches.isNotEmpty) {
      detectedCountry = exactMatches.first;
      moveCaretToPhone = !couldBeLongerCode;
    } else if (codeWithoutPlus.isNotEmpty && !couldBeLongerCode) {
      final shorterCodeMatches =
          phoneCountries
              .where(
                (country) => codeWithoutPlus.startsWith(_callingCode(country)),
              )
              .toList()
            ..sort(
              (a, b) =>
                  _callingCode(b).length.compareTo(_callingCode(a).length),
            );
      if (shorterCodeMatches.isNotEmpty) {
        detectedCountry = shorterCodeMatches.first;
        nationalDigitsFromCode = codeWithoutPlus.substring(
          _callingCode(detectedCountry).length,
        );
        moveCaretToPhone = true;
      }
    }

    final isPossibleCodePrefix =
        codeWithoutPlus.isEmpty ||
        phoneCountries.any(
          (country) => _callingCode(country).startsWith(codeWithoutPlus),
        );

    _debounce?.cancel();
    setState(() {
      _isWrytteIdInput = false;
      _selectedCountry = detectedCountry;
      _hasInvalidCountryCode =
          codeWithoutPlus.isNotEmpty &&
          detectedCountry == null &&
          !isPossibleCodePrefix;
      _showDivider = detectedCountry != null;
      _lookupState = _LookupState.idle;
      _duplicateContact = null;
      _resolvedUserId = null;
      _lookupProfile1 = null;
      _isRegisteredOnWrytte = false;
      _lookupError = null;
      _saveError = null;
      if (detectedCountry != null && nationalDigitsFromCode != null) {
        _codeCtrl.value = TextEditingValue(
          text: '+${_callingCode(detectedCountry)}',
          selection: TextSelection.collapsed(
            offset: _callingCode(detectedCountry).length + 1,
          ),
        );
      }
    });

    if (detectedCountry != null && nationalDigitsFromCode != null) {
      _numberCtrl.text = nationalDigitsFromCode;
    } else if (detectedCountry == null && _numberCtrl.text.isNotEmpty) {
      _numberCtrl.clear();
    }

    if (detectedCountry != null && moveCaretToPhone && !_isAutoFilling) {
      _isAutoFilling = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        _numberFocusNode.requestFocus();
        _isAutoFilling = false;
      });
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
      _duplicateContact = null;
      _resolvedUserId = null;
      _lookupProfile1 = null;
      _isRegisteredOnWrytte = false;
      _lookupError = null;
      _saveError = null;
    });

    _debounce?.cancel();

    final digits = _phoneDigits;
    if (_selectedCountry == null) return;
    if (_isWrytteIdMode) {
      if (digits.length < _kMinPhoneLookupDigits ||
          digits.length > 12 ||
          !_isValidWrytteId(_fullIdentifier)) {
        return;
      }
    } else if (digits.length < _kMinPhoneLookupDigits ||
        digits.length > _kMaxPhoneLookupDigits) {
      return;
    }

    _debounce = Timer(
      _isWrytteIdMode ? _kWrytteIdLookupDebounce : _kPhoneLookupDebounce,
      _lookupUser,
    );
  }

  Future<void> _lookupUser() async {
    debugPrint('🔍 _lookupUser called, identifier: $_fullIdentifier');
    final identifier = _fullIdentifier;
    if (identifier.isEmpty) return;
    if (!_isWrytteIdMode &&
        (_phoneDigits.length < _kMinPhoneLookupDigits ||
            _phoneDigits.length > _kMaxPhoneLookupDigits)) {
      return;
    }
    if (_isWrytteIdMode &&
        (_phoneDigits.length < _kMinPhoneLookupDigits ||
            _phoneDigits.length > 12 ||
            !_isValidWrytteId(identifier))) {
      return;
    }

    try {
      if (!_isWrytteIdMode) {
        final existingContact = await _findExistingContact(identifier);
        if (!mounted || _fullIdentifier != identifier) return;
        if (existingContact != null) {
          _firstNameFocusNode.requestFocus();
          setState(() {
            _lookupState = _LookupState.duplicate;
            _duplicateContact = existingContact;
            _resolvedUserId = existingContact.wrytteUserId;
            _isRegisteredOnWrytte = existingContact.isOnWrytte;
            _lookupError = null;
          });
          return;
        }
      }

      final Map<String, String> result;

      if (_isWrytteIdMode) {
        final userId = await _searchWrytteId(identifier);
        result = userId == null ? {} : {identifier: userId};
      } else {
        final freshToken =
            await AuthService.instance.getMatrixAccessToken() ?? widget.token;
        result = await _searchService.searchUsersByPhones(
          phoneNumbersA: [identifier],
          token: freshToken,
        );
      }

      debugPrint('Lookup result keys: ${result.keys.toList()}');
      debugPrint('Looking for identifier: $identifier');

      if (!mounted) return;
      // A slower request for an older partial number must not overwrite the
      // result for the number currently visible in the field.
      if (_fullIdentifier != identifier) return;

      final lookupValue =
          result[identifier] ??
          result[_normalizeIdentifier(identifier)] ??
          result[_digitsOnly(identifier)];

      if (lookupValue != null && lookupValue.isNotEmpty) {
        final matrixUserId =
            lookupValue == UserSearchService.registeredWithoutMatrixId
                ? null
                : lookupValue;
        if (_isWrytteIdMode && matrixUserId != null) {
          final savedContact = await _findSavedWrytteContact(matrixUserId);
          if (!mounted || _fullIdentifier != identifier) return;
          if (savedContact != null) {
            _firstNameFocusNode.requestFocus();
            setState(() {
              _lookupState = _LookupState.duplicate;
              _duplicateContact = savedContact;
              _resolvedUserId = matrixUserId;
              _lookupProfile1 = null;
              _isRegisteredOnWrytte = true;
              _lookupError = null;
            });
            return;
          }

          // Lock the identifier as soon as Wrytte confirms it. Loading the
          // optional profile details below can take longer and must not leave
          // the verified ID editable during that request.
          _firstNameFocusNode.requestFocus();
          setState(() {
            _lookupState = _LookupState.found;
            _duplicateContact = null;
            _resolvedUserId = matrixUserId;
            _lookupProfile1 = null;
            _isRegisteredOnWrytte = true;
            _lookupError = null;
          });

          final profile = await UserProfileService.instance.getProfileByUid(
            matrixUserId,
            phone: identifier,
            forceRefresh: true,
          );
          if (!mounted || _fullIdentifier != identifier) return;
          final profile1 =
              profile == null
                  ? null
                  : ContactUserProfile1.fromBackendProfile(
                    matrixUserId,
                    profile,
                    fallbackPhone: identifier,
                  );
          if (profile1 != null) {
            unawaited(AvatarPreloadService.warm(profile1.avatarUrl));
            final owner = await AuthService.instance.getCurrentUserId() ?? '';
            await ContactIdentityCache.instance.upsert(
              ownerUserId: owner,
              matrixUserId: matrixUserId,
              phone: profile1.phone,
              profileName: profile1.displayName,
              avatarUrl: profile1.avatarUrl,
              bio: profile1.bio,
            );
            if (!mounted || _fullIdentifier != identifier) return;
            setState(() {
              _lookupProfile1 = profile1;
            });
          }
          return;
        }
        _firstNameFocusNode.requestFocus();
        setState(() {
          _lookupState = _LookupState.found;
          _resolvedUserId = matrixUserId;
          _lookupProfile1 = null;
          _isRegisteredOnWrytte = true;
          _lookupError = null;
        });
      } else {
        setState(() {
          _lookupState = _LookupState.notFound;
          _resolvedUserId = null;
          _lookupProfile1 = null;
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

  Future<Contact?> _findSavedWrytteContact(String matrixUserId) async {
    final owner = await AuthService.instance.getCurrentUserId() ?? '';
    if (owner.isEmpty) return null;
    final targetId =
        (_matrixLocalpart(matrixUserId) ?? matrixUserId).toLowerCase();

    final savedContacts = await ContactLocalDb.loadSavedContacts(
      ownerUserId: owner,
    );
    for (final contact in savedContacts) {
      final contactId = contact.wrytteUserId?.trim() ?? '';
      if (contactId.isNotEmpty &&
          (_matrixLocalpart(contactId) ?? contactId).toLowerCase() ==
              targetId) {
        return contact;
      }
    }

    final identity = await ContactIdentityCache.instance.findByMatrixId(
      ownerUserId: owner,
      matrixUserId: matrixUserId,
    );
    final savedName = identity?.savedName?.trim() ?? '';
    if (identity == null || savedName.isEmpty) return null;
    return Contact(
      displayName: savedName,
      phones: [
        if (identity.phone?.trim().isNotEmpty == true) identity.phone!.trim(),
      ],
      avatarUrl: identity.avatarUrl,
      bio: identity.bio,
      isOnWrytte: true,
      wrytteUserId: identity.matrixUserId,
      isSaved: true,
    );
  }

  Future<Contact?> _findExistingContact(String identifier) async {
    _existingContactsFuture ??= _loadExistingContacts();
    final contacts = await _existingContactsFuture!;
    final selectedIsoCode = _selectedCountry?.isoCode;
    if (selectedIsoCode == null) return null;

    for (final contact in contacts) {
      for (final phone in contact.phones) {
        if (_phonesMatch(phone, identifier, selectedIsoCode)) {
          debugPrint(
            '[NewContact.lookup] local contact match '
            'name="${contact.formattedName}" phone="$phone"',
          );
          return contact;
        }
      }
    }
    debugPrint(
      '[NewContact.lookup] no local match for "$identifier" '
      'across ${contacts.length} contacts',
    );
    return null;
  }

  bool _phonesMatch(String storedPhone, String identifier, String isoCode) {
    final candidate = storedPhone.trim();
    final targetDigits = _digitsOnly(identifier);
    final candidateDigits = _digitsOnly(candidate);
    if (candidateDigits.isEmpty || targetDigits.isEmpty) return false;

    // Stored Wrytte contacts are canonical E.164 numbers. Comparing their
    // digits first avoids rejecting an exact match because of punctuation.
    if (candidateDigits == targetDigits) return true;

    final international = CountryPhoneNumber.international(candidate, isoCode);
    if (international != null && _digitsOnly(international) == targetDigits) {
      return true;
    }

    // The device-contact service preserves local entries with a synthetic
    // leading '+'. Reparse their digits as a national number for the selected
    // country (for example +3107353765 entered locally in a US contact).
    final national = CountryPhoneNumber.international(candidateDigits, isoCode);
    return national != null && _digitsOnly(national) == targetDigits;
  }

  Future<List<Contact>> _loadExistingContacts() async {
    final contacts = <Contact>[];
    final owner = await AuthService.instance.getCurrentUserId() ?? '';

    // Read the local saved-contact database directly. The merged cache can be
    // briefly stale immediately after a contact is created.
    if (owner.isNotEmpty) {
      try {
        contacts.addAll(
          await ContactLocalDb.loadSavedContacts(ownerUserId: owner),
        );
      } catch (e) {
        debugPrint('[NewContact.lookup] local saved contacts unavailable: $e');
      }

      // Profile 2 identities are also a local saved-contact source. Backend
      // contact rows may contain only a user ID while the hydrated phone is
      // stored here and used by chat/profile surfaces.
      try {
        final identities = await ContactIdentityCache.instance.loadAll(
          ownerUserId: owner,
        );
        contacts.addAll(
          identities.values
              .where(
                (identity) =>
                    identity.savedName?.trim().isNotEmpty == true &&
                    identity.phone?.trim().isNotEmpty == true,
              )
              .map(
                (identity) => Contact(
                  displayName: identity.savedName,
                  phones: [identity.phone!.trim()],
                  isOnWrytte: true,
                  wrytteUserId: identity.matrixUserId,
                  isSaved: true,
                ),
              ),
        );
      } catch (e) {
        debugPrint('[NewContact.lookup] saved identities unavailable: $e');
      }
    }

    try {
      contacts.addAll(await _contactService.getDeviceContacts());
    } catch (e) {
      debugPrint('[NewContact.lookup] device contacts unavailable: $e');
    }

    if (owner.isNotEmpty) {
      try {
        contacts.addAll(await _contactService.getMatrixContactsCached(owner));
      } catch (e) {
        debugPrint('[NewContact.lookup] saved contacts unavailable: $e');
      }
    }
    return contacts;
  }

  // ─────────────────────────────────────────────────────────────
  // Save — now fully wired to Matrix + device contacts
  // ─────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_canSave || _isSaving) return;
    if (_hasInvalidCountryCode || _selectedCountry == null) {
      await _showInvalidCountryCodeDialog();
      return;
    }

    if (_isWrytteIdMode && _lookupState == _LookupState.notFound) {
      final choice = await _showUnregisteredWrytteDialog();
      if (choice == null || !mounted) return;
      await _saveUnregisteredWrytte(
        saveAndInvite: choice == _UnregisteredWrytteSaveChoice.saveAndInvite,
      );
      return;
    }

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      final String selfId = await AuthService.instance.getCurrentUserId() ?? '';
      apkLog('NewContact.save', 'save tapped self="$selfId"');

      final receiverId =
          (await _resolveReceiverIdForSave(widget.token))?.trim() ?? '';

      if (_isWrytteIdMode && receiverId.isEmpty) {
        setState(() {
          _isSaving = false;
          _lookupState = _LookupState.notFound;
          _isRegisteredOnWrytte = false;
          _resolvedUserId = null;
        });
        return;
      }

      if (_matrixLocalpart(receiverId) == selfId) {
        throw StateError(
          'You cannot add your own Wrytte account as a contact.',
        );
      }
      if (_isRegisteredOnWrytte && receiverId.isEmpty) {
        throw StateError(
          'This Wrytte contact has no Matrix user ID yet. Try again shortly.',
        );
      }

      final firstName = _firstNameCtrl.text.trim();
      final lastName = _lastNameCtrl.text.trim();
      final contactName = _displayName(firstName, lastName, _fullIdentifier);

      if (_duplicateContact != null) {
        final existing = _duplicateContact!;
        final savedRoomId = existing.directRoomId?.trim() ?? '';
        String? conversationId =
            savedRoomId.startsWith('!') ? savedRoomId : null;
        if (receiverId.isNotEmpty && conversationId == null) {
          conversationId = await ChatService().getMatrixConversationId(
            receiverId,
          );
          if (conversationId == null || !conversationId.startsWith('!')) {
            throw StateError(
              'Could not create a private chat with this contact. Try again.',
            );
          }
        }
        final renamedContact = existing.copyWith(
          displayName: contactName,
          firstName: firstName,
          lastName: lastName,
          directRoomId: conversationId ?? existing.directRoomId,
          isOnWrytte: existing.isOnWrytte || receiverId.isNotEmpty,
          wrytteUserId:
              receiverId.isNotEmpty ? receiverId : existing.wrytteUserId,
          isSaved: true,
        );
        await ContactLocalDb.addContact(renamedContact, ownerUserId: selfId);
        if (receiverId.isNotEmpty) {
          await ContactIdentityCache.instance.upsert(
            ownerUserId: selfId,
            matrixUserId: receiverId,
            phone: renamedContact.primaryPhone,
            savedName: contactName,
            avatarUrl: renamedContact.avatarUrl,
            bio: renamedContact.bio,
          );
          await _saveContactToBackendOrThrow(
            selfId: selfId,
            receiverId: receiverId,
            contact: renamedContact,
          );
        }
        await ChatService().applySavedContact(renamedContact);
        ContactService.notifyContactsChanged(selfId);
        ContactService.invalidateMatrixContactsCache();
        _contactService.invalidateCache();
        if (mounted) Navigator.pop(context);
        return;
      }

      final backendContactProfile =
          receiverId.isEmpty
              ? null
              : _lookupProfile1 != null && _lookupProfile1!.userId == receiverId
              ? await UserProfileService.instance.getProfileByUid(
                receiverId,
                phone: _fullIdentifier,
                forceRefresh: false,
              )
              : await UserProfileService.instance.getProfileByUid(
                receiverId,
                phone: _fullIdentifier,
                forceRefresh: true,
              );
      final contactUserProfile1 =
          backendContactProfile == null
              ? null
              : ContactUserProfile1.fromBackendProfile(
                receiverId,
                backendContactProfile,
                fallbackPhone: _fullIdentifier,
              );
      final profileOneName = _cleanProfileName(
        contactUserProfile1?.displayName,
      );
      final profileOnePhone =
          contactUserProfile1?.phone.trim().isNotEmpty == true
              ? contactUserProfile1!.phone.trim()
              : _fullIdentifier;
      final profileOneAvatar = contactUserProfile1?.avatarUrl;
      final profileOneBio = contactUserProfile1?.bio ?? widget.initialBio;
      unawaited(AvatarPreloadService.warm(profileOneAvatar));

      // Establish the direct room before persisting the contact to account
      // data, so the saved contact record includes the room ID.
      final String? conversationId;
      if (receiverId.isNotEmpty) {
        conversationId = await ChatService().getMatrixConversationId(
          receiverId,
        );
        if (conversationId == null || !conversationId.startsWith('!')) {
          throw StateError(
            'Could not create a private chat with this contact. Try again.',
          );
        }
      } else {
        conversationId = null;
      }

      final contactUserProfile2 = ContactUserProfile2.fromSavedContact(
        savedDisplayName: contactName,
        typedPhone: _fullIdentifier,
        isOnWrytte: _isRegisteredOnWrytte || receiverId.isNotEmpty,
        firstName: firstName,
        lastName: lastName,
        wrytteUserId: receiverId.isEmpty ? null : receiverId,
        contactUserProfile1: contactUserProfile1,
      );

      // Save ContactUserProfile2 locally before syncing its server account data.
      final localContact = contactUserProfile2.toContact().copyWith(
        directRoomId: conversationId,
      );
      await ContactLocalDb.addContact(localContact, ownerUserId: selfId);
      ContactService.notifyContactsChanged(selfId);
      apkLog(
        'NewContact.save',
        'local contact save done owner="$selfId" name="${localContact.formattedName}" wrytteUserId="${localContact.wrytteUserId}" phone="${localContact.primaryPhone}"',
      );
      if (receiverId.isNotEmpty) {
        await ContactIdentityCache.instance.upsert(
          ownerUserId: selfId,
          matrixUserId: receiverId,
          phone: profileOnePhone,
          profileName:
              profileOneName.isNotEmpty ? profileOneName : widget.initialName,
          savedName: contactName,
          avatarUrl: profileOneAvatar,
          bio: profileOneBio,
        );
      }
      await ChatService().applySavedContact(localContact);
      ContactService.invalidateMatrixContactsCache();
      _contactService.invalidateCache();

      // A number that is not registered on Wrytte has no user ID and cannot
      // be stored by the backend or used to create a Matrix DM. It is still a
      // valid local phone contact, so finish successfully after local save.
      if (receiverId.isEmpty) {
        if (!mounted) return;
        Navigator.pop(context);
        return;
      }

      await _saveContactToBackendOrThrow(
        selfId: selfId,
        receiverId: receiverId,
        contact: localContact,
      );
      final directRoomId = conversationId!;
      apkLog(
        'NewContact.save',
        'direct room ready conversation_id="$directRoomId" receiver="$receiverId"',
      );

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder:
              (_, __, ___) => ChatScreen(
                conversationId: directRoomId,
                receiverId:
                    receiverId.isNotEmpty ? receiverId : _fullIdentifier,
                currentUserId: selfId,
                title: contactName,
                avatarUrl: profileOneAvatar,
                conversationKind: ConversationKind.direct,
              ),
          transitionsBuilder: (_, animation, __, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
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

  Future<_UnregisteredWrytteSaveChoice?> _showUnregisteredWrytteDialog() {
    return showDialog<_UnregisteredWrytteSaveChoice>(
      context: context,
      builder:
          (dialogContext) => Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 28,
              vertical: 20,
            ),
            backgroundColor: _kBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: const BorderSide(color: Colors.white24),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This Wrytte ID is not on Wrytte',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'You can save this contact locally and invite them to Wrytte.',
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed:
                          () => Navigator.pop(
                            dialogContext,
                            _UnregisteredWrytteSaveChoice.saveAndInvite,
                          ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: const StadiumBorder(),
                      ),
                      child: const Text('Save and invite'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _unregisteredDialogButton(
                    dialogContext,
                    label: 'Save',
                    result: _UnregisteredWrytteSaveChoice.saveOnly,
                  ),
                  const SizedBox(height: 8),
                  _unregisteredDialogButton(
                    dialogContext,
                    label: 'Cancel',
                    result: null,
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Widget _unregisteredDialogButton(
    BuildContext dialogContext, {
    required String label,
    required _UnregisteredWrytteSaveChoice? result,
  }) {
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: () => Navigator.pop(dialogContext, result),
        style: TextButton.styleFrom(
          backgroundColor: _kCard,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: const StadiumBorder(),
        ),
        child: Text(label),
      ),
    );
  }

  Future<void> _saveUnregisteredWrytte({required bool saveAndInvite}) async {
    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      final firstName = _firstNameCtrl.text.trim();
      final lastName = _lastNameCtrl.text.trim();
      final name = _displayName(firstName, lastName, _fullIdentifier);

      // An unregistered Wrytte ID invited from this flow belongs only in the
      // device address book. Do not create a Wrytte Profile 2 or write it to
      // Matrix account data, where it would appear in the app's contacts.
      if (saveAndInvite) {
        await _saveUnregisteredContactToPhone(
          firstName: firstName,
          lastName: lastName,
          displayName: name,
        );
        if (!mounted) return;
        Navigator.pop(context);
        return;
      }

      final owner = await AuthService.instance.getCurrentUserId() ?? '';
      if (owner.isEmpty) {
        throw StateError('Cannot save contact without a signed-in user.');
      }

      if (_syncToPhone) {
        await _saveUnregisteredContactToPhone(
          firstName: firstName,
          lastName: lastName,
          displayName: name,
        );
      }

      final profile2 = ContactUserProfile2.fromSavedContact(
        savedDisplayName: name,
        typedPhone: _fullIdentifier,
        isOnWrytte: false,
        firstName: firstName,
        lastName: lastName,
      );
      final contact = profile2.toContact();
      await ContactLocalDb.addContact(contact, ownerUserId: owner);
      ContactService.notifyContactsChanged(owner);
      ContactService.invalidateMatrixContactsCache();
      _contactService.invalidateCache();

      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveError = _friendlyError(error.toString());
      });
    }
  }

  Future<void> _saveUnregisteredContactToPhone({
    required String firstName,
    required String lastName,
    required String displayName,
  }) async {
    if (!await _contactService.requestContactsPermission()) {
      throw StateError('Phone contacts permission denied.');
    }

    final digits = _digitsOnly(_fullIdentifier);
    // Avoid reading the entire address book just to check for duplicates: on
    // devices with many contacts that can leave Save and invite appearing
    // stuck. Insert directly and return as soon as the platform confirms it.
    await fc.FlutterContacts.insertContact(
      fc.Contact(
        displayName: displayName,
        name: fc.Name(first: firstName, last: lastName),
        phones: [fc.Phone('+$digits')],
      ),
    );
  }

  Future<void> _showInvalidCountryCodeDialog() async {
    final code = _codeCtrl.text.replaceAll(RegExp(r'[^\d]'), '');
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => Dialog(
            backgroundColor: _kCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Text(
                    'Country code +$code is invalid. Please correct it.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
                const Divider(height: 1, color: _kDivider),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('OK'),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  /// Uses the authoritative Wrytte-ID endpoint used by sign-in. The phone
  /// directory endpoint normalizes `00…` into an E.164 phone number, which
  /// cannot match the backend's canonical `W…` account identifier.
  Future<String?> _searchWrytteId(String identifier) async {
    final digits = _digitsOnly(identifier);
    final search = await AuthService.instance.searchWrytteIdForSignIn(digits);
    if (!search.exists) return null;

    final userId = search.userId.trim();
    if (userId.isEmpty) return null;
    final matrixUserId = search.matrixUserId.trim();
    if (matrixUserId.startsWith('@') && matrixUserId.contains(':')) {
      return matrixUserId;
    }
    if (userId.startsWith('@') && userId.contains(':')) return userId;

    final localpart = userId.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
    if (localpart.isEmpty) return null;
    return '@$localpart:${MatrixConfig.serverName}';
  }

  Future<String?> _resolveReceiverIdForSave(String fallbackToken) async {
    final existing = _resolvedUserId?.trim();
    if (existing != null && existing.isNotEmpty) return existing;

    final identifier = _fullIdentifier;
    if (identifier.isEmpty) return null;
    if (!_isWrytteIdMode && _phoneDigits.length < _kMinPhoneLookupDigits) {
      return null;
    }
    if (!_isWrytteIdMode && _phoneDigits.length > _kMaxPhoneLookupDigits) {
      return null;
    }
    if (_isWrytteIdMode &&
        (_phoneDigits.length < _kMinPhoneLookupDigits ||
            _phoneDigits.length > 12 ||
            !_isValidWrytteId(identifier))) {
      return null;
    }

    apkLog(
      'NewContact.lookup',
      'save forcing final lookup identifier="$identifier" state=$_lookupState',
    );

    try {
      final Map<String, String> result;
      if (_isWrytteIdMode) {
        final userId = await _searchWrytteId(identifier);
        result = userId == null ? {} : {identifier: userId};
      } else {
        final freshToken =
            await AuthService.instance.getMatrixAccessToken() ?? fallbackToken;
        result = await _searchService.searchUsersByPhones(
          phoneNumbersA: [identifier],
          token: freshToken,
        );
      }

      final lookupValue =
          result[identifier] ??
          result[_normalizeIdentifier(identifier)] ??
          result[_digitsOnly(identifier)];

      final matrixUserId =
          lookupValue == UserSearchService.registeredWithoutMatrixId
              ? null
              : lookupValue?.trim();

      if (mounted) {
        setState(() {
          _lookupState =
              lookupValue != null && lookupValue.isNotEmpty
                  ? _LookupState.found
                  : _LookupState.notFound;
          _resolvedUserId =
              matrixUserId == null || matrixUserId.isEmpty
                  ? null
                  : matrixUserId;
          _isRegisteredOnWrytte = lookupValue != null && lookupValue.isNotEmpty;
          _lookupError = null;
        });
      } else {
        _resolvedUserId =
            matrixUserId == null || matrixUserId.isEmpty ? null : matrixUserId;
        _isRegisteredOnWrytte = lookupValue != null && lookupValue.isNotEmpty;
      }

      apkLog(
        'NewContact.lookup',
        'save final lookup resolved="$matrixUserId" registered=$_isRegisteredOnWrytte',
      );
      return matrixUserId == null || matrixUserId.isEmpty ? null : matrixUserId;
    } catch (e) {
      apkLog('NewContact.lookup', 'save final lookup FAILED error="$e"');
      return existing;
    }
  }

  Future<void> _saveContactToBackendOrThrow({
    required String selfId,
    required String receiverId,
    required Contact contact,
  }) async {
    apkLog(
      'NewContact.save',
      'backend contact save start self="$selfId" receiver="$receiverId"',
    );

    try {
      await _contactService.saveContactToBackend(
        ownerUserId: selfId,
        contact: contact,
      );
      apkLog(
        'NewContact.save',
        'backend contact save success name="${contact.formattedName}" wrytteUserId="${contact.wrytteUserId}" phone="${contact.primaryPhone}"',
      );
    } catch (e) {
      apkLog('NewContact.save', 'backend contact save FAILED error="$e"');
      rethrow;
    }
  }

  String _friendlyError(String raw) {
    if (raw.contains('M_FORBIDDEN') ||
        raw.toLowerCase().contains('account data for other users')) {
      return 'Wrytte could not save this contact to your account. Please try again.';
    }
    if (raw.toLowerCase().contains('own wrytte account')) {
      return 'You cannot add yourself as a contact.';
    }
    if (raw.contains('1201')) return 'You are already friends with this user.';
    if (raw.contains('permission')) return 'Phone contacts permission denied.';
    if (raw.contains('not authenticated')) {
      return 'Session expired — please log in again.';
    }
    if (raw.toLowerCase().contains('backend') ||
        raw.toLowerCase().contains('timeout')) {
      return 'Backend contact save failed. Check connection and try again.';
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

  String _displayName(String firstName, String lastName, String fallback) {
    final name = [
      firstName,
      lastName,
    ].where((part) => part.isNotEmpty).join(' ');
    if (name.isNotEmpty) return name;
    return fallback.trim().isNotEmpty ? fallback.trim() : 'Contact';
  }

  String _cleanProfileName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final lowered = trimmed.toLowerCase();
    if (lowered == 'user' || lowered == 'uder' || lowered == 'unknown') {
      return '';
    }
    final digits = trimmed.replaceAll(RegExp(r'[\s\-()+]'), '');
    if (RegExp(r'^\d{7,}$').hasMatch(digits)) return '';
    if (trimmed.startsWith('@') && trimmed.contains(':')) return '';
    return trimmed;
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

  Future<void> _openDuplicateContact() async {
    final contact = _duplicateContact;
    final userId = contact?.wrytteUserId?.trim() ?? '';
    FocusManager.instance.primaryFocus?.unfocus();

    // Keep the New Contact form underneath the profile so the user can return
    // and update the saved contact name.
    if (contact != null && userId.isNotEmpty) {
      final savedRoomId = contact.directRoomId?.trim() ?? '';
      final conversationId =
          savedRoomId.startsWith('!')
              ? savedRoomId
              : await ChatService().findMatrixConversationId(userId);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder:
              (_) => ProfileScreen(
                uid: userId,
                conversationId: conversationId,
                savedNameHint: contact.formattedName,
                initialAvatarUrl: contact.avatarUrl,
              ),
        ),
      );
      return;
    }

    // Device-only contacts do not have a Wrytte profile to open. Return to the
    // saved contact list where the matching entry is available.
    if (mounted) Navigator.of(context).pop();
  }

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
              const SizedBox(width: 6),
              const WrytteIdCheckmark(),
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
                ? 'This Wrytte ID is on Wrytte'
                : 'Phone number is on Wrytte',
            checkmark: true,
          ),
        );

      case _LookupState.duplicate:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 4,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                isWrytteId
                    ? 'This Wrytte ID is in your contacts.'
                    : 'This phone number is already in your contacts.',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              GestureDetector(
                onTap: _openDuplicateContact,
                child: const Text(
                  'View contact',
                  style: TextStyle(color: _kBlue, fontSize: 13),
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
                  ? statusRow('This Wrytte ID is not on Wrytte')
                  : Row(
                    children: [
                      const Text(
                        'Phone number is not on Wrytte. ',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      GestureDetector(
                        onTap: _copyInviteLink,
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
            child: Text(
              'Save',
              style: TextStyle(
                color: _canSave ? Colors.white : Colors.white38,
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
                      focusNode: _firstNameFocusNode,
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

              if (_isIdentityResolved)
                _Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _resolvedIdentifierDisplay,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
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
                        onTap:
                            _isIdentityResolved || _isWrytteIdMode
                                ? null
                                : _pickCountry,
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: _isWrytteIdMode ? 8 : 6,
                        ),
                        leading:
                            _isWrytteIdMode
                                ? Image.asset(
                                  'assets/images/wrytte_id_signup_icon_128.png',
                                  width: 27,
                                  height: 27,
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.high,
                                )
                                : null,
                        title: Text(
                          _hasInvalidCountryCode
                              ? 'Invalid country code'
                              : _isWrytteIdMode
                              ? 'Wrytte ID'
                              : _selectedCountry == null
                              ? 'Country'
                              : '${_selectedCountry!.flag} ${_selectedCountry!.name}',
                          style: TextStyle(
                            color:
                                _selectedCountry == null && !_isWrytteIdMode
                                    ? Colors.white38
                                    : Colors.white,
                            fontSize: 16,
                            fontWeight:
                                _selectedCountry != null || _isWrytteIdMode
                                    ? FontWeight.w500
                                    : FontWeight.normal,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: Colors.white54,
                          size: 22,
                        ),
                        minLeadingWidth: _isWrytteIdMode ? 27 : null,
                        horizontalTitleGap: _isWrytteIdMode ? 10 : null,
                      ),

                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Divider(color: _kDivider, height: 1),
                      ),

                      // Wrytte IDs stay in one text field so backspace runs
                      // naturally through the prefix and the ID without moving
                      // the caret between separate fields.
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: _isWrytteIdMode ? 8 : 10,
                        ),
                        child: Row(
                          children: [
                            if (_isWrytteIdMode)
                              Expanded(
                                child: AbsorbPointer(
                                  absorbing: _isIdentityResolved,
                                  child: TextField(
                                    controller: _codeCtrl,
                                    focusNode: _codeFocusNode,
                                    readOnly: _isIdentityResolved,
                                    showCursor: !_isIdentityResolved,
                                    cursorOpacityAnimates: false,
                                    enableInteractiveSelection:
                                        !_isIdentityResolved,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.allow(
                                        RegExp(r'[+0-9 ]'),
                                      ),
                                    ],
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                    ),
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                    ),
                                    onChanged: _detectCountryFromCode,
                                    onTap:
                                        _isIdentityResolved
                                            ? null
                                            : _onCodeFieldTap,
                                  ),
                                ),
                              )
                            else ...[
                              // Phone country calling code.
                              SizedBox(
                                width: 68,
                                child: AbsorbPointer(
                                  absorbing: _isIdentityResolved,
                                  child: TextField(
                                    controller: _codeCtrl,
                                    focusNode: _codeFocusNode,
                                    readOnly: _isIdentityResolved,
                                    showCursor: !_isIdentityResolved,
                                    cursorOpacityAnimates: true,
                                    enableInteractiveSelection:
                                        !_isIdentityResolved,
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
                                    onChanged: _detectCountryFromCode,
                                    onTap:
                                        _isIdentityResolved
                                            ? null
                                            : _onCodeFieldTap,
                                  ),
                                ),
                              ),

                              // Blue divider between phone country code and number.
                              if (_showDivider)
                                Container(
                                  height: 22,
                                  width: 1,
                                  color: _kBlue,
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),

                              // Phone number field.
                              Expanded(
                                child: AbsorbPointer(
                                  absorbing: _isIdentityResolved,
                                  child: TextField(
                                    controller: _numberCtrl,
                                    focusNode: _numberFocusNode,
                                    readOnly: _isIdentityResolved,
                                    showCursor: !_isIdentityResolved,
                                    cursorOpacityAnimates: true,
                                    enableInteractiveSelection:
                                        !_isIdentityResolved,
                                    keyboardType: TextInputType.phone,
                                    inputFormatters: [
                                      if (_selectedCountry != null)
                                        CountryPhoneNumberInputFormatter(
                                          _selectedCountry!.isoCode,
                                        )
                                      else
                                        FilteringTextInputFormatter.digitsOnly,
                                    ],
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                    ),
                                    decoration: InputDecoration(
                                      hintText:
                                          _selectedCountry != null &&
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
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 8,
                                          ),
                                    ),
                                    enabled:
                                        _isIdentityResolved ||
                                        (_selectedCountry != null &&
                                            _showDivider),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Show lookup results for both editable and verified IDs.
              _buildStatusLine(),

              const SizedBox(height: 22),

              // ── Sync to phone card ─────────────────────────────
              _Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Sync contact to phone',
                          style: TextStyle(color: Colors.white, fontSize: 15),
                        ),
                      ),
                      SyncContactsSwitch(
                        value: _syncToPhone,
                        onChanged: (v) => setState(() => _syncToPhone = v),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── Add via QR code ────────────────────────────────
              Center(
                child: GestureDetector(
                  onTap: _openQrScanner,
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

  Future<void> _copyInviteLink() async {
    final identifier = _fullIdentifier.trim();
    final query =
        identifier.isEmpty
            ? ''
            : '?phone=${Uri.encodeQueryComponent(identifier)}';
    final inviteLink = 'https://wrytte.com/invite$query';
    await Clipboard.setData(ClipboardData(text: inviteLink));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied to clipboard.')),
    );
  }

  Future<void> _openQrScanner() async {
    final controller = TextEditingController();
    final scannedValue = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            backgroundColor: _kCard,
            title: const Text(
              'Enter Wrytte ID',
              style: TextStyle(color: Colors.white),
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Wrytte ID',
                hintStyle: TextStyle(color: Colors.white54),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: const Text('Continue'),
              ),
            ],
          ),
    );
    controller.dispose();
    final value = scannedValue?.trim() ?? '';
    if (value.isEmpty || !mounted) return;

    const wrytteMode = wryptteId;
    final digits = value.replaceAll(RegExp(r'[^\d]'), '');
    final body = digits.startsWith('00') ? digits.substring(2) : digits;
    setState(() {
      _selectedCountry = wrytteMode;
      _isWrytteIdInput = true;
      _codeCtrl.text = _formatWrytteIdInput('00$body');
      _showDivider = false;
      _lookupState = _LookupState.idle;
      _lookupError = null;
      _resolvedUserId = null;
      _isRegisteredOnWrytte = false;
    });
    _numberCtrl.text = _formatWrytteIdBody(body);
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
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;

  const _NameField({
    required this.controller,
    this.focusNode,
    required this.hint,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
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
