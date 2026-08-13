import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';

class FaceCommitmentStore {
  const FaceCommitmentStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<FuzzyCommitment?> read(String identity) async {
    final canonicalKey = _key(identity);
    var value = await _storage.read(key: canonicalKey);
    if (value == null || value.isEmpty) {
      // Migrate commitments enrolled before Wrytte IDs were canonicalized.
      for (final legacyIdentity in _legacyIdentities(identity)) {
        final legacyKey = _legacyKey(legacyIdentity);
        if (legacyKey == canonicalKey) continue;
        value = await _storage.read(key: legacyKey);
        if (value != null && value.isNotEmpty) {
          await _storage.write(key: canonicalKey, value: value);
          await _storage.delete(key: legacyKey);
          break;
        }
      }
    }
    if (value == null || value.isEmpty) return null;
    return FuzzyCommitment.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> write(String identity, FuzzyCommitment commitment) {
    return _storage.write(
      key: _key(identity),
      value: jsonEncode(commitment.toJson()),
    );
  }

  String _key(String identity) => _legacyKey(_canonicalIdentity(identity));

  String _legacyKey(String identity) =>
      'kface_ldpc_${base64Url.encode(utf8.encode(identity)).replaceAll('=', '')}';

  String _canonicalIdentity(String identity) =>
      identity.replaceAll(RegExp(r'[^\d]'), '');

  Iterable<String> _legacyIdentities(String identity) sync* {
    yield identity;
    final digits = _canonicalIdentity(identity);
    yield digits;
    yield '+$digits';
    if (digits.startsWith('00') && digits.length > 2) {
      final body = digits.substring(2);
      final groups = <String>[];
      for (var offset = 0; offset < body.length; offset += 3) {
        groups.add(body.substring(offset, (offset + 3).clamp(0, body.length)));
      }
      yield '+00 ${groups.join(' ')}';
    }
  }
}
