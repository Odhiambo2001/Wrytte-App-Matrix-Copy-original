import 'package:flutter/material.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';


class UserSearchService {
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
      final allIdentifiers = phonesToSend
          .split('|')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toSet()
          .toList();

      final lookupQueries = allIdentifiers
          .expand((identifier) => _matrixLookupQueries(identifier))
          .toSet()
          .toList();

      final result = <String, String>{};
      await _searchMatrixDirectory(lookupQueries, result);
      return result;
    } catch (e) {
      debugPrint('Matrix user search failed: $e');
      throw Exception("User search error: $e");
    }
  }

  Future<void> _searchMatrixDirectory(
    List<String> identifiers,
    Map<String, String> result,
  ) async {
    try {
      await MatrixAuthService.instance.restore();
      final client = MatrixClientService.instance.client;
      if (!client.isLogged()) return;

      for (final identifier in identifiers) {
        final query = identifier.trim();
        if (query.length < 3) continue;
        final response = await client.searchUserDirectory(query, limit: 10);
        for (final user in response.results) {
          final userId = user.userId;
          result[query] = userId;
          if (userId.startsWith('@')) {
            result[userId] = userId;
            result[userId.split(':').first.substring(1)] = userId;
          }
        }
      }
    } catch (e) {
      debugPrint('Matrix user directory search failed: $e');
    }
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }

  Iterable<String> _matrixLookupQueries(String identifier) sync* {
    final trimmed = identifier.trim();
    if (trimmed.isEmpty) return;
    yield trimmed;
    final digits = trimmed.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length >= 6) {
      yield _normalizePhone(digits);
      yield digits;
    }
  }
}
