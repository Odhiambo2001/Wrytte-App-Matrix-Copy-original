import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/ldpc_fuzzy_commitment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('enrolls and recovers the same normalized embedding', () async {
    final ldpc = LdpcFuzzyCommitment();
    await ldpc.initialize();
    final embedding = _normalizedEmbedding();

    final commitment = ldpc.enroll(embedding);
    final recovery = ldpc.recover(embedding, commitment);

    expect(commitment.helper, hasLength(LdpcFuzzyCommitment.codeN));
    expect(recovery.syndromePassed, isTrue);
    expect(recovery.hashMatched, isTrue);
    expect(recovery.accepted, isTrue);
    expect(recovery.recoveredHash, commitment.keyHash);
    expect(
      recovery.derivedKey,
      ldpc.deriveEnrollmentKey(embedding, commitment),
    );
  });

  test('packed commitment metadata round-trips without losing bits', () async {
    final ldpc = LdpcFuzzyCommitment();
    await ldpc.initialize();
    final commitment = ldpc.enroll(_normalizedEmbedding());

    final restored = FuzzyCommitment.fromJson(commitment.toJson());

    expect(restored.helper, orderedEquals(commitment.helper));
    expect(restored.nonce, orderedEquals(commitment.nonce));
    expect(restored.keyHash, commitment.keyHash);
    expect(restored.kdfSalt, orderedEquals(commitment.kdfSalt));
  });

  test('quantization matches NumPy ties-to-even Gray coding', () {
    final embedding = Float32List(LdpcFuzzyCommitment.embeddingDimension);
    // After scaling and mapping, these produce levels 0, 3.5 and 7.
    embedding[0] = -0.2;
    embedding[1] = 0;
    embedding[2] = 0.2;
    final bits = LdpcFuzzyCommitment().embeddingToBitVector(embedding);

    expect(bits.sublist(0, 9), orderedEquals([0, 0, 0, 1, 1, 0, 1, 0, 0]));
    expect(bits, hasLength(1536));
  });

  test('recovery rejects a valid syndrome when stored hash differs', () async {
    final ldpc = LdpcFuzzyCommitment();
    await ldpc.initialize();
    final embedding = _normalizedEmbedding();
    final enrolled = ldpc.enroll(embedding);
    final altered = FuzzyCommitment(
      helper: enrolled.helper,
      nonce: enrolled.nonce,
      keyHash: List.filled(32, '00').join(),
      kdfSalt: enrolled.kdfSalt,
      quantScale: enrolled.quantScale,
    );

    final recovery = ldpc.recover(embedding, altered);
    expect(recovery.syndromePassed, isTrue);
    expect(recovery.hashMatched, isFalse);
    expect(recovery.accepted, isFalse);
  });
}

Float32List _normalizedEmbedding() {
  final values = List<double>.generate(
    LdpcFuzzyCommitment.embeddingDimension,
    (index) => math.sin(index * 0.17) + math.cos(index * 0.07),
  );
  final norm = math.sqrt(
    values.fold<double>(0, (sum, value) => sum + value * value),
  );
  return Float32List.fromList(values.map((value) => value / norm).toList());
}
