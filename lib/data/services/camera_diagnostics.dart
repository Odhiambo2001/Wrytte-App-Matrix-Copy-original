import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

class CameraDiagnostics {
  const CameraDiagnostics();

  void event(String name, [Map<String, Object?> fields = const {}]) {
    if (!kDebugMode) return;
    final details = fields.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    developer.log(
      details.isEmpty ? name : '$name $details',
      name: 'wrytte.camera',
    );
  }
}
