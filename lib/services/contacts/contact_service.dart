import 'dart:async';

import 'package:wrytte/services/contacts/contact_local_db.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/contacts/contact_avatar_sanitizer.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/contacts/contact_directory_service.dart';
import 'package:wrytte/services/contacts/contact_identity_cache.dart';
import 'package:wrytte/services/user/avatar_preload_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/utils/apk_debug_logger.dart';
import 'user_search_service.dart';

class ContactService {
  final UserSearchService _userSearchService = UserSearchService();
  static final StreamController<String> _contactsChangedController =
      StreamController<String>.broadcast();

  static Stream<String> get contactsChanged =>
      _contactsChangedController.stream;

  // ── Cache to avoid repeated Wrytte directory lookups ───────────────────
  Map<String, String>? _phoneUserMapCache;
  DateTime? _cacheTime;

  // ── Static in-memory saved-contact cache shared across screen opens ────
  static List<Contact>? _matrixContactsCache;
  static String? _matrixContactsCacheOwner;
  static Future<List<Contact>>? _matrixContactsFetchInFlight;
  static String? _matrixContactsFetchOwner;
  static final Set<String> _profileRefreshOwners = <String>{};
  static int _cacheGeneration = 0;

  static void preloadContacts(String ownerUserId, ContactService service) {
    final generation = _cacheGeneration;
    service.getMatrixContacts(ownerUserId).then((contacts) {
      if (contacts.isEmpty || generation != _cacheGeneration) return;
      _matrixContactsCache = contacts;
      _matrixContactsCacheOwner = ownerUserId;
    });
  }

  Future<List<Contact>> getMatrixContactsCached(String ownerUserId) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return [];

    //Strict userId match — never serve another user's cached contacts
    if (_matrixContactsCache != null &&
        _matrixContactsCacheOwner != null &&
        _matrixContactsCacheOwner!.trim().toLowerCase() ==
            owner.toLowerCase() &&
        _matrixContactsCache!.isNotEmpty) {
      _matrixContactsCache = ContactAvatarSanitizer.sanitizeAll(
        _matrixContactsCache!,
      );
      return _matrixContactsCache!;
    }

    if (_matrixContactsFetchInFlight != null &&
        _matrixContactsFetchOwner != null &&
        _matrixContactsFetchOwner!.trim().toLowerCase() ==
            owner.toLowerCase()) {
      return _matrixContactsFetchInFlight!;
    }

    // Wrong owner — invalidate before fetching, but do not clear a valid in-flight
    // request for this owner.
    if (_matrixContactsCacheOwner != null &&
        _matrixContactsCacheOwner!.trim().toLowerCase() !=
            owner.toLowerCase()) {
      invalidateMatrixContactsCache();
    }

    final contacts = await getMatrixContacts(owner);
    if (contacts.isNotEmpty) {
      _matrixContactsCache = ContactAvatarSanitizer.sanitizeAll(contacts);
      _matrixContactsCacheOwner = owner;
    }
    return contacts;
  }

  /// Returns only the already-loaded Profile 2 contacts for [ownerUserId].
  /// This never starts I/O and is safe to use during a widget's first frame.
  static List<Contact> matrixContactsSnapshot(String ownerUserId) {
    final owner = ownerUserId.trim().toLowerCase();
    if (owner.isEmpty ||
        _matrixContactsCacheOwner?.trim().toLowerCase() != owner ||
        _matrixContactsCache == null) {
      return const [];
    }
    return List<Contact>.unmodifiable(_matrixContactsCache!);
  }

  static void invalidateMatrixContactsCache() {
    _matrixContactsCache = null;
    _matrixContactsCacheOwner = null;
    // Keep an active fetch registered. Clearing it here lets another caller
    // start a duplicate UserContacts/getall request for the same account.
  }

  static void clearAllCachesForLogout() {
    _cacheGeneration += 1;
    _matrixContactsCache = null;
    _matrixContactsCacheOwner = null;
    _matrixContactsFetchInFlight = null;
    _matrixContactsFetchOwner = null;
    _profileRefreshOwners.clear();
  }

  static void notifyContactsChanged(String ownerUserId) {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return;
    _contactsChangedController.add(owner);
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
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    cleaned = _stripInvalidNorthAmericaPrefix(cleaned);
    return cleaned;
  }

  String _stripInvalidNorthAmericaPrefix(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (!phone.startsWith('+1')) return phone;
    if (digits.length <= 11) return phone;
    return '+${digits.substring(1)}';
  }

  // ──────────────────────────────────────────────────────────────────────
  // Device contacts — read from phone book (for matching only)
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getDeviceContacts() async {
    final hasPermission = await requestContactsPermission();
    if (!hasPermission) throw Exception('Contacts permission denied');

    final deviceContacts = await fc.FlutterContacts.getContacts(
      withProperties: true,
      // This pass only matches phone numbers. Loading every device-contact
      // photo blocks the platform thread and causes visible startup jank.
      withPhoto: false,
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

  static const String _contactsAccountDataType = 'com.wrytte.contacts';

  Future<List<Contact>> _readMatrixAccountContacts(String owner) async {
    final client = MatrixClientService.instance.client;
    final sessionUserId = client.userID?.trim();
    if (sessionUserId == null || sessionUserId.isEmpty) {
      throw StateError('Cannot read contacts without an active Matrix session.');
    }
    final ownerLocalpart = _matrixLocalpart(owner)?.toLowerCase();
    final sessionLocalpart = _matrixLocalpart(sessionUserId)?.toLowerCase();
    if (ownerLocalpart == null || ownerLocalpart != sessionLocalpart) {
      throw StateError(
        'The active Matrix account does not match the contact owner.',
      );
    }

    // Matrix account data is private to its owner. Fetch it directly from the
    // authenticated homeserver instead of relying on possibly stale sync data.
    Map<String, Object?> accountData;
    try {
      accountData = await client.getAccountData(
        sessionUserId,
        _contactsAccountDataType,
      );
    } catch (error) {
      final message = error.toString();
      if (message.contains('M_NOT_FOUND') || message.contains('404')) {
        return const [];
      }
      rethrow;
    }
    final value = accountData['contacts'];
    if (value is! List) return [];
    return value
        .whereType<Map>()
        .map((item) => Contact.fromMap(Map<String, dynamic>.from(item)))
        .map((contact) => contact.copyWith(isSaved: true))
        .where((contact) => !_isSelfContact(contact.wrytteUserId, owner))
        .toList();
  }

  Future<void> _writeMatrixAccountContacts(String owner, List<Contact> contacts) async {
    final client = MatrixClientService.instance.client;
    final sessionUserId = client.userID?.trim();
    if (sessionUserId == null || sessionUserId.isEmpty) {
      throw StateError('Cannot sync contacts without an active Matrix session.');
    }
    final ownerLocalpart = _matrixLocalpart(owner)?.toLowerCase();
    final sessionLocalpart = _matrixLocalpart(sessionUserId)?.toLowerCase();
    if (ownerLocalpart == null || ownerLocalpart != sessionLocalpart) {
      throw StateError(
        'The active Matrix account does not match the contact owner.',
      );
    }

    // Matrix account data must be written against the authenticated MXID, not
    // the app's stored Wrytte ID/localpart (for example, "w123" vs
    // "@w123:wrytte.com").
    await client.setAccountData(sessionUserId, _contactsAccountDataType, {
      'contacts': contacts.map((contact) => contact.copyWith(isSaved: true).toMap()).toList(),
    });
  }

  Future<void> saveContactToBackend({
    required String ownerUserId,
    required Contact contact,
  }) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return;
    final freshContact = await _contactWithLatestPublicProfile(
      ownerUserId: owner,
      contact: contact,
    );

    final existing = await _readMatrixAccountContacts(owner);
    await _writeMatrixAccountContacts(owner, _mergeSavedContacts(existing, [freshContact]));
    apkLog(
      'Contact.save',
      'Matrix account-data contact save done owner="$owner" name="${freshContact.formattedName}"',
    );
  }

  Future<void> removeContactFromBackend({
    required String ownerUserId,
    required Contact contact,
  }) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return;
    final existing = await _readMatrixAccountContacts(owner);
    final key = _dedupeKey(contact);
    await _writeMatrixAccountContacts(owner,
        existing.where((item) => _dedupeKey(item) != key).toList());
    apkLog(
      'Contact.remove',
      'Matrix account-data contact remove done owner="$owner" name="${contact.formattedName}"',
    );
  }

  Future<void> updateContactNameOnBackend({
    required String ownerUserId,
    required Contact contact,
    required String name,
  }) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return;
    final existing = await _readMatrixAccountContacts(owner);
    final key = _dedupeKey(contact);
    final updated = existing.map((item) => _dedupeKey(item) == key
        ? item.copyWith(displayName: name)
        : item).toList();
    await _writeMatrixAccountContacts(owner, updated);
    apkLog(
      'Contact.update',
      'Matrix account-data contact update done owner="$owner" name="$name"',
    );
  }

  // ──────────────────────────────────────────────────────────────────────
  // Fetch this owner's contacts from local cache and their private Matrix
  // account data. The authenticated SDK request is owner scoped.
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getMatrixContacts(String ownerUserId) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty) return [];
    if (_matrixContactsFetchInFlight != null &&
        _matrixContactsFetchOwner != null &&
        _matrixContactsFetchOwner!.trim().toLowerCase() ==
            owner.toLowerCase()) {
      return _matrixContactsFetchInFlight!;
    }

    final fetch = _getMatrixContactsFresh(owner, _cacheGeneration);
    _matrixContactsFetchInFlight = fetch;
    _matrixContactsFetchOwner = owner;
    try {
      return await fetch;
    } finally {
      if (identical(_matrixContactsFetchInFlight, fetch)) {
        _matrixContactsFetchInFlight = null;
        _matrixContactsFetchOwner = null;
      }
    }
  }

  Future<List<Contact>> _getMatrixContactsFresh(
    String owner,
    int generation,
  ) async {
    final localContacts = await ContactLocalDb.loadSavedContacts(
      ownerUserId: owner,
    );
    var contacts = _sortSavedContacts(
      ContactAvatarSanitizer.sanitizeAll(
        localContacts
            .where((contact) => !_isSelfContact(contact.wrytteUserId, owner))
            .toList(),
      ),
    );
    if (contacts.length != localContacts.length) {
      await ContactLocalDb.saveContacts(contacts, ownerUserId: owner);
      ContactService.notifyContactsChanged(owner);
    }

    if (contacts.isEmpty) {
      final recoveredContacts = await ContactLocalDb.loadRecoverableContacts(
        ownerUserId: owner,
      );
      final peerRecoveredContacts =
          recoveredContacts
              .where((contact) => !_isSelfContact(contact.wrytteUserId, owner))
              .toList();
      if (peerRecoveredContacts.isNotEmpty) {
        contacts = _mergeSavedContacts(
          contacts,
          ContactAvatarSanitizer.sanitizeAll(peerRecoveredContacts),
        );
        await ContactLocalDb.saveContacts(contacts, ownerUserId: owner);
        apkLog(
          'Contact.recover',
          'recovered ${peerRecoveredContacts.length} contacts into owner="$owner"',
        );
      }
    }

    try {
      final matrixContacts = await _readMatrixAccountContacts(owner);
      if (generation != _cacheGeneration) return const [];
      if (matrixContacts.isNotEmpty) {
        contacts = _mergeSavedContacts(contacts, ContactAvatarSanitizer.sanitizeAll(matrixContacts));
        await ContactLocalDb.saveContacts(contacts, ownerUserId: owner);
        ContactService.notifyContactsChanged(owner);
      }
      _matrixContactsCache = ContactAvatarSanitizer.sanitizeAll(contacts);
      _matrixContactsCacheOwner = owner;
      debugPrint('Loaded ${contacts.length} contacts');
      return contacts;
    } catch (e) {
      debugPrint('Failed to load Matrix account-data contacts: $e');
      _matrixContactsCache = ContactAvatarSanitizer.sanitizeAll(contacts);
      _matrixContactsCacheOwner = owner;
      return contacts;
    }
  }

  Future<void> _refreshBackendContactProfiles(
    String owner,
    List<Contact> backendContacts,
  ) async {
    if (backendContacts.isEmpty || _profileRefreshOwners.contains(owner)) {
      return;
    }
    _profileRefreshOwners.add(owner);
    try {
      final refreshedContacts = await Future.wait(
        backendContacts.map(
          (contact) => _contactWithLatestPublicProfile(
            ownerUserId: owner,
            contact: contact.copyWith(isSaved: true),
          ),
        ),
      );
      if (refreshedContacts.isEmpty) return;

      final currentContacts = await ContactLocalDb.loadSavedContacts(
        ownerUserId: owner,
      );
      final mergedContacts = _mergeSavedContacts(
        ContactAvatarSanitizer.sanitizeAll(
          currentContacts
              .where((contact) => !_isSelfContact(contact.wrytteUserId, owner))
              .toList(),
        ),
        ContactAvatarSanitizer.sanitizeAll(refreshedContacts),
      );
      await ContactLocalDb.saveContacts(mergedContacts, ownerUserId: owner);
      _matrixContactsCache = ContactAvatarSanitizer.sanitizeAll(mergedContacts);
      _matrixContactsCacheOwner = owner;
      ContactService.notifyContactsChanged(owner);
    } catch (e) {
      apkLog(
        'Contact.sync',
        'backend profile refresh failed owner="$owner" error="$e"',
      );
    } finally {
      _profileRefreshOwners.remove(owner);
    }
  }

  List<Contact> _mergeSavedContacts(
    List<Contact> current,
    List<Contact> incoming,
  ) {
    final byKey = <String, Contact>{};
    for (final contact in ContactAvatarSanitizer.sanitizeAll(current)) {
      byKey[_dedupeKey(contact)] = contact.copyWith(isSaved: true);
    }
    for (final contact in ContactAvatarSanitizer.sanitizeAll(incoming)) {
      final savedContact = contact.copyWith(isSaved: true);
      final key = _dedupeKey(savedContact);
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = savedContact;
        continue;
      }
      byKey[key] = _mergeSavedContact(existing, savedContact);
    }
    return _sortSavedContacts(byKey.values.toList());
  }

  Contact _mergeSavedContact(Contact existing, Contact incoming) {
    final incomingName = incoming.displayName?.trim();
    final existingName = existing.displayName?.trim();
    final incomingAvatar = incoming.avatarUrl?.trim();
    final existingAvatar = existing.avatarUrl?.trim();
    final incomingBio = incoming.bio?.trim();
    final existingBio = existing.bio?.trim();
    final incomingUserId = incoming.wrytteUserId?.trim();
    final existingUserId = existing.wrytteUserId?.trim();

    return Contact(
      displayName:
          incomingName != null && incomingName.isNotEmpty
              ? incomingName
              : existingName,
      phones: incoming.phones.isNotEmpty ? incoming.phones : existing.phones,
      avatarUrl:
          incomingAvatar != null && incomingAvatar.isNotEmpty
              ? incomingAvatar
              : existingAvatar,
      bio:
          incomingBio != null && incomingBio.isNotEmpty
              ? incomingBio
              : existingBio,
      isOnWrytte: incoming.isOnWrytte || existing.isOnWrytte,
      wrytteUserId:
          incomingUserId != null && incomingUserId.isNotEmpty
              ? incomingUserId
              : existingUserId,
      databaseName: incoming.databaseName ?? existing.databaseName,
      firstName: incoming.firstName ?? existing.firstName,
      lastName: incoming.lastName ?? existing.lastName,
      directRoomId: incoming.directRoomId ?? existing.directRoomId,
      inviteStatus: incoming.inviteStatus ?? existing.inviteStatus,
      isRecent: existing.isRecent || incoming.isRecent,
      isSaved: true,
    );
  }

  List<Contact> _sortSavedContacts(List<Contact> contacts) {
    final sorted = List<Contact>.from(contacts);
    sorted.sort((a, b) => a.formattedName.compareTo(b.formattedName));
    return sorted;
  }

  String _dedupeKey(Contact contact) {
    final wrytteId = _matrixLocalpart(contact.wrytteUserId);
    if (wrytteId != null && wrytteId.isNotEmpty) {
      return 'w:${wrytteId.toLowerCase()}';
    }
    final phone = contact.phones
        .map(_normalizePhone)
        .firstWhere((phone) => phone.isNotEmpty, orElse: () => '');
    if (phone.isNotEmpty) return 'p:$phone';
    return 'n:${contact.formattedName.trim().toLowerCase()}';
  }

  // ──────────────────────────────────────────────────────────────────────
  // Wrytte directory lookup — parallel phone matching with 5-minute cache
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getWrytteContactsOptimized() async {
    final deviceContacts = await getDeviceContacts();
    final ownerUserId = await AuthService.instance.getCurrentUserId();

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
          if (_isSelfContact(matrixUserId, ownerUserId)) continue;
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
      ContactService.notifyContactsChanged(selfUserId);
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

    final storedContacts = await ContactLocalDb.loadSavedContacts(
      ownerUserId: owner,
    );
    final contacts =
        storedContacts
            .where((contact) => !_isSelfContact(contact.wrytteUserId, owner))
            .toList();
    if (contacts.length != storedContacts.length) {
      await ContactLocalDb.saveContacts(contacts, ownerUserId: owner);
      ContactService.notifyContactsChanged(owner);
    }
    if (contacts.isEmpty) {
      apkLog(
        'Contact.sync',
        'backend contact sync skipped; no local saved contacts owner="$owner"',
      );
      return;
    }

    await _writeMatrixAccountContacts(owner, contacts);
    invalidateMatrixContactsCache();
    apkLog(
      'Contact.sync',
      'Matrix account-data contact sync done owner="$owner" contacts=${contacts.length}',
    );
  }

  Future<Contact> _contactWithLatestPublicProfile({
    required String ownerUserId,
    required Contact contact,
  }) async {
    final wrytteUserId = contact.wrytteUserId?.trim();
    if (wrytteUserId == null || wrytteUserId.isEmpty) return contact;

    try {
      final profile = await UserProfileService.instance.getProfileByUid(
        wrytteUserId,
        phone: contact.primaryPhone,
        forceRefresh: true,
      );
      if (profile == null) return contact;

      final latestAvatar =
          profile.hasProfileImage ? profile.profileImage.trim() : null;
      final latestBio = profile.bio.trim();
      final latestPhone =
          profile.phone.trim().isNotEmpty ? profile.phone.trim() : null;
      if (latestAvatar != null && latestAvatar != contact.avatarUrl?.trim()) {
        unawaited(
          AvatarPreloadService.replace(
            oldUrl: contact.avatarUrl,
            newUrl: latestAvatar,
          ),
        );
      }

      final refreshed = await ContactLocalDb.refreshPublicProfileFields(
        ownerUserId: ownerUserId,
        wrytteUserId: wrytteUserId,
        phone: latestPhone ?? contact.primaryPhone,
        avatarUrl: latestAvatar,
        bio: latestBio,
      );
      if (refreshed != null) return refreshed;

      return Contact(
        displayName: contact.displayName,
        firstName: contact.firstName,
        lastName: contact.lastName,
        phones: latestPhone == null ? contact.phones : [latestPhone],
        avatarUrl: latestAvatar ?? contact.avatarUrl,
        bio: latestBio.isEmpty ? contact.bio : latestBio,
        isOnWrytte: contact.isOnWrytte,
        wrytteUserId: contact.wrytteUserId,
        databaseName: contact.databaseName,
        directRoomId: contact.directRoomId,
        isRecent: contact.isRecent,
        isSaved: true,
      );
    } catch (e) {
      apkLog(
        'Contact.sync',
        'public profile refresh skipped owner="$ownerUserId" contact="${contact.formattedName}" error="$e"',
      );
      return contact;
    }
  }
}
