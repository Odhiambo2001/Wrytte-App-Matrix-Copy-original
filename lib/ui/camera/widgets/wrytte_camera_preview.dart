import 'package:flutter/material.dart';
import 'package:wrytte/domain/models/camera_session_state.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';

class WrytteCameraPreview extends StatelessWidget {
  const WrytteCameraPreview({
    super.key,
    required this.repository,
    required this.state,
  });

  final CameraRepository repository;
  final CameraSessionState state;

  @override
  Widget build(BuildContext context) {
    if (!state.isReady) {
      return const ColoredBox(color: Color(0xFF050608));
    }
    return repository.buildPreview(key: ValueKey(state.activeDevice?.id));
  }
}
