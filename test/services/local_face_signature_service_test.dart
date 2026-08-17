import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/local_face_signature_service.dart';

void main() {
  const recoveredHkdfKey =
      '000102030405060708090a0b0c0d0e0f'
      '101112131415161718191a1b1c1d1e1f';

  test(
    'recovered HKDF key signs a challenge verified by enrollment key',
    () async {
      final service = LocalFaceSignatureService();
      final enrollment = await service.enroll(recoveredHkdfKey);

      final result = await service.verifyRecoveredKey(
        identity: '+00 700 297 347',
        hkdfKeyHex: recoveredHkdfKey,
        enrolledPublicKeyBase64: enrollment.publicKeyBase64,
      );

      expect(result.verified, isTrue);
      expect(result.signatureBytes, 64);
      expect(result.challengeBytes, greaterThan(32));
    },
  );

  test('different recovered HKDF key cannot satisfy enrollment key', () async {
    final service = LocalFaceSignatureService();
    final enrollment = await service.enroll(recoveredHkdfKey);
    const differentHkdfKey =
        'ffffffffffffffffffffffffffffffff'
        'ffffffffffffffffffffffffffffffff';

    final result = await service.verifyRecoveredKey(
      identity: '00700297347',
      hkdfKeyHex: differentHkdfKey,
      enrolledPublicKeyBase64: enrollment.publicKeyBase64,
    );

    expect(result.verified, isFalse);
  });
}
