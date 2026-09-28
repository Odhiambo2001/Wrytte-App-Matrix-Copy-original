import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:wrytte/domain/models/camera_session_state.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';

/// The camera-owned preview surface rendered inside a caller's attachment tile.
/// The media feature receives this as an ordinary widget and remains unaware of
/// camera plugin types and hardware lifecycle details.
class AttachmentCameraPreview extends StatelessWidget {
  const AttachmentCameraPreview({
    super.key,
    required this.repository,
    required this.fullScreenCameraOpen,
  });

  final CameraRepository repository;
  final ValueListenable<bool> fullScreenCameraOpen;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: fullScreenCameraOpen,
      builder: (context, cameraOpen, _) {
        if (cameraOpen) return const SizedBox.expand();
        return StreamBuilder<CameraSessionState>(
          stream: repository.states,
          initialData: repository.state,
          builder: (context, snapshot) {
            final state = snapshot.data ?? repository.state;
            if (!state.isReady) return const SizedBox.expand();
            return RepaintBoundary(
              child: repository.buildPreview(
                key: ValueKey('attachment-camera-${state.activeDevice?.id}'),
              ),
            );
          },
        );
      },
    );
  }
}
