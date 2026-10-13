import 'dart:async';

import 'package:flutter/material.dart';

/// Warms the small, frequently used route-control assets while the first screen
/// is visible so they never appear a frame after their surrounding UI.
class WrytteAssetWarmup extends StatefulWidget {
  const WrytteAssetWarmup({super.key, required this.child});

  final Widget child;

  @override
  State<WrytteAssetWarmup> createState() => _WrytteAssetWarmupState();
}

class _WrytteAssetWarmupState extends State<WrytteAssetWarmup> {
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_warmAssets());
  }

  Future<void> _warmAssets() async {
    await Future.wait([
      _ignoreFailure(
        precacheImage(
          const AssetImage('assets/images/wrytte_id_signup_icon_128.png'),
          context,
        ),
      ),
      _ignoreFailure(
        precacheImage(
          const AssetImage('assets/images/default_avatar.jpg'),
          context,
        ),
      ),
      _ignoreFailure(
        precacheImage(
          const AssetImage('assets/images/chat_wallpaper.jpg'),
          context,
        ),
      ),
      _ignoreFailure(
        precacheImage(
          const AssetImage('assets/images/video image5.jpg'),
          context,
        ),
      ),
    ]);
  }

  Future<void> _ignoreFailure(Future<Object?> operation) async {
    try {
      await operation;
    } catch (_) {
      // Each widget still has its normal asset error behavior. Warmup must
      // never prevent application startup.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
