import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AttachmentLocalCopy {
  final File file;
  final bool isComplete;
  final int? totalBytes;

  const AttachmentLocalCopy({
    required this.file,
    required this.isComplete,
    this.totalBytes,
  });
}

class AttachmentLocalStore {
  AttachmentLocalStore._();
  static final AttachmentLocalStore instance = AttachmentLocalStore._();

  static const int initialFileBytes = 35 * 1024 * 1024;
  final Map<String, Future<AttachmentLocalCopy>> _inFlight = {};

  Future<AttachmentLocalCopy> ensureInitial({
    required String source,
    required String fileName,
    required bool allowPartial,
  }) {
    final key = '${source.trim()}|initial|$allowPartial';
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _ensure(
          source: source,
          fileName: fileName,
          allowPartial: allowPartial,
        );
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  Future<AttachmentLocalCopy> ensureComplete({
    required String source,
    required String fileName,
  }) {
    final key = '${source.trim()}|complete';
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _ensure(
          source: source,
          fileName: fileName,
          allowPartial: false,
        );
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  Future<void> deleteLocalCopy({
    required String source,
    required String fileName,
  }) async {
    final cleanSource = source.trim();
    if (cleanSource.isEmpty) return;
    try {
      final target = await _targetFile(cleanSource, fileName);
      final marker = File('${target.path}.complete');
      if (await target.exists()) await target.delete();
      if (await marker.exists()) await marker.delete();
    } catch (_) {
      // Local database cleanup must still complete if a cached file was
      // already removed by Android or another cleanup pass.
    }
  }

  Future<AttachmentLocalCopy> _ensure({
    required String source,
    required String fileName,
    required bool allowPartial,
  }) async {
    final cleanSource = source.trim();
    if (cleanSource.isEmpty) throw StateError('Attachment URL is unavailable');

    final target = await _targetFile(cleanSource, fileName);
    final completeMarker = File('${target.path}.complete');
    if (await target.exists() && await completeMarker.exists()) {
      return AttachmentLocalCopy(
        file: target,
        isComplete: true,
        totalBytes: await target.length(),
      );
    }

    if (!cleanSource.startsWith('http')) {
      final local = File(cleanSource);
      if (!await local.exists()) throw StateError('Attachment is unavailable');
      if (local.path != target.path) await local.copy(target.path);
      await completeMarker.writeAsString('complete', flush: true);
      return AttachmentLocalCopy(
        file: target,
        isComplete: true,
        totalBytes: await target.length(),
      );
    }

    final client = http.Client();
    try {
      int? totalBytes;
      try {
        final head = await client
            .head(Uri.parse(cleanSource))
            .timeout(const Duration(seconds: 15));
        totalBytes = int.tryParse(head.headers['content-length'] ?? '');
      } catch (_) {}

      final shouldPartial =
          allowPartial && totalBytes != null && totalBytes > initialFileBytes;
      final request = http.Request('GET', Uri.parse(cleanSource));
      if (shouldPartial) {
        request.headers['Range'] = 'bytes=0-${initialFileBytes - 1}';
      }
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Attachment download failed: ${response.statusCode}',
        );
      }

      final sink = target.openWrite(mode: FileMode.writeOnly);
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (shouldPartial &&
            response.statusCode == 200 &&
            received >= initialFileBytes) {
          break;
        }
      }
      await sink.flush();
      await sink.close();

      final isComplete = !shouldPartial || await target.length() >= totalBytes;
      if (isComplete) {
        await completeMarker.writeAsString('complete', flush: true);
      }
      return AttachmentLocalCopy(
        file: target,
        isComplete: isComplete,
        totalBytes: totalBytes,
      );
    } finally {
      client.close();
    }
  }

  Future<File> _targetFile(String source, String fileName) async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/Wrytte Attachments');
    await directory.create(recursive: true);
    var name = fileName.trim();
    if (name.isEmpty || name.toLowerCase() == 'file') {
      name = p.basename(Uri.tryParse(source)?.path ?? source);
    }
    var extension = p.extension(name).toLowerCase();
    if (extension.isEmpty) {
      extension = p.extension(Uri.tryParse(source)?.path ?? '').toLowerCase();
    }
    extension = extension.replaceAll(RegExp(r'[^a-z0-9.]'), '');
    if (extension.isEmpty) extension = '.bin';
    return File('${directory.path}/${_stableSourceKey(source)}$extension');
  }

  String _stableSourceKey(String source) {
    var hash = 0xcbf29ce484222325;
    for (final byte in source.codeUnits) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }
}
