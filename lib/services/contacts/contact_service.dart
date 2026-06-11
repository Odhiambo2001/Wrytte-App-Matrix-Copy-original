import 'dart:async';

import 'package:wrytte/services/contacts/contact_local_db.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/contacts/contact_backend_service.dart';
import 'package:wrytte/services/contacts/contact_directory_service.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'user_search_service.dart';

class ContactService {
  final UserSearchService _userSearchService = UserSearchService();

  // ── Cache to avoid repeated Wrytte directory lookups ───────────────────
  Map<String, String>? _phoneUserMapCache;
  DateTime? _cacheTime;

  // ── Static in-memory saved-contact cache shared across screen opens ────
  static List<Contact>? _matrixContactsCache;
  static String? _matrixContactsCacheOwner;

  static void preloadContacts(String ownerUserId, ContactService service) {
    service.getMatrixContacts(ownerUserId).then((contacts) {
      if (contacts.isEmpty) return;
      _matrixContactsCache = contacts;
      _matrixContactsCacheOwner = ownerUserId;
    });
  }

  Future<List<Contact>> getMatrixContactsCached(String ownerUserId) async {
    //Strict userId match — never serve another user's cached contacts
    if (_matrixContactsCache != null &&
        _matrixContactsCacheOwner != null &&
        _matrixContactsCacheOwner!.trim().toLowerCase() ==
            ownerUserId.trim().toLowerCase() &&
        _matrixContactsCache!.isNotEmpty) {
      return _matrixContactsCache!;
    }

    //Wrong owner or empty — invalidate before fetching
    invalidateMatrixContactsCache();

    final contacts = await getMatrixContacts(ownerUserId);
    if (contacts.isNotEmpty) {
      _matrixContactsCache = contacts;
      _matrixContactsCacheOwner = ownerUserId.trim();
    }
    return contacts;
  }

  static void invalidateMatrixContactsCache() {
    _matrixContactsCache = null;
    _matrixContactsCacheOwner = null;
  }

  void invalidateCache() {
    _phoneUserMapCache = null;
    _cacheTime = null;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Permission
  // ──────────────────────────────────────────────────────────────────────
  // ✅ FIXED — check status first, only request if not yet determined
  // Add as a class-level field

  static bool _permissionRequestInProgress = false;

  Future<bool> requestContactsPermission() async {
    final status = await Permission.contacts.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) return false;

    // Guard against concurrent requests
    if (_permissionRequestInProgress) {
      // Wait briefly and re-check
      await Future.delayed(const Duration(milliseconds: 500));
      return (await Permission.contacts.status).isGranted;
    }

    _permissionRequestInProgress = true;
    try {
      final result = await Permission.contacts.request();
      return result.isGranted;
    } finally {
      _permissionRequestInProgress = false;
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Phone normalisation
  // ──────────────────────────────────────────────────────────────────────
  String _normalizePhone(String phone) {
    String cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) return '+$cleaned';
    return cleaned;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Device contacts — read from phone book (for matching only)
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getDeviceContacts() async {
    final hasPermission = await requestContactsPermission();
    if (!hasPermission) throw Exception('Contacts permission denied');

    final deviceContacts = await fc.FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: true,
    );

    final List<Contact> contacts = [];
    for (var c in deviceContacts) {
      final phones = <String>[];
      for (var p in c.phones) {
        final normalized = _normalizePhone(p.number);
        final digitsOnly = normalized.replaceAll(RegExp(r'[^\d]'), '');
        if (digitsOnly.length >= 7) phones.add(normalized);
      }
      if (phones.isNotEmpty) {
        contacts.add(
          Contact(displayName: c.displayName, phones: phones, avatarUrl: null),
        );
      }
    }
    debugPrint('Loaded ${contacts.length} device contacts');
    return contacts;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Backend is the remote source of truth for saved contacts. Matrix is chat
  // transport only and must not be used as the contact database.
  // ──────────────────────────────────────────────────────────────────────
  Future<void> saveContactToBackend({
    required String ownerUserId,
    required Contact contact,
  }) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return;

    await ContactBackendService.instance.saveContact(
      ownerUserId: owner,
      contact: contact.copyWith(isSaved: true),
    );
    apkLog(
      'Contact.save',
      'backend contact save done owner="$owner" name="${contact.formattedName}" wrytteUserId="${contact.wrytteUserId}"',
    );
  }

  // ──────────────────────────────────────────────────────────────────────
  // Fetch contacts saved by this user. Local cache paints immediately; backend
  // can restore contacts after reinstall/login. Matrix is not used here.
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getMatrixContacts(String ownerUserId) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return [];
    final localContacts = await ContactLocalDb.loadSavedContacts(
      ownerUserId: owner,
    );
    if (localContacts.isNotEmpty) {
      return localContacts
        ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
    }

    final recoveredContacts = await ContactLocalDb.loadRecoverableContacts(
      ownerUserId: owner,
    );
    if (recoveredContacts.isNotEmpty) {
      await ContactLocalDb.saveContacts(recoveredContacts, ownerUserId: owner);
      apkLog(
        'Contact.recover',
        'recovered ${recoveredContacts.length} contacts into owner="$owner"',
      );
      return recoveredContacts;
    }

    try {
      final contacts =
          (await ContactBackendService.instance.loadContacts(
              ownerUserId: owner,
            )).map((contact) => contact.copyWith(isSaved: true)).toList()
            ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
      if (contacts.isNotEmpty) {
        await ContactLocalDb.saveContacts(contacts, ownerUserId: owner);
      }
      debugPrint('Loaded ${contacts.length} contacts');
      return contacts;
    } catch (e) {
      debugPrint('Failed to load backend contacts: $e');
      return ContactLocalDb.loadContacts(ownerUserId: owner);
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Wrytte directory lookup — parallel phone matching with 5-minute cache
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getWrytteContactsOptimized() async {
    final deviceContacts = await getDeviceContacts();

    final allPhones =
        deviceContacts
            .expand((c) => c.phones)
            .where((p) {
              final digits = p.replaceAll(RegExp(r'[^\d]'), '');
              return digits.length >= 7;
            })
            .toSet()
            .toList();

    if (allPhones.isEmpty) return [];

    // ✅ Use cache if less than 5 minutes old
    final now = DateTime.now();
    final cacheValid =
        _cacheTime != null &&
        now.difference(_cacheTime!).inMinutes < 5 &&
        _phoneUserMapCache != null;

    Map<String, String> phoneUserMap;

    if (cacheValid) {
      debugPrint('✅ Using cached phone lookup');
      phoneUserMap = _phoneUserMapCache!;
    } else {
      debugPrint('Running batched phone lookup for ${allPhones.length} phones');

      try {
        phoneUserMap = await _searchPhonesInChunks(allPhones);
      } on ContactDirectoryUnavailable catch (e) {
        debugPrint('Wrytte contact lookup unavailable: $e');
        _phoneUserMapCache = {};
        _cacheTime = now;
        return [];
      } on TimeoutException catch (e) {
        debugPrint('Wrytte contact lookup timed out: $e');
        _phoneUserMapCache = {};
        _cacheTime = now;
        return [];
      } catch (e) {
        debugPrint('Wrytte contact lookup failed: $e');
        _phoneUserMapCache = {};
        _cacheTime = now;
        return [];
      }

      // ✅ Store in cache
      _phoneUserMapCache = phoneUserMap;
      _cacheTime = now;
    }

    final List<Contact> wrytteContacts = [];
    for (final dc in deviceContacts) {
      for (final phone in dc.phones) {
        final normalizedPhone = _normalizePhone(phone);
        final userId =
            phoneUserMap[normalizedPhone] ??
            phoneUserMap[normalizedPhone.replaceAll(RegExp(r'[^\d]'), '')];
        if (userId != null) {
          final matrixUserId =
              userId == UserSearchService.registeredWithoutMatrixId
                  ? null
                  : userId;
          final ownerUserId = await AuthService.instance.getCurrentUserId();
          if (ownerUserId != null &&
              ownerUserId.isNotEmpty &&
              matrixUserId != null &&
              matrixUserId.isNotEmpty) {
            unawaited(
              ContactIdentityCache.instance.upsert(
                ownerUserId: ownerUserId,
                matrixUserId: matrixUserId,
                phone: normalizedPhone,
                profileName: dc.displayName,
                avatarUrl: dc.avatarUrl,
              ),
            );
          }
          wrytteContacts.add(
            Contact(
              displayName: dc.displayName,
              phones: dc.phones,
              avatarUrl: dc.avatarUrl,
              isOnWrytte: true,
              wrytteUserId: matrixUserId,
            ),
          );
          break;
        }
      }
    }
    debugPrint('Found ${wrytteContacts.length} Wrytte contacts');
    return wrytteContacts;
  }

  Future<Map<String, String>> _searchPhonesInChunks(List<String> phones) async {
    const chunkSize = 80;
    final phoneUserMap = <String, String>{};

    for (var start = 0; start < phones.length; start += chunkSize) {
      final end =
          (start + chunkSize > phones.length)
              ? phones.length
              : start + chunkSize;
      final chunk = phones.sublist(start, end);
      debugPrint(
        'Running Wrytte phone lookup chunk '
        '${(start ~/ chunkSize) + 1} for ${chunk.length} phones',
      );

      try {
        final chunkResult = await _userSearchService.searchUsersByPhones(
          phoneNumbersC: chunk.join('|'),
          token: '',
        );
        phoneUserMap.addAll(chunkResult);
      } on ContactDirectoryUnavailable catch (e) {
        debugPrint('Wrytte contact lookup chunk unavailable: $e');
      } on TimeoutException catch (e) {
        debugPrint('Wrytte contact lookup chunk timed out: $e');
      } catch (e) {
        debugPrint('Wrytte contact lookup chunk failed: $e');
      }
    }

    return phoneUserMap;
  }

  Future<List<Contact>> getNonWrytteContacts() async {
    final deviceContacts = await getDeviceContacts();
    final wrytteContacts = await getWrytteContactsOptimized();
    final wryttePhones = wrytteContacts.expand((c) => c.phones).toSet();
    final nonWrytte =
        deviceContacts
            .where((c) => !c.phones.any((p) => wryttePhones.contains(p)))
            .toList();
    debugPrint('Found ${nonWrytte.length} non-Wrytte contacts');
    return nonWrytte;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Save a manually-entered contact through backend/local contact flow.
  // ──────────────────────────────────────────────────────────────────────
  Future<Contact> saveManualContact({
    required String firstName,
    required String lastName,
    required String fullIdentifier,
    required String? wrytteUserId,
    required bool isOnWrytte,
    required bool syncToPhone,
    required String token,
    required String? selfUserId,
    String? bio,
  }) async {
    final displayName = '$firstName $lastName'.trim();
    final isWrytteContact =
        isOnWrytte || (wrytteUserId != null && wrytteUserId.isNotEmpty);
    apkLog(
      'Contact.save',
      'manual save start self="$selfUserId" name="$displayName" identifier="$fullIdentifier" wrytteUserId="$wrytteUserId" isOnWrytte=$isWrytteContact syncToPhone=$syncToPhone',
    );
    if (_isSelfContact(wrytteUserId, selfUserId)) {
      throw StateError('You cannot add your own Wrytte account as a contact.');
    }

    final contact = Contact(
      displayName: displayName,
      phones: [_normalizePhone(fullIdentifier)],
      bio: bio,
      isOnWrytte: isWrytteContact,
      wrytteUserId: wrytteUserId,
      isSaved: true,
    );

    if (selfUserId != null && selfUserId.isNotEmpty) {
      await ContactLocalDb.addContact(contact, ownerUserId: selfUserId);
      if (wrytteUserId != null && wrytteUserId.trim().isNotEmpty) {
        await ContactIdentityCache.instance.upsert(
          ownerUserId: selfUserId,
          matrixUserId: wrytteUserId,
          phone: fullIdentifier,
          savedName: displayName,
          bio: bio,
        );
      }
      apkLog(
        'Contact.save',
        'local cache save done owner="$selfUserId" name="${contact.formattedName}"',
      );

      unawaited(
        saveContactToBackend(
          ownerUserId: selfUserId,
          contact: contact,
        ).catchError((e) {
          apkLog(
            'Contact.save',
            'backend contact save failed owner="$selfUserId" name="${contact.formattedName}" error="$e"',
          );
        }),
      );

      invalidateCache();
      invalidateMatrixContactsCache();
    } else {
      throw StateError('Cannot save contact without a signed-in user.');
    }

    apkLog(
      'Contact.save',
      'manual save complete name="${contact.formattedName}" wrytteUserId="${contact.wrytteUserId}"',
    );
    return contact;
  }

  bool _isSelfContact(String? wrytteUserId, String? selfUserId) {
    final self = selfUserId?.trim();
    if (self == null || self.isEmpty) return false;
    final other = _matrixLocalpart(wrytteUserId);
    return other == self;
  }

  String? _matrixLocalpart(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('@') && trimmed.contains(':')) {
      return trimmed.substring(1, trimmed.indexOf(':'));
    }
    return trimmed;
  }

  Future<void> syncLocalContactsToBackend(String ownerUserId) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return;

    final contacts = await ContactLocalDb.loadSavedContacts(ownerUserId: owner);
    if (contacts.isEmpty) {
      apkLog(
        'Contact.sync',
        'backend contact sync skipped; no local saved contacts owner="$owner"',
      );
      return;
    }

    for (final contact in contacts) {
      await ContactBackendService.instance.saveContact(
        ownerUserId: owner,
        contact: contact.copyWith(isSaved: true),
      );
    }
    invalidateMatrixContactsCache();
    apkLog(
      'Contact.sync',
      'backend contact sync done owner="$owner" contacts=${contacts.length}',
    );
  }
}
