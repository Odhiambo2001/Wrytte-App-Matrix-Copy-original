import 'dart:io';
import 'dart:typed_data';

/// Copies a PCM WAV range without loading the recording payload into memory.
class WavAudioTrimmer {
  const WavAudioTrimmer();

  Future<String> trim(
    String sourcePath, {
    required double startFraction,
    required double endFraction,
  }) async {
    final safeStart = startFraction.clamp(0.0, .999);
    final safeEnd = endFraction.clamp(safeStart, 1.0);
    if (safeStart <= 0 && safeEnd >= 1) return sourcePath;

    final source = await File(sourcePath).open();
    try {
      final fileLength = await source.length();
      final prefix = Uint8List.fromList(
        await source.read(fileLength.clamp(0, 1024 * 1024)),
      );
      if (prefix.length < 44 ||
          String.fromCharCodes(prefix.sublist(0, 4)) != 'RIFF' ||
          String.fromCharCodes(prefix.sublist(8, 12)) != 'WAVE') {
        throw const FormatException('Unsupported WAV header');
      }

      final prefixData = ByteData.sublistView(prefix);
      var cursor = 12;
      int? blockAlign;
      int? dataHeaderOffset;
      int? dataSize;
      while (cursor + 8 <= prefix.length) {
        final chunkId = String.fromCharCodes(
          prefix.sublist(cursor, cursor + 4),
        );
        final chunkSize = prefixData.getUint32(cursor + 4, Endian.little);
        final payload = cursor + 8;
        if (chunkId == 'fmt ' &&
            chunkSize >= 16 &&
            payload + 16 <= prefix.length) {
          blockAlign = prefixData.getUint16(payload + 12, Endian.little);
        } else if (chunkId == 'data') {
          dataHeaderOffset = cursor;
          dataSize = chunkSize.clamp(0, fileLength - payload);
          break;
        }
        cursor = payload + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }
      if (dataHeaderOffset == null || dataSize == null || blockAlign == null) {
        throw const FormatException('WAV data chunk is missing');
      }

      final payloadOffset = dataHeaderOffset + 8;
      final firstBlock = ((dataSize * safeStart) ~/ blockAlign) * blockAlign;
      final lastBlock = ((dataSize * safeEnd) ~/ blockAlign) * blockAlign;
      final outputDataSize = (lastBlock - firstBlock).clamp(0, dataSize);
      final header = Uint8List.fromList(prefix.sublist(0, payloadOffset));
      final headerData = ByteData.sublistView(header);
      headerData.setUint32(
        4,
        header.length + outputDataSize - 8,
        Endian.little,
      );
      headerData.setUint32(dataHeaderOffset + 4, outputDataSize, Endian.little);

      final separator = Platform.pathSeparator;
      final slash = sourcePath.lastIndexOf(separator);
      final dot = sourcePath.lastIndexOf('.');
      final base = dot > slash ? sourcePath.substring(0, dot) : sourcePath;
      final targetPath =
          '${base}_trim_${DateTime.now().microsecondsSinceEpoch}.wav';
      final target = await File(targetPath).open(mode: FileMode.write);
      try {
        await target.writeFrom(header);
        await source.setPosition(payloadOffset + firstBlock);
        var remaining = outputDataSize;
        while (remaining > 0) {
          final chunk = await source.read(remaining.clamp(0, 64 * 1024));
          if (chunk.isEmpty) break;
          await target.writeFrom(chunk);
          remaining -= chunk.length;
        }
        await target.flush();
      } finally {
        await target.close();
      }
      return targetPath;
    } finally {
      await source.close();
    }
  }
}
