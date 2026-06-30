import 'package:flutter/foundation.dart';
import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class ContactBackendService {
  ContactBackendService._();
  static final ContactBackendService instance = ContactBackendService._();

  Future<void> saveContact({
    required String ownerUserId,
    required Contact contact,
  }) async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    final query = _contactQuery(contact);
    await ApiService.post(
      '/api/UserContacts/add',
      queryParameters: query,
      token: token,
    );
  }

  Future<List<Contact>> loadContacts({required String ownerUserId}) async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) return const [];

    try {
      final response = await ApiService.get(
        '/api/UserContacts/getall',
        token: token,
      );
      return _contactsFromResponse(response);
    } catch (e) {
      debugPrint('[ContactBackendService] load contacts failed: $e');
      return const [];
    }
  }

  Future<void> removeContact({
    required String ownerUserId,
    required Contact contact,
  }) async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    final userId = _contactUserId(contact);
    if (userId.isEmpty) throw Exception('Missing contact userId.');
    await ApiService.post(
      '/api/UserContacts/remove',
      queryParameters: {'userId': userId},
      token: token,
    );
  }

  Future<void> updateContactName({
    required String ownerUserId,
    required Contact contact,
    required String name,
  }) async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    final userId = _contactUserId(contact);
    if (userId.isEmpty) throw Exception('Missing contact userId.');
    await ApiService.post(
      '/api/UserContacts/update',
      queryParameters: {'userId': userId, 'name': name.trim()},
      token: token,
    );
  }

  Map<String, dynamic> _contactQuery(Contact contact) {
    final userId = _contactUserId(contact);
    if (userId.isEmpty) throw Exception('Missing contact userId.');
    return {'userId': userId, 'name': contact.displayName?.trim() ?? ''};
  }

  String _contactUserId(Contact contact) {
    final id = contact.wrytteUserId?.trim() ?? '';
    if (id.startsWith('@') && id.contains(':')) {
      return id.substring(1, id.indexOf(':'));
    }
    return id;
  }

  List<Contact> _contactsFromResponse(dynamic response) {
    final raw =
        response is Map
            ? response['contacts'] ??
                response['Contacts'] ??
                response['savedContacts'] ??
                response['SavedContacts'] ??
                response['data'] ??
                response['results']
            : response;
    if (raw is! List) return const [];

    return raw
        .map(_contactFromRaw)
        .whereType<Contact>()
        .map((contact) => contact.copyWith(isSaved: true))
        .toList();
  }

  Contact? _contactFromRaw(Object? entry) {
    if (entry is! Map) return null;
    final map = entry.map((key, value) => MapEntry(key.toString(), value));
    final phones =
        <String>[
              _field(map, const [
                'phone',
                'Phone',
                'primaryPhone',
                'PrimaryPhone',
              ]),
              ..._phoneList(map['phones'] ?? map['Phones']),
            ]
            .map(_normalizePhone)
            .where((phone) => phone.trim().isNotEmpty)
            .toSet()
            .toList();

    final wrytteUserId = _field(map, const [
      'wrytteUserId',
      'WrytteUserId',
      'matrixUserId',
      'MatrixUserId',
      'userid',
      'Userid',
      'userId',
      'UserId',
    ]);
    if (phones.isEmpty && wrytteUserId.isEmpty) return null;

    return Contact(
      displayName: _field(map, const [
        'displayName',
        'DisplayName',
        'name',
        'Name',
        'savedName',
        'SavedName',
      ]),
      phones: phones,
      avatarUrl: _field(map, const [
        'avatarUrl',
        'AvatarUrl',
        'avatar',
        'AvatarImg',
        'profileImage',
      ]),
      bio: _field(map, const ['bio', 'Bio']),
      isOnWrytte: _boolField(map, const ['isOnWrytte', 'IsOnWrytte']),
      wrytteUserId: wrytteUserId.isEmpty ? null : wrytteUserId,
      isSaved: true,
    );
  }

  String _field(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
    }
    return '';
  }

  List<String> _phoneList(Object? raw) {
    if (raw is List) return raw.map((phone) => phone.toString()).toList();
    return const [];
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }

  bool _boolField(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is bool) return value;
      final text = value?.toString().toLowerCase();
      if (text == 'true') return true;
      if (text == 'false') return false;
    }
    return false;
  }
}
