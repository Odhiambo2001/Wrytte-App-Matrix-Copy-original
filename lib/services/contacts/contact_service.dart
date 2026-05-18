import 'package:wrytte/services/contacts/contact_local_db.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/matrix/matrix_contact_service.dart';
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
      await MatrixContactService.instance.saveContact(_normalizeContact(contact));
      debugPrint('✅ Contact saved to Matrix account data: ${contact.displayName}');
    } catch (e, stack) {
      debugPrint('🔴 Contact save FAILED: $e');
      debugPrint('🔴 Stack: $stack');
      rethrow;
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Fetch contacts saved by this user from Matrix account data.
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getMatrixContacts(String ownerUserId) async {
    try {
      final contacts = await MatrixContactService.instance.loadContacts();
      debugPrint('Loaded ${contacts.length} Matrix contacts');
      return contacts;
    } catch (e) {
      debugPrint('Failed to load Matrix contacts: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Wrytte contacts — parallel lookup with 5-minute cache
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getWrytteContactsOptimized() async {
    final deviceContacts = await getDeviceContacts();

    final allPhones = deviceContacts
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
    final cacheValid = _cacheTime != null &&
        now.difference(_cacheTime!).inMinutes < 5 &&
        _phoneUserMapCache != null;

    Map<String, String> phoneUserMap;

    if (cacheValid) {
      debugPrint('✅ Using cached phone lookup');
      phoneUserMap = _phoneUserMapCache!;
    } else {
      // ✅ Run ALL chunks in parallel
      const chunkSize = 10;
      final chunks = <List<String>>[];
      for (var i = 0; i < allPhones.length; i += chunkSize) {
        chunks.add(allPhones.skip(i).take(chunkSize).toList());
      }

      debugPrint('Running ${chunks.length} parallel phone lookups');

      final results = await Future.wait(
        chunks.map((chunk) => _userSearchService.searchUsersByPhones(
              phoneNumbersC: chunk.join('|'),
              token: '',
            )),
      );

      phoneUserMap = {};
      for (final result in results) {
        phoneUserMap.addAll(result);
      }

      // ✅ Store in cache
      _phoneUserMapCache = phoneUserMap;
      _cacheTime = now;
    }

    final List<Contact> wrytteContacts = [];
    for (final dc in deviceContacts) {
      for (final phone in dc.phones) {
        final normalizedPhone = _normalizePhone(phone);
        final userId = phoneUserMap[normalizedPhone];
        if (userId != null) {
          wrytteContacts.add(Contact(
            displayName: dc.displayName,
            phones: dc.phones,
            avatarUrl: dc.avatarUrl,
            isOnWrytte: true,
            wrytteUserId: userId,
          ));
          break;
        }
      }
    }
    debugPrint('Found ${wrytteContacts.length} Wrytte contacts');
    return wrytteContacts;
  }

  Future<List<Contact>> getNonWrytteContacts() async {
    final deviceContacts = await getDeviceContacts();
    final wrytteContacts = await getWrytteContactsOptimized();
    final wryttePhones = wrytteContacts.expand((c) => c.phones).toSet();
    final nonWrytte = deviceContacts
        .where((c) => !c.phones.any((p) => wryttePhones.contains(p)))
        .toList();
    debugPrint('Found ${nonWrytte.length} non-Wrytte contacts');
    return nonWrytte;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Save a manually-entered contact
  // ✅ NEVER writes to device phonebook — stays inside Wrytte only
  // ──────────────────────────────────────────────────────────────────────
  Future<Contact> saveManualContact({
    required String firstName,
    required String lastName,
    required String fullIdentifier,
    required String? wrytteUserId,
    required bool syncToPhone,
    required String token,
    required String? selfUserId,
  }) async {
    final displayName = '$firstName $lastName'.trim();
    final isWrytteContact = wrytteUserId != null && wrytteUserId.isNotEmpty;

    final contact = Contact(
      displayName: displayName,
      phones: [_normalizePhone(fullIdentifier)],
      isOnWrytte: isWrytteContact,
      wrytteUserId: wrytteUserId,
    );

    if (selfUserId != null && selfUserId.isNotEmpty) {
      await saveContactToMatrix(
        ownerUserId: selfUserId,
        contact: contact,
      );
      await ContactLocalDb.addContact(contact);

      invalidateCache();
      invalidateMatrixContactsCache();
    }

    return contact;
  }

  Contact _normalizeContact(Contact contact) {
    return contact.copyWith(
      phones: contact.phones
          .map(_normalizePhone)
          .where((phone) => phone.isNotEmpty)
          .toSet()
          .toList(),
    );
  }
}
