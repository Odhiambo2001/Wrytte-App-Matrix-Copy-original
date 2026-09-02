import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:sodium/sodium.dart';

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

class BackendChallengeSignature {
  const BackendChallengeSignature({
    required this.signatureBase64Url,
    required this.challengeBytes,
    required this.signatureBytes,
  });

  final String signatureBase64Url;
  final int challengeBytes;
  final int signatureBytes;
}

/// Local stand-in for the future backend Ed25519 challenge service.
///
/// Enrollment persists only the public key. The private key is reconstructed
/// from the successfully recovered, domain-separated HKDF output and exists
/// only for the duration of signing a fresh challenge.
class LocalFaceSignatureService {
  LocalFaceSignatureService({Future<Sodium>? sodium})
    : _sodium = Future<Sodium>.value(sodium ?? SodiumInit.init());

  static const signingSeedInfo = 'wrytte/kface/ed25519-signing-seed/v1';
  static const challengeDomain = 'wrytte/kface/local-login-challenge/v1';

  final Future<Sodium> _sodium;

  Future<LocalSignatureEnrollment> enroll(String hkdfKeyHex) async {
    final sodium = await _sodium;
    final seed = _deriveSigningSeed(hkdfKeyHex);
    final secureSeed = sodium.secureCopy(seed);
    KeyPair? keyPair;
    try {
      // libsodium crypto_sign_seed_keypair(). The secret key is held in
      // protected native memory and securely erased by dispose().
      keyPair = sodium.crypto.sign.seedKeyPair(secureSeed);
      return LocalSignatureEnrollment(
        publicKeyBase64: base64Encode(keyPair.publicKey),
      );
    } finally {
      keyPair?.dispose();
      secureSeed.dispose();
      seed.fillRange(0, seed.length, 0);
    }
  }

  Future<LocalSignatureVerification> verifyRecoveredKey({
    required String identity,
    required String hkdfKeyHex,
    required String enrolledPublicKeyBase64,
  }) async {
    final sodium = await _sodium;
    final enrolledPublicBytes = base64Decode(enrolledPublicKeyBase64);
    if (enrolledPublicBytes.length != sodium.crypto.sign.publicKeyBytes) {
      throw const FormatException('Invalid enrolled Ed25519 public key.');
    }

    final seed = _deriveSigningSeed(hkdfKeyHex);
    final secureSeed = sodium.secureCopy(seed);
    final challenge = _createChallenge(identity);
    KeyPair? recoveredKeyPair;
    Uint8List? signature;
    try {
      // The corresponding public key is intentionally not persisted at login.
      // libsodium reconstructs the protected secret key from the seed, signs
      // with crypto_sign_detached(), then verifies with the enrolled signup
      // key through crypto_sign_verify_detached().
      recoveredKeyPair = sodium.crypto.sign.seedKeyPair(secureSeed);
      signature = sodium.crypto.sign.detached(
        message: challenge,
        secretKey: recoveredKeyPair.secretKey,
      );
      final verified = sodium.crypto.sign.verifyDetached(
        message: challenge,
        signature: signature,
        publicKey: enrolledPublicBytes,
      );
      return LocalSignatureVerification(
        verified: verified,
        challengeBytes: challenge.length,
        signatureBytes: signature.length,
      );
    } finally {
      signature?.fillRange(0, signature.length, 0);
      recoveredKeyPair?.publicKey.fillRange(
        0,
        recoveredKeyPair.publicKey.length,
        0,
      );
      recoveredKeyPair?.dispose();
      secureSeed.dispose();
      seed.fillRange(0, seed.length, 0);
      challenge.fillRange(0, challenge.length, 0);
      enrolledPublicBytes.fillRange(0, enrolledPublicBytes.length, 0);
    }
  }

  Future<BackendChallengeSignature> signBackendChallenge({
    required String hkdfKeyHex,
    required String challengeBase64Url,
  }) async {
    final sodium = await _sodium;
    final seed = _deriveSigningSeed(hkdfKeyHex);
    final secureSeed = sodium.secureCopy(seed);
    final challenge = base64Url.decode(base64Url.normalize(challengeBase64Url));
    KeyPair? recoveredKeyPair;
    Uint8List? signature;
    try {
      recoveredKeyPair = sodium.crypto.sign.seedKeyPair(secureSeed);
      signature = sodium.crypto.sign.detached(
        message: Uint8List.fromList(challenge),
        secretKey: recoveredKeyPair.secretKey,
      );
      return BackendChallengeSignature(
        signatureBase64Url: base64UrlEncode(signature),
        challengeBytes: challenge.length,
        signatureBytes: signature.length,
      );
    } finally {
      signature?.fillRange(0, signature.length, 0);
      recoveredKeyPair?.publicKey.fillRange(
        0,
        recoveredKeyPair.publicKey.length,
        0,
      );
      recoveredKeyPair?.dispose();
      secureSeed.dispose();
      seed.fillRange(0, seed.length, 0);
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
}
