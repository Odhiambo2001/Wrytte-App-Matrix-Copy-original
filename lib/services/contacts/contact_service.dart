import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:wrytte/services/contacts/contact_local_db.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/matrix/matrix_chat_service.dart';
import 'user_search_service.dart';

class ContactService {
  final UserSearchService _userSearchService = UserSearchService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ── Cache to avoid repeated Firestore lookups ──────────────────────────
  Map<String, String>? _phoneUserMapCache;
  DateTime? _cacheTime;

  // ── Static in-memory cache shared across screen opens ──────────────────
  static List<Contact>? _firestoreContactsCache;
  static String? _firestoreContactsCacheOwner;

  static void preloadContacts(String ownerUserId, ContactService service) {
    service.getFirestoreContacts(ownerUserId).then((contacts) {
      _firestoreContactsCache = contacts;
      _firestoreContactsCacheOwner = ownerUserId;
    });
  }

  Future<List<Contact>> getFirestoreContactsCached(String ownerUserId) async {
    if (_firestoreContactsCache != null &&
        _firestoreContactsCacheOwner == ownerUserId) {
      return _firestoreContactsCache!;
    }
    final contacts = await getFirestoreContacts(ownerUserId);
    _firestoreContactsCache = contacts;
    _firestoreContactsCacheOwner = ownerUserId;
    return contacts;
  }

  static void invalidateFirestoreCache() {
    _firestoreContactsCache = null;
    _firestoreContactsCacheOwner = null;
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
    if (cleaned.startsWith('+')) return cleaned;
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      return '+${cleaned.substring(2)}';
    }
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
  // Save contact to PRIVATE subcollection under the owner's user document
  // users/{ownerUserId}/contacts/{phoneDigits}
  // ──────────────────────────────────────────────────────────────────────
  Future<void> saveContactToFirestore({
    required String ownerUserId,
    required Contact contact,
  }) async {
    try {
      final phone = contact.phones.isNotEmpty
          ? _normalizePhone(contact.phones.first)
          : null;

      if (phone == null || phone.isEmpty) {
        debugPrint('No phone number — skipping Firestore save');
        return;
      }

      final docId = phone.replaceAll(RegExp(r'[^\d]'), '');

      // ✅ FIXED: write to private subcollection under the owner's UID
      final contactRef = _firestore
          .collection('users')
          .doc(ownerUserId)
          .collection('contacts')
          .doc(docId);

      await contactRef.set({
        'phone': phone,
        'name': contact.displayName ?? '',
        'username': contact.displayName ?? '',
        'uid': contact.wrytteUserId ?? docId,
        'matrixUserId': contact.wrytteUserId ?? '',
        'isOnWrytte': contact.isOnWrytte,
        'avatarUrl': contact.avatarUrl ?? '',
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint('✅ Contact saved to users/$ownerUserId/contacts/$docId: ${contact.displayName}');
    } catch (e, stack) {
      debugPrint('🔴 Firestore write FAILED: $e');
      debugPrint('🔴 Stack: $stack');
      rethrow;
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Fetch contacts saved by this user — from their PRIVATE subcollection
  // ──────────────────────────────────────────────────────────────────────
  Future<List<Contact>> getFirestoreContacts(String ownerUserId) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      debugPrint('🔴 Not authenticated');
      return [];
    }

    try {
      // ✅ FIXED: read only from this user's private subcollection
      final snapshot = await _firestore
          .collection('users')
          .doc(ownerUserId)
          .collection('contacts')
          .get();

      final contacts = snapshot.docs.map((doc) {
        final data = doc.data();
        return Contact(
          displayName: data['name']?.toString(),
          phones: [data['phone']?.toString() ?? ''],
          avatarUrl: data['avatarUrl']?.toString(),
          isOnWrytte: data['isOnWrytte'] as bool? ?? false,
          wrytteUserId: data['matrixUserId']?.toString() ??
              data['openImUserId']?.toString(),
        );
      }).toList();

      debugPrint('Loaded ${contacts.length} Firestore contacts');
      return contacts;
    } catch (e) {
      debugPrint('Failed to load Firestore contacts: $e');
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

    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null || token.isEmpty) throw Exception('User not authenticated');

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
              token: token,
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


  /*  
  
  Do NOT write to device contacts. If this is a Wrytte contact, Matrix direct
  room creation can be used to establish the contact relationship.
   This keeps the contact management within Wrytte and avoids polluting the user's phonebook with entries they didn't explicitly add there.
  


  if (isWrytteContact) {
    if (selfUserId == null || selfUserId.isEmpty) {
      throw Exception('Could not resolve your user ID. Please log in again.');
    }
    await _matrixAddFriend(
      selfUserId: selfUserId,
      friendUserId: wrytteUserId,
      remark: displayName,
      token: token,
    );
  }

  */


  final contact = Contact(
      displayName: displayName,
      phones: [fullIdentifier],
      isOnWrytte: isWrytteContact,
      wrytteUserId: wrytteUserId,
    );

    if (selfUserId != null && selfUserId.isNotEmpty)
     {
      await saveContactToFirestore(
        ownerUserId: selfUserId,
        contact: contact,
      );
      await ContactLocalDb.addContact(contact);

      invalidateCache();
      invalidateFirestoreCache();
    }

    return contact;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Matrix direct room — contact relationship
  // ──────────────────────────────────────────────────────────────────────
  Future<void> _matrixAddFriend({
    required String selfUserId,
    required String friendUserId,
    required String remark,
    required String token,
  }) async {
    await MatrixChatService.instance.getOrCreateDirectRoom(friendUserId);
    debugPrint('Matrix direct room ensured for $friendUserId');
  }
}
