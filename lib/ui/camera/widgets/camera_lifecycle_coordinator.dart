import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';

/// Releases the active camera session only when the application is genuinely
/// backgrounded, then restores it when the application resumes.
///
/// Keeping this at the app boundary gives the full-screen camera and embedded
/// attachment preview one lifecycle owner. In particular, `inactive` is not
/// treated as a release signal because Android uses it transiently while a
/// permission surface is visible.
class CameraLifecycleCoordinator extends StatefulWidget {
  const CameraLifecycleCoordinator({
    super.key,
    required this.repository,
    required this.child,
  });

  final CameraRepository repository;
  final Widget child;

  @override
  State<CameraLifecycleCoordinator> createState() =>
      _CameraLifecycleCoordinatorState();
}

class _CameraLifecycleCoordinatorState
    extends State<CameraLifecycleCoordinator> {
  late final AppLifecycleListener _listener;
  bool _suspended = false;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(
      onPause: _suspend,
      onDetach: _suspend,
      onResume: _resume,
    );
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  void _suspend() {
    if (_suspended) return;
    _suspended = true;
    unawaited(widget.repository.interrupt());
  }

  void _resume() {
    if (!_suspended) return;
    _suspended = false;
    unawaited(widget.repository.resume());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
