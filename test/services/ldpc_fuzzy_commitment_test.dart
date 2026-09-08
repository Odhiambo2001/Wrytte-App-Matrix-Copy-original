import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/biometric_api_service.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'client LDPC enrolls and recovers the backend 832-bit contract',
    () async {
      final packed = Uint8List(104);
      packed[0] = 0x80;
      packed[57] = 0x3c;
      packed[103] = 0x01;
      final input = BiometricApiService.unpackLdpcBits(packed);
      final ldpc = LdpcFuzzyCommitment();

      await ldpc.initialize();
      final commitment = ldpc.enrollQuantizedBits(input);
      final enrollmentKey = ldpc.deriveEnrollmentKeyFromQuantizedBits(
        input,
        commitment,
      );
      final recovery = ldpc.recoverQuantizedBits(input, commitment);

      expect(input, hasLength(LdpcFuzzyCommitment.codeN));
      expect(commitment.helper, hasLength(LdpcFuzzyCommitment.codeN));
      expect(commitment.nonce, hasLength(LdpcFuzzyCommitment.codeN));
      expect(
        commitment.toJson()['formatVersion'],
        LdpcFuzzyCommitment.commitmentFormatVersion,
      );
      expect(recovery.accepted, isTrue);
      expect(recovery.derivedKey, enrollmentKey);

      final publicKey = base64Encode(Uint8List(32));
      final serialized = commitment.withSigningPublicKey(publicKey).toJson();
      final restored = FuzzyCommitment.fromJson(serialized);
      expect(restored.signingPublicKey, publicKey);
      expect(
        restored.formatVersion,
        LdpcFuzzyCommitment.commitmentFormatVersion,
      );
      expect(
        () => FuzzyCommitment.fromJson(
          Map<String, dynamic>.from(serialized)..remove('formatVersion'),
        ),
        throwsFormatException,
      );
      expect(
        () => commitment.withSigningPublicKey(base64Encode(Uint8List(31))),
        throwsFormatException,
      );
    },
  );
}
