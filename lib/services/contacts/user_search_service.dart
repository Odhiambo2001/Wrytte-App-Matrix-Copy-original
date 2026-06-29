import 'dart:async';

import 'package:wrytte/services/contacts/contact_directory_service.dart';

class UserSearchService {
  static const registeredWithoutMatrixId =
      '__wrytte_registered_without_matrix_id__';

  final Map<String, _LookupCacheEntry> _cache = {};
  final ContactDirectoryService _directory = ContactDirectoryService.instance;

  /// Search the Matrix user directory by phone/Wrytte ID and return
  /// identifier -> Matrix user ID.
  Future<Map<String, String>> searchUsersByPhones({
    List<String>? phoneNumbersA,
    String? phoneNumbersC,
    required String token,
  }) async {
    String? phonesToSend;

    if (phoneNumbersC != null && phoneNumbersC.isNotEmpty) {
      phonesToSend = phoneNumbersC;
    } else if (phoneNumbersA != null && phoneNumbersA.isNotEmpty) {
      phonesToSend = phoneNumbersA.join('|');
    } else {
      return {};
    }

    try {
      final allIdentifiers =
          phonesToSend
              .split('|')
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toSet()
              .toList();

      final result = <String, String>{};
      final pendingDirectory = <String, String>{};
      for (final identifier in allIdentifiers) {
        final normalized = _normalizeLookupIdentifier(identifier);
        final cached = _readCache(normalized);
        if (cached != null) {
          _addLookupKeys(result, identifier, cached);
          continue;
        }

        final digits = _digitsOnly(normalized);
        if (digits.length >= 7) {
          pendingDirectory[normalized] = identifier;
        }
      }

      if (pendingDirectory.isNotEmpty) {
        final resolved = await _directory.resolvePhones(pendingDirectory.keys);
        for (final entry in pendingDirectory.entries) {
          final phone = entry.key;
          final identifier = entry.value;
          final directoryResult =
              resolved[phone] ?? resolved[_digitsOnly(phone)];
          if (directoryResult != null && directoryResult.isOnWrytte) {
            final resolvedUserId =
                directoryResult.matrixUserId ??
                directoryResult.userId ??
                registeredWithoutMatrixId;
            _writeCache(phone, resolvedUserId);
            _addLookupKeys(result, identifier, resolvedUserId);
          }
        }
      }
      return result;
    } on ContactDirectoryUnavailable {
      rethrow;
    } on TimeoutException {
      throw const ContactDirectoryUnavailable(
        'Wrytte contact search timed out.',
      );
    } catch (e) {
      throw Exception("User search error: $e");
    }
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

  String _normalizeLookupIdentifier(String identifier) {
    final trimmed = identifier.trim();
    final digits = trimmed.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length >= 6) return _normalizePhone(digits);
    return trimmed;
  }

  void _addLookupKeys(
    Map<String, String> result,
    String identifier,
    String userId,
  ) {
    final trimmed = identifier.trim();
    if (trimmed.isEmpty || userId.isEmpty) return;

    result[trimmed] = userId;
    final normalized = _normalizeLookupIdentifier(trimmed);
    result[normalized] = userId;

    final digits = normalized.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isNotEmpty) result[digits] = userId;
    if (normalized.startsWith('+')) result[normalized.substring(1)] = userId;
  }

  String _digitsOnly(String identifier) =>
      identifier.replaceAll(RegExp(r'[^\d]'), '');

  String? _readCache(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.createdAt) >
        const Duration(minutes: 5)) {
      _cache.remove(key);
      return null;
    }
    return entry.userId;
  }

  void _writeCache(String key, String userId) {
    if (key.isEmpty || userId.isEmpty) return;
    _cache[key] = _LookupCacheEntry(userId: userId, createdAt: DateTime.now());
  }
}

class _LookupCacheEntry {
  final String userId;
  final DateTime createdAt;

  const _LookupCacheEntry({required this.userId, required this.createdAt});
}
