import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class WrytteVideoSurface extends StatelessWidget {
  const WrytteVideoSurface({
    super.key,
    required this.controller,
    this.fit = BoxFit.cover,
    this.backgroundColor = Colors.black,
  });

  final VideoPlayerController controller;

  final BoxFit fit;

  final Color backgroundColor;

  @override
  Widget build(
    BuildContext context,
  ) {
    final value =
        controller.value;

    if (!value.isInitialized ||
        value.size.width <= 0 ||
        value.size.height <= 0) {
      return ColoredBox(
        color:
            backgroundColor,
      );
    }

    final sourceSize =
        value.size;

    return ColoredBox(
      color:
          backgroundColor,
      child:
          SizedBox.expand(
        child:
            FittedBox(
          fit:
              fit,
          clipBehavior:
              Clip.hardEdge,
          child:
              SizedBox(
            width:
                sourceSize.width,
            height:
                sourceSize.height,
            child:
                VideoPlayer(
              controller,
            ),
          ),
        ),
      ),
    );
  }
}