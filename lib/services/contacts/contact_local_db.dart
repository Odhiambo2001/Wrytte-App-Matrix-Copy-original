import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/models/contact_model.dart';

class ContactLocalDb {
  static const _key = 'local_contacts';

  static Future<void> saveContacts(List<Contact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final data = contacts.map((c) => jsonEncode({
          'name': c.displayName,
          'phones': c.phones.map(_normalizePhone).toList(),
          'avatar': c.avatarUrl,
          'wrytteUserId': c.wrytteUserId,
          'isOnWrytte': c.isOnWrytte,
        })).toList();

    await prefs.setStringList(_key, data);
  }

  static Future<List<Contact>> loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(_key) ?? [];

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

  static Future<void> addContact(Contact contact) async {
    final existing = await loadContacts();
    existing.add(contact.copyWith(
      phones: contact.phones.map(_normalizePhone).toList(),
    ));
    await saveContacts(existing);
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
