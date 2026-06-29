import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/models/contact_model.dart';

class ContactLocalDb {
  static const _key = 'local_contacts';

  static String _keyForOwner(String ownerUserId) {
    final normalizedOwner = ownerUserId.trim();
    if (normalizedOwner.isEmpty) {
      throw StateError('Cannot save contacts without a signed-in user.');
    }
    return '${_key}_$normalizedOwner';
  }

  static Future<void> saveContacts(
    List<Contact> contacts, {
    required String ownerUserId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final data =
        contacts
            .map(
              (c) => jsonEncode({
                'name': c.displayName,
                'phones': c.phones.map(_normalizePhone).toList(),
                'avatar': c.avatarUrl,
                'bio': c.bio,
                'wrytteUserId': c.wrytteUserId,
                'isOnWrytte': c.isOnWrytte,
                'isSaved': c.isSaved,
              }),
            )
            .toList();

    await prefs.setStringList(_keyForOwner(ownerUserId), data);
  }

  static Future<List<Contact>> loadContacts({
    required String ownerUserId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(_keyForOwner(ownerUserId)) ?? [];

    return data.map((e) {
      final json = jsonDecode(e);
      return Contact(
        displayName: json['name'],
        phones: List<String>.from(json['phones']).map(_normalizePhone).toList(),
        avatarUrl: json['avatar'],
        bio: json['bio'],
        wrytteUserId: json['wrytteUserId'],
        isOnWrytte: json['isOnWrytte'] ?? false,
        isSaved: json['isSaved'] ?? false,
      );
    }).toList();
  }

  static Future<List<Contact>> loadSavedContacts({
    required String ownerUserId,
  }) async {
    return (await loadContacts(
      ownerUserId: ownerUserId,
    )).where((contact) => contact.isSaved).toList();
  }

  static Future<List<Contact>> loadRecoverableContacts({
    required String ownerUserId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final normalizedOwner = ownerUserId.trim();
    final currentKey = _keyForOwner(normalizedOwner);
    final contactsByKey = <String, Contact>{};

    for (final key in prefs.getKeys()) {
      if (!key.startsWith('${_key}_')) continue;

      // Extract the userId portion from the key
      final keyUserId = key.substring('${_key}_'.length);

      // ONLY recover if the key belongs to THIS exact userId
      // Handles minor formatting variants of the same ID (trim, case)
      if (keyUserId.trim().toLowerCase() !=
          normalizedOwner.trim().toLowerCase()) {
        continue; // Different userId — never touch their contacts
      }

      // Skip the current active key (it was already checked and was empty)
      if (key == currentKey) continue;

      final data = prefs.getStringList(key) ?? const <String>[];
      for (final raw in data) {
        try {
          final json = jsonDecode(raw);
          final contact = Contact(
            displayName: json['name'],
            phones:
                List<String>.from(
                  json['phones'] ?? const <String>[],
                ).map(_normalizePhone).toList(),
            avatarUrl: json['avatar'],
            bio: json['bio'],
            wrytteUserId: json['wrytteUserId'],
            isOnWrytte: json['isOnWrytte'] ?? false,
            isSaved: json['isSaved'] ?? false,
          );
          if (!contact.isSaved) continue;
          final dedupeKey = _dedupeKey(contact);
          if (dedupeKey.isNotEmpty) contactsByKey[dedupeKey] = contact;
        } catch (_) {
          // Ignore corrupted entries
        }
      }
    }

    return contactsByKey.values.toList()
      ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
  }

  static Future<void> addContact(
    Contact contact, {
    required String ownerUserId,
  }) async {
    final existing = await loadContacts(ownerUserId: ownerUserId);
    final incomingPhones = contact.phones.map(_normalizePhone).toSet();
    final incomingWrytteId = contact.wrytteUserId?.trim();
    existing.removeWhere((saved) {
      final savedWrytteId = saved.wrytteUserId?.trim();
      final sameWrytteId =
          incomingWrytteId != null &&
          incomingWrytteId.isNotEmpty &&
          savedWrytteId == incomingWrytteId;
      final samePhone = saved.phones
          .map(_normalizePhone)
          .any(incomingPhones.contains);
      return sameWrytteId || samePhone;
    });
    existing.add(
      contact.copyWith(phones: contact.phones.map(_normalizePhone).toList()),
    );
    await saveContacts(existing, ownerUserId: ownerUserId);
  }

  static Future<Contact?> removeContact(
    Contact contact, {
    required String ownerUserId,
  }) async {
    final existing = await loadContacts(ownerUserId: ownerUserId);
    final incomingPhones = contact.phones.map(_normalizePhone).toSet();
    final incomingWrytteId = contact.wrytteUserId?.trim();
    Contact? removed;
    existing.removeWhere((saved) {
      final savedWrytteId = saved.wrytteUserId?.trim();
      final sameWrytteId =
          incomingWrytteId != null &&
          incomingWrytteId.isNotEmpty &&
          savedWrytteId == incomingWrytteId;
      final samePhone = saved.phones
          .map(_normalizePhone)
          .any(incomingPhones.contains);
      final shouldRemove = sameWrytteId || samePhone;
      if (shouldRemove) removed ??= saved;
      return shouldRemove;
    });
    if (removed != null) {
      await saveContacts(existing, ownerUserId: ownerUserId);
    }
    return removed;
  }

  static Future<Contact?> refreshPublicProfileFields({
    required String ownerUserId,
    String? wrytteUserId,
    String? phone,
    String? avatarUrl,
    String? bio,
  }) async {
    final existing = await loadContacts(ownerUserId: ownerUserId);
    final targetWrytteId = wrytteUserId?.trim();
    final targetPhone = _normalizePhone(phone ?? '');
    final cleanAvatar = avatarUrl?.trim();
    final cleanBio = bio?.trim();
    Contact? updated;

    for (var i = 0; i < existing.length; i++) {
      final contact = existing[i];
      final sameWrytteId =
          targetWrytteId != null &&
          targetWrytteId.isNotEmpty &&
          contact.wrytteUserId?.trim() == targetWrytteId;
      final samePhone =
          targetPhone.isNotEmpty &&
          contact.phones.map(_normalizePhone).contains(targetPhone);
      if (!sameWrytteId && !samePhone) continue;

      final next = Contact(
        displayName: contact.displayName,
        phones: contact.phones,
        avatarUrl: avatarUrl == null ? contact.avatarUrl : cleanAvatar,
        bio: bio == null ? contact.bio : cleanBio,
        isOnWrytte: contact.isOnWrytte,
        wrytteUserId: contact.wrytteUserId,
        databaseName: contact.databaseName,
        isRecent: contact.isRecent,
        isSaved: contact.isSaved,
      );
      existing[i] = next;
      updated = next;
      break;
    }

    if (updated != null) {
      await saveContacts(existing, ownerUserId: ownerUserId);
    }
    return updated;
  }

  static String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    cleaned = _stripInvalidNorthAmericaPrefix(cleaned);
    return cleaned;
  }

  static String _stripInvalidNorthAmericaPrefix(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (!phone.startsWith('+1')) return phone;
    if (digits.length <= 11) return phone;
    return '+${digits.substring(1)}';
  }

  static String _dedupeKey(Contact contact) {
    final wrytteId = contact.wrytteUserId?.trim();
    if (wrytteId != null && wrytteId.isNotEmpty) return 'w:$wrytteId';
    final phone = contact.phones
        .map(_normalizePhone)
        .firstWhere((phone) => phone.isNotEmpty, orElse: () => '');
    return phone.isEmpty ? '' : 'p:$phone';
  }
}
