import 'dart:async';

import 'package:wrytte/services/contacts/contact_local_db.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/contacts/contact_directory_service.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_contact_service.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'user_search_service.dart';

class ContactService {
  final UserSearchService _userSearchService = UserSearchService();

  // ── Cache to avoid repeated Matrix directory lookups ───────────────────
  Map<String, String>? _phoneUserMapCache;
  DateTime? _cacheTime;

  // ── Static in-memory cache shared across screen opens ──────────────────
  static List<Contact>? _matrixContactsCache;
  static String? _matrixContactsCacheOwner;

  static void preloadContacts(String ownerUserId, ContactService service) {
    service.getMatrixContacts(ownerUserId).then((contacts) {
      _matrixContactsCache = contacts;
      _matrixContactsCacheOwner = ownerUserId;
    });
  }

  Future<List<Contact>> getMatrixContactsCached(String ownerUserId) async {
    if (_matrixContactsCache != null &&
        _matrixContactsCacheOwner == ownerUserId) {
      return _matrixContactsCache!;
    }
    final contacts = await getMatrixContacts(ownerUserId);
    _matrixContactsCache = contacts;
    _matrixContactsCacheOwner = ownerUserId;
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
  // Save contact through Matrix account data only.
  // ──────────────────────────────────────────────────────────────────────
  Future<void> saveContactToMatrix({
    required String ownerUserId,
    required Contact contact,
  }) async {
    try {
      final matrixReady = await _ensureMatrixContactSession(ownerUserId);
      if (!matrixReady) {
        apkLog(
          'Contact.save',
          'Matrix account-data save skipped; session not ready owner="$ownerUserId"',
        );
        return;
      }
      apkLog(
        'Contact.save',
        'Matrix account-data save start owner="$ownerUserId" name="${contact.formattedName}" wrytteUserId="${contact.wrytteUserId}" phone="${contact.primaryPhone}"',
      );
      await MatrixContactService.instance
          .saveContact(_normalizeContact(contact))
          .timeout(const Duration(seconds: 15));
      apkLog(
        'Contact.save',
        'Matrix account-data save done owner="$ownerUserId" name="${contact.formattedName}"',
      );
      debugPrint(
        '✅ Contact saved to Matrix account data: ${contact.displayName}',
      );
    } catch (e, stack) {
      if (_isUnknownMatrixToken(e)) {
        apkLog(
          'Contact.save',
          'Matrix account-data save got M_UNKNOWN_TOKEN; refreshing Matrix session owner="$ownerUserId"',
        );
        final refreshed = await _refreshMatrixSessionForContactSave(
          ownerUserId,
        );
        if (!refreshed) {
          apkLog(
            'Contact.save',
            'Matrix account-data retry skipped; session not ready owner="$ownerUserId"',
          );
          return;
        }
        apkLog(
          'Contact.save',
          'Matrix account-data save retry start owner="$ownerUserId" name="${contact.formattedName}"',
        );
        try {
          await MatrixContactService.instance
              .saveContact(_normalizeContact(contact))
              .timeout(const Duration(seconds: 15));
          apkLog(
            'Contact.save',
            'Matrix account-data save retry done owner="$ownerUserId" name="${contact.formattedName}"',
          );
        } catch (retryError) {
          apkLog(
            'Contact.save',
            'Matrix account-data save retry failed; local contact kept owner="$ownerUserId" error="$retryError"',
          );
        }
        return;
      }
      debugPrint('🔴 Contact save FAILED: $e');
      debugPrint('🔴 Stack: $stack');
      rethrow;
    }
  }

  Future<bool> _refreshMatrixSessionForContactSave(String ownerUserId) async {
    apkLog('Contact.save', 'Matrix session refresh start owner="$ownerUserId"');

    final expected = _toMatrixUserId(ownerUserId);
    var client = await MatrixClientService.instance.ensureInitialized();
    if (client.isLogged() && client.userID == expected) {
      final valid = await MatrixAuthService.instance.validateCurrentSession(
        expectedUserId: expected,
      );
      if (!valid) {
        apkLog(
          'Contact.save',
          'Matrix session refresh required; token invalid owner="$ownerUserId"',
        );
      } else {
        apkLog(
          'Contact.save',
          'Matrix session refresh skipped; already ready owner="$ownerUserId"',
        );
        return true;
      }
      client = await MatrixClientService.instance.ensureInitialized();
    }

    if (client.isLogged() && client.userID != expected) {
      apkLog(
        'Contact.save',
        'Matrix session mismatch before refresh current="${client.userID}" expected="$expected"',
      );
      try {
        await MatrixClientService.instance.clearLocalSession().timeout(
          const Duration(seconds: 5),
        );
        MatrixContactService.instance.clearCache();
        client = await MatrixClientService.instance.ensureInitialized();
      } catch (e) {
        apkLog(
          'Contact.save',
          'Matrix session mismatch clear failed owner="$ownerUserId" error="$e"',
        );
        return false;
      }
    }

    final storedName =
        (await AuthService.instance.getCurrentUsername())?.trim();
    final nickname =
        storedName != null && storedName.isNotEmpty ? storedName : ownerUserId;
    await AuthService.instance
        .loginToMatrix(
          userId: ownerUserId,
          nickname: nickname,
          forceFreshSession: true,
        )
        .timeout(const Duration(seconds: 75));
    client = MatrixClientService.instance.client;
    if (!client.isLogged() || client.userID != expected) {
      apkLog(
        'Contact.save',
        'Matrix session refresh not ready owner="$ownerUserId" current="${client.userID}" expected="$expected"',
      );
      return false;
    }
    MatrixContactService.instance.clearCache();
    apkLog('Contact.save', 'Matrix session refresh done owner="$ownerUserId"');
    return true;
  }

  bool _isUnknownMatrixToken(Object error) =>
      MatrixAuthService.isUnknownToken(error);

  // ──────────────────────────────────────────────────────────────────────
  // Fetch contacts saved by this user from Matrix account data.
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getMatrixContacts(String ownerUserId) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return [];
    try {
      final matrixReady = await _ensureMatrixContactSession(owner);
      if (!matrixReady) {
        debugPrint(
          '[ContactService] Matrix contacts skipped: session not ready for $owner',
        );
        return ContactLocalDb.loadContacts(ownerUserId: owner);
      }
      final matrixContacts = await MatrixContactService.instance.loadContacts();
      final contacts =
          matrixContacts
            ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
      debugPrint('Loaded ${contacts.length} contacts');
      return contacts;
    } catch (e) {
      debugPrint('Failed to load Matrix contacts: $e');
      return ContactLocalDb.loadContacts(ownerUserId: owner);
    }
  }

  Future<bool> _ensureMatrixContactSession(String ownerUserId) async {
    final expected = _toMatrixUserId(ownerUserId);
    final client = await MatrixAuthService.instance.restore();
    if (client.isLogged() && client.userID == expected) {
      return MatrixAuthService.instance.validateCurrentSession(
        expectedUserId: expected,
      );
    }

    if (client.isLogged()) {
      debugPrint(
        '[ContactService] Matrix contact session mismatch current="${client.userID}" expected="$expected"; skipping Matrix contact sync.',
      );
    }
    return false;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Wrytte contacts — parallel lookup with 5-minute cache
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
  // Save a manually-entered contact through Matrix account data first.
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
      isOnWrytte: isWrytteContact,
      wrytteUserId: wrytteUserId,
    );

    if (selfUserId != null && selfUserId.isNotEmpty) {
      await ContactLocalDb.addContact(contact, ownerUserId: selfUserId);
      if (wrytteUserId != null && wrytteUserId.trim().isNotEmpty) {
        await ContactIdentityCache.instance.upsert(
          ownerUserId: selfUserId,
          matrixUserId: wrytteUserId,
          phone: fullIdentifier,
          savedName: displayName,
        );
      }
      apkLog(
        'Contact.save',
        'local cache save done before Matrix owner="$selfUserId" name="${contact.formattedName}"',
      );

      invalidateCache();
      invalidateMatrixContactsCache();

      await saveContactToMatrix(ownerUserId: selfUserId, contact: contact);
    } else {
      throw StateError('Cannot save Matrix contact without a signed-in user.');
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

  Contact _normalizeContact(Contact contact) {
    return contact.copyWith(
      phones:
          contact.phones
              .map(_normalizePhone)
              .where((phone) => phone.isNotEmpty)
              .toSet()
              .toList(),
    );
  }

  Future<void> syncLocalContactsToMatrix(String ownerUserId) async {
    if (!await _ensureMatrixContactSession(ownerUserId)) return;
    final localContacts = await ContactLocalDb.loadContacts(
      ownerUserId: ownerUserId,
    );
    if (localContacts.isEmpty) return;

    for (final contact in localContacts) {
      try {
        await MatrixContactService.instance.saveContact(
          _normalizeContact(contact),
        );
      } on StateError catch (e) {
        debugPrint('Matrix contact sync not ready: $e');
        return;
      } catch (e) {
        debugPrint(
          'Matrix contact sync failed for ${contact.formattedName}: $e',
        );
      }
    }
  }

  String _toMatrixUserId(String userId) {
    final trimmed = userId.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    return '@${_matrixLocalpart(trimmed)}:${MatrixConfig.serverName}';
  }
}
