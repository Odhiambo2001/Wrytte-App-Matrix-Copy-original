import 'package:flutter/material.dart';

class CameraShutterButton extends StatelessWidget {
  const CameraShutterButton({
    super.key,
    required this.videoMode,
    required this.recording,
    required this.enabled,
    required this.onPressed,
  });

  final bool videoMode;
  final bool recording;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = videoMode ? const Color(0xFFFF4D4F) : const Color(0xFFF5F5F5);
    return Semantics(
      button: true,
      enabled: enabled,
      label: recording
          ? 'Stop recording'
          : videoMode
          ? 'Record video'
          : 'Take photo',
      child: SizedBox.square(
        dimension: 86,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            customBorder: const CircleBorder(),
            splashFactory: NoSplash.splashFactory,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 78,
                height: 78,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFF5F5F5), width: 3),
                ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  decoration: BoxDecoration(
                    color: enabled ? color : color.withValues(alpha: .45),
                    shape: recording ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius: recording
                        ? const BorderRadius.all(Radius.circular(9))
                        : null,
                  ),
                  margin: recording
                      ? const EdgeInsets.all(17)
                      : EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
