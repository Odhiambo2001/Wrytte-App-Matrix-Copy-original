import 'package:flutter/foundation.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

class WrytteContactResolution {
  final String phone;
  final bool isOnWrytte;
  final String? userId;
  final String? matrixUserId;
  final String? displayName;
  final String? avatarUrl;

  const WrytteContactResolution({
    required this.phone,
    required this.isOnWrytte,
    this.userId,
    this.matrixUserId,
    this.displayName,
    this.avatarUrl,
  });
}

class ContactDirectoryUnavailable implements Exception {
  final String message;

  const ContactDirectoryUnavailable(this.message);

  @override
  String toString() => message;
}

class ContactDirectoryService {
  ContactDirectoryService._();
  static final ContactDirectoryService instance = ContactDirectoryService._();

  static const _searchPath = '/api/Users/Search';
  DateTime? _disabledUntil;

  Future<Map<String, WrytteContactResolution>> resolvePhones(
    Iterable<String> phones,
  ) async {
    final normalizedPhones =
        phones
            .map(_normalizePhone)
            .where(
              (phone) => phone.replaceAll(RegExp(r'[^\d]'), '').length >= 7,
            )
            .toSet()
            .toList();
    if (normalizedPhones.isEmpty) return {};

    final disabledUntil = _disabledUntil;
    if (disabledUntil != null && DateTime.now().isBefore(disabledUntil)) {
      throw const ContactDirectoryUnavailable(
        'Wrytte contact search endpoint is not available.',
      );
    }

    try {
      final token = await AuthService.instance.getValidBackendToken();
      if (!_hasUsableBackendToken(token)) {
        throw StateError(
          'Wrytte backend session is missing. Please sign in again.',
        );
      }
      final backendPhones =
          normalizedPhones
              .expand(_backendPhoneCandidates)
              .where((phone) => phone.isNotEmpty)
              .toSet()
              .toList();
      final response = await _postSearch({
        'phoneNumbersC': backendPhones.join('|'),
      }, token: token);
      return _parseResponse(response, normalizedPhones, backendPhones);
    } on ApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 405 || e.statusCode == 501) {
        _disabledUntil = DateTime.now().add(const Duration(minutes: 10));
        throw const ContactDirectoryUnavailable(
          'Wrytte contact search endpoint is not available.',
        );
      }
      debugPrint('[ContactDirectory] resolve failed: $e');
      rethrow;
    }
  }

  Future<dynamic> _postSearch(
    Map<String, String> fields, {
    required String? token,
  }) async {
    return ApiService.postMultipart(_searchPath, fields, token: token);
  }

  Map<String, WrytteContactResolution> _parseResponse(
    dynamic response,
    List<String> requestedPhones,
    List<String> backendPhones,
  ) {
    final output = <String, WrytteContactResolution>{};
    if (response is! Map) return output;

    final contactsRaw = response['contacts'] ?? response['results'] ?? response;

    if (contactsRaw is List) {
      for (final item in contactsRaw.whereType<Map>()) {
        final resolution = _resolutionFromMap(item);
        if (resolution != null) {
          _addResolution(output, resolution);
        }
      }
    } else if (contactsRaw is Map) {
      for (final entry in contactsRaw.entries) {
        final keyPhone = _normalizePhone(entry.key.toString());
        final value = entry.value;
        if (value is Map) {
          final resolution = _resolutionFromMap(value, fallbackPhone: keyPhone);
          if (resolution != null) {
            _addResolution(output, resolution);
          }
        } else if (value is bool) {
          _addResolution(
            output,
            WrytteContactResolution(phone: keyPhone, isOnWrytte: value),
          );
        } else if (value != null && value.toString().trim().isNotEmpty) {
          final userId = value.toString().trim();
          _addResolution(
            output,
            WrytteContactResolution(
              phone: keyPhone,
              isOnWrytte: true,
              userId: userId,
              matrixUserId: _toMatrixUserId(userId),
            ),
          );
        }
      }
    }

    for (final phone in [...requestedPhones, ...backendPhones]) {
      output.putIfAbsent(
        _normalizePhone(phone),
        () => WrytteContactResolution(
          phone: _normalizePhone(phone),
          isOnWrytte: false,
        ),
      );
    }
    return output;
  }

  WrytteContactResolution? _resolutionFromMap(
    Map raw, {
    String? fallbackPhone,
  }) {
    final phone = _normalizePhone(
      (raw['phone'] ??
              raw['phoneNumber'] ??
              raw['msisdn'] ??
              raw['identifier'] ??
              fallbackPhone ??
              '')
          .toString(),
    );
    if (phone.isEmpty) return null;

    final matrixUserId = _stringValue(
      raw['matrixUserId'] ??
          raw['matrix_user_id'] ??
          raw['mxid'] ??
          raw['matrixId'],
    );
    final userId = _stringValue(
      raw['userId'] ?? raw['userid'] ?? raw['uid'] ?? raw['id'],
    );
    final isOnWrytte =
        raw['isOnWrytte'] == true ||
        raw['registered'] == true ||
        raw['exists'] == true ||
        matrixUserId != null ||
        userId != null;

    return WrytteContactResolution(
      phone: phone,
      isOnWrytte: isOnWrytte,
      userId: userId,
      matrixUserId: matrixUserId,
      displayName: _stringValue(
        raw['displayName'] ?? raw['name'] ?? raw['username'],
      ),
      avatarUrl: _resolveAvatarUrl(
        _stringValue(
          raw['AvatarImg'] ??
              raw['avatarImg'] ??
              raw['avatarUrl'] ??
              raw['avatar_url'],
        ),
      ),
    );
  }

  void _addResolution(
    Map<String, WrytteContactResolution> output,
    WrytteContactResolution resolution,
  ) {
    output[resolution.phone] = resolution;
    final digits = resolution.phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isNotEmpty) output[digits] = resolution;
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
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

  Iterable<String> _backendPhoneCandidates(String phone) sync* {
    final normalized = _normalizePhone(phone);
    final digits = normalized.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return;

    yield digits;
    yield normalized;

    if (digits.startsWith('254') && digits.length == 12) {
      yield '0${digits.substring(3)}';
    }
  }

  String _toMatrixUserId(String userId) {
    final trimmed = userId.trim();
    if (trimmed.startsWith('@') && trimmed.contains(':')) return trimmed;
    final localpart = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._=-]'), '');
    return '@$localpart:${MatrixConfig.serverName}';
  }

  String? _stringValue(Object? value) {
    final string = value?.toString().trim();
    return string == null || string.isEmpty ? null : string;
  }

  String? _resolveAvatarUrl(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) return trimmed;
    if (trimmed.startsWith('/')) return '${ApiService.baseUrl}$trimmed';
    return '${ApiService.baseUrl}/$trimmed';
  }

  bool _hasUsableBackendToken(String? token) {
    if (token == null || token.trim().isEmpty) return false;
    return token.trim().split('.').length == 3;
  }
}
