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
  });

  test('packed commitment metadata round-trips without losing bits', () async {
    final ldpc = LdpcFuzzyCommitment();
    await ldpc.initialize();
    final commitment = ldpc.enroll(_normalizedEmbedding());

    final restored = FuzzyCommitment.fromJson(commitment.toJson());

    expect(restored.helper, orderedEquals(commitment.helper));
    expect(restored.nonce, orderedEquals(commitment.nonce));
    expect(restored.keyHash, commitment.keyHash);
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
