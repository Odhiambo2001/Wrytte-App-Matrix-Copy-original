import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';

class FaceCommitmentStore {
  const FaceCommitmentStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<FuzzyCommitment?> read(String identity) async {
    final value = await _storage.read(key: _key(identity));
    if (value == null || value.isEmpty) return null;
    return FuzzyCommitment.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> write(String identity, FuzzyCommitment commitment) {
    return _storage.write(
      key: _key(identity),
      value: jsonEncode(commitment.toJson()),
    );
  }

  String _key(String identity) =>
      'kface_ldpc_${base64Url.encode(utf8.encode(identity)).replaceAll('=', '')}';
}
