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

    final body = _contactBody(ownerUserId: ownerUserId, contact: contact);
    await _sendFirstSuccessful(
      action: 'save contact',
      requests: [
        () =>
            ApiService.postJson('/api/Contacts/save', body: body, token: token),
        () =>
            ApiService.postJson('/api/Contact/save', body: body, token: token),
        () => ApiService.postJson(
          '/api/UserContacts/save',
          body: body,
          token: token,
        ),
        () => ApiService.postJson(
          '/api/Users/Contacts/save',
          body: body,
          token: token,
        ),
        () => ApiService.postMultipart(
          '/api/Contacts/save',
          body.map((key, value) => MapEntry(key, value?.toString() ?? '')),
          token: token,
        ),
      ],
    );
  }

  Future<List<Contact>> loadContacts({required String ownerUserId}) async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) return const [];

    final query = {
      'ownerUserId': ownerUserId,
      'userid': ownerUserId,
      'userId': ownerUserId,
    };
    final candidates = [
      () => ApiService.get(
        '/api/Contacts/get',
        token: token,
        queryParameters: query,
      ),
      () =>
          ApiService.get('/api/Contacts', token: token, queryParameters: query),
      () => ApiService.get(
        '/api/UserContacts/get',
        token: token,
        queryParameters: query,
      ),
      () => ApiService.get(
        '/api/Users/Contacts',
        token: token,
        queryParameters: query,
      ),
    ];

    for (final request in candidates) {
      try {
        final response = await request();
        final contacts = _contactsFromResponse(response);
        if (contacts.isNotEmpty) return contacts;
      } catch (e) {
        debugPrint('[ContactBackendService] load contact endpoint skipped: $e');
      }
    }
    return const [];
  }

  Map<String, dynamic> _contactBody({
    required String ownerUserId,
    required Contact contact,
  }) {
    return {
      'ownerUserId': ownerUserId,
      'userid': ownerUserId,
      'userId': ownerUserId,
      'name': contact.displayName ?? '',
      'displayName': contact.displayName ?? '',
      'phone': contact.primaryPhone,
      'phones': contact.phones,
      'avatarUrl': contact.avatarUrl ?? '',
      'avatar': contact.avatarUrl ?? '',
      'bio': contact.bio ?? '',
      'wrytteUserId': contact.wrytteUserId ?? '',
      'matrixUserId': contact.wrytteUserId ?? '',
      'isOnWrytte': contact.isOnWrytte,
      'isSaved': true,
    };
  }

  Future<void> _sendFirstSuccessful({
    required String action,
    required List<Future<dynamic> Function()> requests,
  }) async {
    Object? lastError;
    for (final request in requests) {
      try {
        await request();
        return;
      } catch (e) {
        lastError = e;
        debugPrint('[ContactBackendService] $action endpoint skipped: $e');
      }
    }
    throw Exception('Could not $action on backend: $lastError');
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
          _field(map, const ['phone', 'Phone', 'primaryPhone', 'PrimaryPhone']),
          ..._phoneList(map['phones'] ?? map['Phones']),
        ].where((phone) => phone.trim().isNotEmpty).toSet().toList();

    final wrytteUserId = _field(map, const [
      'wrytteUserId',
      'WrytteUserId',
      'matrixUserId',
      'MatrixUserId',
      'userid',
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
