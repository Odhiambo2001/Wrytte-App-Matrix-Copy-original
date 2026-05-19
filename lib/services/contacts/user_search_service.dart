import 'package:flutter/material.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

class UserSearchService {
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

    final identifiers = phonesToSend
        .split('|')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList();

    final result = <String, String>{};

    try {
      await MatrixAuthService.instance.restore();
      final client = MatrixClientService.instance.client;
      if (!client.isLogged()) return result;

      for (final identifier in identifiers) {
        final digits = identifier.replaceAll(RegExp(r'[^\d]'), '');
        if (digits.length < 7) continue;

        final matrixUserId = '@$digits:${MatrixConfig.serverName}';

        try {
          await client.getUserProfile(matrixUserId);
          result[identifier] = matrixUserId;
          debugPrint('[UserSearchService] Found: $identifier → $matrixUserId');
        } catch (_) {
          debugPrint('[UserSearchService] Not found: $identifier');
        }
      }
    } catch (e) {
      debugPrint('[UserSearchService] Search failed: $e');
      throw Exception('User search error: $e');
    }

    return result;
  }
}
