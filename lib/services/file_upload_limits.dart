import 'dart:io';

import 'package:path/path.dart' as p;

class FileTooLargeException implements Exception {
  FileTooLargeException(this.label, this.maxBytes, this.actualBytes);

  final String label;
  final int maxBytes;
  final int actualBytes;

  @override
  String toString() {
    return '$label is too large. Maximum size is '
        '${FileUploadLimits.formatBytes(maxBytes)}.';
  }
}

class InvalidUploadFileTypeException implements Exception {
  InvalidUploadFileTypeException(this.label, this.allowedTypes);

  final String label;
  final List<String> allowedTypes;

  @override
  String toString() {
    return '$label must be one of: ${allowedTypes.join(', ')}.';
  }
}

class FileUploadLimits {
  FileUploadLimits._();

  /// Maximum size accepted by the app for any uploaded media or attachment.
  /// The Matrix homeserver may advertise a lower limit, in which case the
  /// lower server limit remains authoritative.
  static const int mediaMaxBytes = 100 * 1024 * 1024;

  static const int avatarImageMaxBytes = mediaMaxBytes;
  static const int voiceMessageMaxBytes = mediaMaxBytes;
  static const int videoMessageMaxBytes = mediaMaxBytes;
  static const int chatFileMaxBytes = mediaMaxBytes;

  static const List<String> avatarImageExtensions = [
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.heic',
    '.heif',
  ];

  static Future<void> validatePath(
    String path, {
    required int maxBytes,
    required String label,
  }) async {
    final file = File(path);
    final exists = await file.exists();
    if (!exists) throw FileSystemException('File not found', path);

    final size = await file.length();
    if (size > maxBytes) {
      throw FileTooLargeException(label, maxBytes, size);
    }
  }

  static Future<void> validateAvatarImagePath(String path) async {
    await validatePath(
      path,
      maxBytes: avatarImageMaxBytes,
      label: 'Avatar image',
    );
    final extension = p.extension(path).toLowerCase();
    if (!avatarImageExtensions.contains(extension)) {
      throw InvalidUploadFileTypeException(
        'Avatar image',
        avatarImageExtensions,
      );
    }
  }

  static String formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final decimals = value >= 10 || unitIndex == 0 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }
}
