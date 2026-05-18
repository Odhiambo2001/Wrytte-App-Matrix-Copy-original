import 'package:flutter/foundation.dart';
import 'package:wrytte/models/contact_model.dart';

import 'matrix_auth_service.dart';
import 'matrix_chat_service.dart';
import 'matrix_client.dart';

class MatrixContactService {
  MatrixContactService._();
  static final MatrixContactService instance = MatrixContactService._();

  static const accountDataType = 'com.wrytte.contacts';
  Map<String, Object?>? _memoryContacts;

  Future<List<Contact>> loadContacts() async {
    final client = await MatrixAuthService.instance.restore();
    if (!client.isLogged()) return [];

    final content = client.accountData[accountDataType]?.content;
    final rawContacts = content?['contacts'];
    if (rawContacts is! Map) return [];

    _memoryContacts = rawContacts.map(
      (key, value) => MapEntry(key.toString(), value),
    );

    return rawContacts.values
        .whereType<Map>()
        .map((raw) => _contactFromAccountData(raw))
        .where((contact) => contact.primaryPhone.isNotEmpty ||
            (contact.wrytteUserId?.isNotEmpty ?? false))
        .toList()
      ..sort((a, b) => a.formattedName.compareTo(b.formattedName));
  }

  Future<void> saveContact(Contact contact) async {
    final client = await MatrixAuthService.instance.restore();
    final userId = client.userID;
    if (userId == null || userId.isEmpty || !client.isLogged()) {
      throw StateError('Matrix session is not available for contact save.');
    }

    final current = await _contactsMap();
    final key = _contactKey(contact);
    current[key] = _contactToAccountData(contact);
    _memoryContacts = Map<String, Object?>.from(current);

    await client.setAccountData(userId, accountDataType, {
      'version': 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'contacts': current,
    });

    final matrixUserId = contact.wrytteUserId;
    if (matrixUserId != null && matrixUserId.startsWith('@')) {
      try {
        await MatrixChatService.instance.getOrCreateDirectRoom(matrixUserId);
      } catch (e) {
        debugPrint('[MatrixContactService] direct room bootstrap failed: $e');
      }
    }
  }

  Future<Map<String, Object?>> _contactsMap() async {
    final client = MatrixClientService.instance.client;
    final content = client.accountData[accountDataType]?.content;
    final rawContacts = content?['contacts'];
    if (rawContacts is! Map) {
      return Map<String, Object?>.from(_memoryContacts ?? {});
    }
    final fromSync = rawContacts.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    return {
      ...fromSync,
      ...?_memoryContacts,
    };
  }

  String _contactKey(Contact contact) {
    final matrixId = contact.wrytteUserId?.trim();
    if (matrixId != null && matrixId.isNotEmpty) return matrixId;
    final phone = _normalizePhone(contact.primaryPhone);
    return phone.isNotEmpty
        ? phone
        : contact.formattedName.trim().toLowerCase();
  }

  Map<String, Object?> _contactToAccountData(Contact contact) => {
        'name': contact.displayName ?? '',
        'phones': contact.phones.map(_normalizePhone).toSet().toList(),
        'avatar_url': contact.avatarUrl ?? '',
        'matrix_user_id': contact.wrytteUserId ?? '',
        'is_on_wrytte': contact.isOnWrytte,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  Contact _contactFromAccountData(Map raw) {
    final phonesRaw = raw['phones'];
    return Contact(
      displayName: raw['name']?.toString(),
      phones: phonesRaw is List
          ? phonesRaw.map((phone) => _normalizePhone(phone.toString())).toList()
          : <String>[],
      avatarUrl: raw['avatar_url']?.toString(),
      wrytteUserId: raw['matrix_user_id']?.toString(),
      isOnWrytte: raw['is_on_wrytte'] == true,
    );
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }
}
