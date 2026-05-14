import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wrytte/local_user_service.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';


class UserSearchService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Search Firebase users by phone number and return phone -> uid.
  /// Optimized: single query per batch using only the 'phone' field.
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

      // Separate phones from Wrytte IDs
      final phones = allIdentifiers
          .where((p) => p.startsWith('+'))
          .map(_normalizePhone)
          .where((p) => p.length >= 10)
          .toSet()
          .toList();

      final wrytteIds = allIdentifiers
          .where((p) => _looksLikeWrytteId(p))
          .toSet()
          .toList();

      final result = <String, String>{};
      await _searchMatrixDirectory(allIdentifiers, result);
      final localService = LocalUserService();
        final localResult = await localService.getUsers(phones);
        result.addAll(localResult);

        final missingPhones = phones
            .where((p) => !localResult.containsKey(p))
            .toList();

        for (var i = 0; i < missingPhones.length; i += 10) {
          final chunk = missingPhones.skip(i).take(10).toList();

          try {
            final snapshot = await _firestore
                .collection('users')
                .where('phone', whereIn: chunk)
                .get();

            for (final doc in snapshot.docs) {
              final userId = _resolveUserId(doc);
              final phone = doc.data()['phone']?.toString();

              if (phone != null && phone.isNotEmpty) {
                final normalized = _normalizePhone(phone);

                _addLookupKeys(result, normalized, userId);

                await localService.saveUser(normalized, userId);
              }
            }
          } catch (e) {
            debugPrint('Phone chunk query failed: $e');
          }
        }

      // ── Single field query for Wrytte IDs ─────────────────────
      // Only query uid field — Matrix user IDs
      for (var i = 0; i < wrytteIds.length; i += 10) {
        final chunk = wrytteIds.skip(i).take(10).toList();
        try {
          final snapshot = await _firestore
              .collection('users')
              .where('uid', whereIn: chunk)
              .get();

          for (final doc in snapshot.docs) {
            final userId = _resolveUserId(doc);
            final id = doc.data()['uid']?.toString();
            if (id != null && id.isNotEmpty) {
              _addLookupKeys(result, id, userId);
            }
          }
        } catch (e) {
          debugPrint('WrytteId chunk query failed: $e');
        }
      }

      return result;
    } catch (e) {
      debugPrint('Firebase user search failed: $e');
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
    if (!cleaned.startsWith('+')) return cleaned;
    return cleaned;
  }

  void _addLookupKeys(
      Map<String, String> result, String value, String userId) {
    final trimmed = value.trim();
    final normalized = _normalizePhone(trimmed);

    result[trimmed] = userId;
    result[normalized] = userId;

    if (normalized.startsWith('+')) {
      result[normalized.substring(1)] = userId;
    }
  }

  bool _looksLikeWrytteId(String value) {
    return !value.startsWith('+') && RegExp(r'^\d{4,}$').hasMatch(value);
  }

  String _resolveUserId(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    return data['matrixUserId']?.toString() ??
        data['openImUserId']?.toString() ??
        data['userId']?.toString() ??
        data['uid']?.toString() ??
        doc.id;
  }
}
