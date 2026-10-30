import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class StagedMedia {
  const StagedMedia({
    required this.path,
    required this.width,
    required this.height,
  });

  final String path;
  final int width;
  final int height;
}

class OutgoingMediaStore {
  OutgoingMediaStore._();

  static final instance = OutgoingMediaStore._();

  Directory? _directory;
  File? _indexFile;
  Future<void>? _initialization;
  Future<void> _writes = Future<void>.value();
  final Map<String, String> _names = <String, String>{};

  Future<void> init() => _initialization ??= _load();

  Future<void> _load() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/outgoing_media');
    await directory.create(recursive: true);
    final indexFile = File('${directory.path}/index.json');
    if (await indexFile.exists()) {
      try {
        final decoded = jsonDecode(await indexFile.readAsString());
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is String && value is String &&
                File('${directory.path}/$value').existsSync()) {
              _names[key] = value;
            }
          });
        }
      } catch (error) {
        debugPrint('[OutgoingMediaStore.load] index error=$error');
      }
    }
    _directory = directory;
    _indexFile = indexFile;
  }

  Future<StagedMedia?> stage(
    String sourcePath, {
    required String localId,
  }) async {
    try {
      await init();
      final name = '${DateTime.now().microsecondsSinceEpoch}';
      final destination = File('${_directory!.path}/$name');
      await File(sourcePath).copy(destination.path);
      final size = await _readSize(destination.path);
      if (size == null) {
        await destination.delete();
        return null;
      }
      _names[localId] = name;
      unawaited(_persist());
      return StagedMedia(
        path: destination.path,
        width: size.width.round(),
        height: size.height.round(),
      );
    } catch (error) {
      debugPrint('[OutgoingMediaStore.stage] error=$error');
      return null;
    }
  }

  void adopt(String fromKey, Iterable<String?> keys) {
    final name = _names[fromKey.trim()];
    if (name == null) return;
    var changed = false;
    for (final rawKey in keys) {
      final key = rawKey?.trim();
      if (key == null || key.isEmpty || _names[key] == name) continue;
      _names[key] = name;
      changed = true;
    }
    if (changed) unawaited(_persist());
  }

  String? lookup(String? key) {
    final directory = _directory;
    final cleanKey = key?.trim();
    if (directory == null || cleanKey == null || cleanKey.isEmpty) return null;
    final name = _names[cleanKey];
    final path = name == null ? null : '${directory.path}/$name';
    return path != null && File(path).existsSync() ? path : null;
  }

  Future<void> _persist() {
    _writes = _writes.then((_) async {
      final file = _indexFile;
      if (file == null) return;
      try {
        await file.writeAsString(jsonEncode(_names), flush: true);
      } catch (error) {
        debugPrint('[OutgoingMediaStore.persist] error=$error');
      }
    });
    return _writes;
  }

  Future<ui.Size?> _readSize(String path) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width.toDouble();
      final height = descriptor.height.toDouble();
      return width > 0 && height > 0 ? ui.Size(width, height) : null;
    } catch (_) {
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
