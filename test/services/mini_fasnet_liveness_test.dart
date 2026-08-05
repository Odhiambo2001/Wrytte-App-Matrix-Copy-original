import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/services/face/mini_fasnet_liveness.dart';

void main() {
  test('class 1 is Real and classes 0 and 2 combine as Fake', () {
    const score = MiniFasNetScore(probabilities: [0.10, 0.80, 0.10]);

    expect(score.realProbability, closeTo(0.80, 1e-12));
    expect(score.fakeProbability, closeTo(0.20, 1e-12));
    expect(score.labelIndex, 1);
    expect(score.isReal, isTrue);
  });

  test('both models must classify the crop as Real', () {
    const result = DualLivenessResult(
      v2: MiniFasNetScore(probabilities: [0.05, 0.90, 0.05]),
      v1se: MiniFasNetScore(probabilities: [0.60, 0.30, 0.10]),
    );

    expect(result.v2.isReal, isTrue);
    expect(result.v1se.isReal, isFalse);
    expect(result.isReal, isFalse);
    expect(result.combinedRealProbability, closeTo(0.30, 1e-12));
  });
}
