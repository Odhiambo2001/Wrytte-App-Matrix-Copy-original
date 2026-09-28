import 'dart:async';

import 'package:flutter/services.dart';

enum KeyboardMotionInsetUnit {
  physicalPixels,
  logicalPixels,
}

class KeyboardMotionTarget {
  const KeyboardMotionTarget({
    required this.visible,
    required this.inset,
    required this.unit,
  });

  final bool visible;
  final double inset;
  final KeyboardMotionInsetUnit unit;
}

/// Native IME end-state bridge.
///
/// The important distinction from MediaQuery.viewInsets is timing: Android can
/// expose the fully-shown IME animation bound when the keyboard animation
/// starts, before Flutter has received the final per-frame viewInsets value.
/// That lets the first keyboard opening use the real destination instead of a
/// guessed screen-height percentage.
class KeyboardMotionBridge {
  KeyboardMotionBridge._();

  static final KeyboardMotionBridge instance = KeyboardMotionBridge._();

  static const MethodChannel _channel = MethodChannel(
    'wrytte/keyboard_motion',
  );

  final StreamController<KeyboardMotionTarget> _targets =
      StreamController<KeyboardMotionTarget>.broadcast();

  bool _installed = false;

  Stream<KeyboardMotionTarget> get targets {
    _ensureInstalled();
    return _targets.stream;
  }

  void _ensureInstalled() {
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'target') return;

    final arguments = call.arguments;
    if (arguments is! Map) return;

    final visible = arguments['visible'];
    final inset = arguments['inset'];
    final unit = arguments['unit'];

    if (visible is! bool || inset is! num) return;

    _targets.add(
      KeyboardMotionTarget(
        visible: visible,
        inset: inset.toDouble(),
        unit: unit == 'logicalPixels'
            ? KeyboardMotionInsetUnit.logicalPixels
            : KeyboardMotionInsetUnit.physicalPixels,
      ),
    );
  }
}
