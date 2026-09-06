import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

class LocalSignatureEnrollment {
  const LocalSignatureEnrollment({required this.publicKeyBase64});

  final String publicKeyBase64;
}

class LocalSignatureVerification {
  const LocalSignatureVerification({
    required this.verified,
    required this.challengeBytes,
    required this.signatureBytes,
  });

  final bool verified;
  final int challengeBytes;
  final int signatureBytes;
}

/// Local stand-in for the future backend Ed25519 challenge service.
///
/// Enrollment persists only the public key. The private key is reconstructed
/// from the successfully recovered, domain-separated HKDF output and exists
/// only for the duration of signing a fresh challenge.
class LocalFaceSignatureService {
  LocalFaceSignatureService({Ed25519? algorithm})
    : _algorithm = algorithm ?? Ed25519();

  static const signingSeedInfo = 'wrytte/kface/ed25519-signing-seed/v1';
  static const challengeDomain = 'wrytte/kface/local-login-challenge/v1';

  final Ed25519 _algorithm;

  Future<LocalSignatureEnrollment> enroll(String hkdfKeyHex) async {
    final seed = _deriveSigningSeed(hkdfKeyHex);
    try {
      final keyPair = await _algorithm.newKeyPairFromSeed(seed);
      final publicKey = await keyPair.extractPublicKey();
      return LocalSignatureEnrollment(
        publicKeyBase64: base64Encode(publicKey.bytes),
      );
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  /// Signs the backend's fresh, short-lived challenge with the private key
  /// reconstructed from local LDPC recovery. The seed, challenge, and
  /// signature are never persisted or logged.
  Future<String> signBackendChallenge({
    required String hkdfKeyHex,
    required String challengeBase64Url,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,256}$').hasMatch(challengeBase64Url)) {
      throw const FormatException('Invalid sign-in challenge.');
    }
    final challenge = _base64UrlDecode(challengeBase64Url);
    if (challenge.length != 32) {
      challenge.fillRange(0, challenge.length, 0);
      throw const FormatException('Invalid sign-in challenge.');
    }
    final seed = _deriveSigningSeed(hkdfKeyHex);
    try {
      final keyPair = await _algorithm.newKeyPairFromSeed(seed);
      final signature = await _algorithm.sign(challenge, keyPair: keyPair);
      if (signature.bytes.length != 64) {
        throw StateError('Invalid Ed25519 signature.');
      }
      return base64UrlEncode(signature.bytes).replaceAll('=', '');
    } finally {
      seed.fillRange(0, seed.length, 0);
      challenge.fillRange(0, challenge.length, 0);
    }
  }

  Future<LocalSignatureVerification> verifyRecoveredKey({
    required String identity,
    required String hkdfKeyHex,
    required String enrolledPublicKeyBase64,
  }) async {
    final enrolledPublicBytes = base64Decode(enrolledPublicKeyBase64);
    if (enrolledPublicBytes.length != 32) {
      throw const FormatException('Invalid enrolled Ed25519 public key.');
    }

    final seed = _deriveSigningSeed(hkdfKeyHex);
    final challenge = _createChallenge(identity);
    try {
      // The corresponding public key is intentionally not persisted at login.
      // Only the reconstructed private key is used to sign this challenge.
      final recoveredKeyPair = await _algorithm.newKeyPairFromSeed(seed);
      final signature = await _algorithm.sign(
        challenge,
        keyPair: recoveredKeyPair,
      );
      final verified = await _algorithm.verify(
        challenge,
        signature: Signature(
          signature.bytes,
          publicKey: SimplePublicKey(
            enrolledPublicBytes,
            type: KeyPairType.ed25519,
          ),
        ),
      );
      return LocalSignatureVerification(
        verified: verified,
        challengeBytes: challenge.length,
        signatureBytes: signature.bytes.length,
      );
    } finally {
      seed.fillRange(0, seed.length, 0);
      challenge.fillRange(0, challenge.length, 0);
    }
  }

  Uint8List _deriveSigningSeed(String hkdfKeyHex) {
    if (hkdfKeyHex.length != 64 ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hkdfKeyHex)) {
      throw const FormatException('Expected a 32-byte HKDF key.');
    }
    final hkdfKey = Uint8List(32);
    for (var index = 0; index < hkdfKey.length; index++) {
      hkdfKey[index] = int.parse(
        hkdfKeyHex.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    try {
      return Uint8List.fromList(
        hashes.Hmac(
          hashes.sha256,
          hkdfKey,
        ).convert(utf8.encode(signingSeedInfo)).bytes,
      );
    } finally {
      hkdfKey.fillRange(0, hkdfKey.length, 0);
    }
  }

  Uint8List _createChallenge(String identity) {
    final random = Random.secure();
    final nonce = List<int>.generate(32, (_) => random.nextInt(256));
    return Uint8List.fromList([
      ...utf8.encode(challengeDomain),
      0,
      ...utf8.encode(identity.replaceAll(RegExp(r'[^\d]'), '')),
      0,
      ...nonce,
    ]);
  }

  Uint8List _base64UrlDecode(String encoded) {
    final padding = '=' * ((4 - encoded.length % 4) % 4);
    return Uint8List.fromList(base64Url.decode('$encoded$padding'));
  }
}
