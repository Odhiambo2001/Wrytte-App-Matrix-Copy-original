import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

class FuzzyCommitment {
  const FuzzyCommitment({
    required this.helper,
    required this.nonce,
    required this.keyHash,
    required this.kdfSalt,
    this.quantScale = LdpcFuzzyCommitment.quantScale,
  });

  final Uint8List helper;
  final Uint8List nonce;
  final String keyHash;
  final Uint8List kdfSalt;
  final int quantScale;

  Map<String, dynamic> toJson() => {
    'helper': _pack(helper),
    'helperLength': helper.length,
    'nonce': _pack(nonce),
    'nonceLength': nonce.length,
    'keyHash': keyHash,
    'kdfSalt': base64Encode(kdfSalt),
    'kdf': LdpcFuzzyCommitment.kdfAlgorithm,
    'quantScale': quantScale,
  };

  factory FuzzyCommitment.fromJson(Map<String, dynamic> json) {
    return FuzzyCommitment(
      helper: _unpack(json['helper'] as String, json['helperLength'] as int),
      nonce: _unpack(json['nonce'] as String, json['nonceLength'] as int),
      keyHash: json['keyHash'] as String,
      kdfSalt:
          json['kdfSalt'] == null
              ? Uint8List(0)
              : base64Decode(json['kdfSalt'] as String),
      quantScale: json['quantScale'] as int? ?? LdpcFuzzyCommitment.quantScale,
    );
  }

  static String _pack(Uint8List bits) => base64Encode(_packBits(bits));

  static Uint8List _unpack(String encoded, int length) =>
      _unpackBits(base64Decode(encoded), length);
}

class LdpcRecoveryResult {
  const LdpcRecoveryResult({
    required this.accepted,
    required this.syndromePassed,
    required this.hashMatched,
    required this.recoveredHash,
    required this.derivedKey,
    required this.preDecodeErrors,
    required this.postDecodeErrors,
  });

  final bool accepted;
  final bool syndromePassed;
  final bool hashMatched;
  final String? recoveredHash;
  final String? derivedKey;
  final int preDecodeErrors;
  final int postDecodeErrors;
}

class LdpcFuzzyCommitment {
  static const baseGraphColumns = 52;
  static const baseGraphRows = 42;
  static const quantScale = 5;
  static const quantBits = 3;
  static const embeddingDimension = 512;
  static const bitVectorLength = embeddingDimension * quantBits;
  static const codeN = 832;
  static const codeK = 160;
  static const kdfAlgorithm = 'HKDF-SHA-256';
  static const kdfInfo = 'wrytte/kface/application-key/v1';
  static const kdfSaltLength = 32;
  static const derivedKeyLength = 32;
  static const _codeM = 672;
  static const _z = 16;
  static const _iterations = 25;

  List<Uint8List>? _generator;
  List<List<int>>? _checkEdges;
  List<int>? _edgeVariables;
  List<int>? _edgePrototypes;
  List<Float64List>? _weights;
  List<Float64List>? _biases;

  Future<void> initialize() async {
    if (_generator != null) return;
    _generator = _parseIntMatrix(
      await rootBundle.loadString('assets/ldpc/LDPC_GM_BG2_16.txt'),
      commaSeparated: true,
    ).map(Uint8List.fromList).toList(growable: false);
    if (_generator!.length != codeK || _generator!.first.length != codeN) {
      throw StateError('Unexpected LDPC generator matrix dimensions.');
    }

    final baseGraph = _parseIntMatrix(
      await rootBundle.loadString('assets/ldpc/BaseGraph2_Set0.txt'),
      commaSeparated: false,
    );
    _buildEdges(baseGraph);
    _weights = <Float64List>[];
    _biases = <Float64List>[];
    for (var iteration = 0; iteration < _iterations; iteration++) {
      _weights!.add(
        _parseDoubles(
          await rootBundle.loadString(
            'assets/ldpc/Weights_Var_MS/Weights_Var$iteration.txt',
          ),
        ),
      );
      _biases!.add(
        _parseDoubles(
          await rootBundle.loadString(
            'assets/ldpc/Biases_Var_MS/Biases_Var$iteration.txt',
          ),
        ),
      );
    }
  }

  Uint8List embeddingToBitVector(
    Float32List embedding, {
    int scale = quantScale,
  }) {
    if (embedding.length != embeddingDimension) {
      throw ArgumentError('Expected a $embeddingDimension-value embedding.');
    }
    const levels = (1 << quantBits) - 1;
    final result = Uint8List(bitVectorLength);
    for (var index = 0; index < embedding.length; index++) {
      final scaled = (embedding[index] * scale).clamp(-1.0, 1.0);
      final quantized = _roundHalfToEven(
        ((scaled + 1.0) / 2.0) * levels,
      ).clamp(0, levels);
      final gray = quantized ^ (quantized >> 1);
      for (var bit = 0; bit < quantBits; bit++) {
        result[index * quantBits + (quantBits - 1 - bit)] = (gray >> bit) & 1;
      }
    }
    return result;
  }

  /// Matches NumPy's `round`, which uses ties-to-even rather than Dart's
  /// default half-away-from-zero rounding.
  static int _roundHalfToEven(double value) {
    final lower = value.floor();
    final fraction = value - lower;
    if ((fraction - 0.5).abs() <= 1e-12) {
      return lower.isEven ? lower : lower + 1;
    }
    return fraction < 0.5 ? lower : lower + 1;
  }

  FuzzyCommitment enroll(Float32List embedding) {
    _ensureReady();
    final bitVector = embeddingToBitVector(embedding);
    final nonce = Uint8List(bitVectorLength)..fillRange(0, bitVectorLength, 1);
    final message = Uint8List.fromList(bitVector.sublist(0, codeK));
    final codeword = _encode(message);
    final helper = Uint8List(codeN);
    for (var index = 0; index < codeN; index++) {
      helper[index] = bitVector[index] ^ codeword[index];
    }
    return FuzzyCommitment(
      helper: helper,
      nonce: nonce,
      keyHash: sha256.convert(_packBits(message)).toString(),
      kdfSalt: _secureRandomBytes(kdfSaltLength),
    );
  }

  String deriveEnrollmentKey(
    Float32List embedding,
    FuzzyCommitment commitment,
  ) {
    if (commitment.kdfSalt.isEmpty) {
      throw StateError('This enrollment predates HKDF key derivation.');
    }
    final bits = embeddingToBitVector(embedding, scale: commitment.quantScale);
    final message = Uint8List.fromList(bits.sublist(0, codeK));
    return _hex(_hkdfSha256(_packBits(message), commitment.kdfSalt));
  }

  LdpcRecoveryResult recover(
    Float32List embedding,
    FuzzyCommitment commitment,
  ) {
    _ensureReady();
    final probe = embeddingToBitVector(embedding, scale: commitment.quantScale);
    final received = Uint8List(codeN);
    for (var index = 0; index < codeN; index++) {
      final nonceBit =
          index < commitment.nonce.length ? commitment.nonce[index] : 0;
      final helperBit =
          index < commitment.helper.length ? commitment.helper[index] : 0;
      received[index] = (probe[index] & nonceBit) ^ helperBit;
    }

    final preDecodeErrors = _differenceCount(
      _encode(Uint8List.fromList(received.sublist(0, codeK))),
      received,
    );
    final decoded = _decode(received);
    final candidateMessage = Uint8List.fromList(decoded.sublist(0, codeK));
    final candidateCodeword = _encode(candidateMessage);
    final postDecodeErrors = _differenceCount(candidateCodeword, decoded);
    final syndromePassed = postDecodeErrors == 0;
    final recoveredHash =
        syndromePassed
            ? sha256.convert(_packBits(candidateMessage)).toString()
            : null;
    final hashMatched = recoveredHash == commitment.keyHash;
    final accepted = syndromePassed && hashMatched;
    final derivedKey =
        accepted && commitment.kdfSalt.isNotEmpty
            ? _hex(_hkdfSha256(_packBits(candidateMessage), commitment.kdfSalt))
            : null;
    return LdpcRecoveryResult(
      accepted: accepted,
      syndromePassed: syndromePassed,
      hashMatched: hashMatched,
      recoveredHash: recoveredHash,
      derivedKey: derivedKey,
      preDecodeErrors: preDecodeErrors,
      postDecodeErrors: postDecodeErrors,
    );
  }

  static Uint8List _secureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static Uint8List _hkdfSha256(Uint8List inputKey, Uint8List salt) {
    final extract = Hmac(sha256, salt).convert(inputKey).bytes;
    final info = utf8.encode(kdfInfo);
    final output = <int>[];
    var previous = <int>[];
    var counter = 1;
    while (output.length < derivedKeyLength) {
      previous =
          Hmac(sha256, extract).convert([...previous, ...info, counter]).bytes;
      output.addAll(previous);
      counter++;
    }
    return Uint8List.fromList(output.sublist(0, derivedKeyLength));
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _encode(Uint8List message) {
    final generator = _generator!;
    final output = Uint8List(codeN);
    for (var row = 0; row < codeK; row++) {
      if (message[row] == 0) continue;
      final generatorRow = generator[row];
      for (var column = 0; column < codeN; column++) {
        output[column] ^= generatorRow[column] & 1;
      }
    }
    return output;
  }

  Uint8List _decode(Uint8List received) {
    final checkEdges = _checkEdges!;
    final edgeVariables = _edgeVariables!;
    final edgePrototypes = _edgePrototypes!;
    final channelLlr = Float64List.fromList(
      received.map((bit) => 1.0 - 2.0 * bit).toList(),
    );
    var checkToVariable = Float64List(edgeVariables.length);

    for (var iteration = 0; iteration < _iterations; iteration++) {
      final total = Float64List.fromList(channelLlr);
      for (var edge = 0; edge < edgeVariables.length; edge++) {
        total[edgeVariables[edge]] += checkToVariable[edge];
      }
      final variableToCheck = Float64List(edgeVariables.length);
      for (var edge = 0; edge < edgeVariables.length; edge++) {
        variableToCheck[edge] =
            total[edgeVariables[edge]] - checkToVariable[edge];
      }

      final next = Float64List(edgeVariables.length);
      for (var check = 0; check < _codeM; check++) {
        final edges = checkEdges[check];
        if (edges.isEmpty) continue;
        var negativeCount = 0;
        var minimum = double.infinity;
        var secondMinimum = double.infinity;
        var minimumEdge = -1;
        for (final edge in edges) {
          final value = variableToCheck[edge];
          if (value < 0) negativeCount++;
          final magnitude = value.abs();
          if (magnitude < minimum) {
            secondMinimum = minimum;
            minimum = magnitude;
            minimumEdge = edge;
          } else if (magnitude < secondMinimum) {
            secondMinimum = magnitude;
          }
        }
        for (final edge in edges) {
          final value = variableToCheck[edge];
          final negativeWithoutSelf = negativeCount - (value < 0 ? 1 : 0);
          final sign = negativeWithoutSelf.isEven ? 1.0 : -1.0;
          final magnitude = edge == minimumEdge ? secondMinimum : minimum;
          final prototype = edgePrototypes[edge];
          final weight = _weights![iteration][prototype];
          final bias = _biases![iteration][prototype];
          final scaled = (magnitude * weight + bias).clamp(0.0, 1000000.0);
          next[edge] = sign * scaled;
        }
      }
      checkToVariable = next;
    }

    final totals = Float64List.fromList(channelLlr);
    for (var edge = 0; edge < edgeVariables.length; edge++) {
      totals[edgeVariables[edge]] += checkToVariable[edge];
    }
    return Uint8List.fromList(
      totals.map((value) => value < 0 ? 1 : 0).toList(),
    );
  }

  void _buildEdges(List<List<int>> baseGraph) {
    final checkEdges = List.generate(_codeM, (_) => <int>[]);
    final variables = <int>[];
    final prototypes = <int>[];
    var prototype = 0;
    for (var column = 0; column < baseGraph.first.length; column++) {
      for (var row = 0; row < baseGraph.length; row++) {
        final shiftValue = baseGraph[row][column];
        if (shiftValue == -1) continue;
        final shift = shiftValue % _z;
        for (var lift = 0; lift < _z; lift++) {
          final check = row * _z + lift;
          final variable = column * _z + ((lift + shift) % _z);
          final edge = variables.length;
          variables.add(variable);
          prototypes.add(prototype);
          checkEdges[check].add(edge);
        }
        prototype++;
      }
    }
    _checkEdges = checkEdges;
    _edgeVariables = variables;
    _edgePrototypes = prototypes;
  }

  void _ensureReady() {
    if (_generator == null) {
      throw StateError(
        'LdpcFuzzyCommitment.initialize() must be called first.',
      );
    }
  }

  static int _differenceCount(Uint8List a, Uint8List b) {
    final length = a.length < b.length ? a.length : b.length;
    var count = 0;
    for (var index = 0; index < length; index++) {
      if (a[index] != b[index]) count++;
    }
    return count + (a.length - b.length).abs();
  }

  static List<List<int>> _parseIntMatrix(
    String source, {
    required bool commaSeparated,
  }) {
    return source
        .trim()
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .map(
          (line) => line
              .trim()
              .split(commaSeparated ? ',' : RegExp(r'\s+'))
              .where((value) => value.trim().isNotEmpty)
              .map((value) => int.parse(value.trim()))
              .toList(growable: false),
        )
        .toList(growable: false);
  }

  static Float64List _parseDoubles(String source) => Float64List.fromList(
    source
        .trim()
        .split(RegExp(r'[,\s]+'))
        .where((value) => value.isNotEmpty)
        .map(double.parse)
        .toList(),
  );
}

Uint8List _packBits(Uint8List bits) {
  final packed = Uint8List((bits.length + 7) ~/ 8);
  for (var index = 0; index < bits.length; index++) {
    packed[index ~/ 8] |= (bits[index] & 1) << (7 - (index % 8));
  }
  return packed;
}

Uint8List _unpackBits(Uint8List packed, int bitLength) {
  final bits = Uint8List(bitLength);
  for (var index = 0; index < bitLength; index++) {
    bits[index] = (packed[index ~/ 8] >> (7 - (index % 8))) & 1;
  }
  return bits;
}
