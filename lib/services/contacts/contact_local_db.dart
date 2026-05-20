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
    final data = contacts.map((c) => jsonEncode({
          'name': c.displayName,
          'phones': c.phones.map(_normalizePhone).toList(),
          'avatar': c.avatarUrl,
          'wrytteUserId': c.wrytteUserId,
          'isOnWrytte': c.isOnWrytte,
        })).toList();

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
        wrytteUserId: json['wrytteUserId'],
        isOnWrytte: json['isOnWrytte'] ?? false,
      );
    }).toList();
  }

  static Future<void> addContact(
    Contact contact, {
    required String ownerUserId,
  }) async {
    final existing = await loadContacts(ownerUserId: ownerUserId);
    existing.add(contact.copyWith(
      phones: contact.phones.map(_normalizePhone).toList(),
    ));
    await saveContacts(existing, ownerUserId: ownerUserId);
  }

  static String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }
}
