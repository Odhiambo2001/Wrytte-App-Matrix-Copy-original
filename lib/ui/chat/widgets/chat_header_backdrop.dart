import 'dart:ui';

import 'package:flutter/material.dart';

/// The original Wrytte conversation header treatment: the timeline remains
/// beneath the header, a progressively masked blur softens it, and a separate
/// black scrim is strongest above the controls and transparent below them.
class ChatHeaderBackdrop extends StatelessWidget {
  const ChatHeaderBackdrop({
    super.key,
    required this.child,
    required this.pillBottom,
    required this.overlayHeight,
  });

  final Widget child;
  final double pillBottom;
  final double overlayHeight;

  @override
  Widget build(BuildContext context) {
    final fadeStart = pillBottom - 26;
    final fadeEnd = pillBottom + 10;
    final transitionSpan = fadeEnd - fadeStart;
    const transitionAlphas = <double>[
      1,
      .99,
      .96,
      .90,
      .81,
      .69,
      .56,
      .43,
      .31,
      .21,
      .12,
      .05,
      0,
    ];
    final maskStops = <double>[0];
    final maskColors = <Color>[Colors.white];
    for (var index = 0; index < transitionAlphas.length; index++) {
      final progress = index / (transitionAlphas.length - 1);
      maskStops.add((fadeStart + transitionSpan * progress) / overlayHeight);
      maskColors.add(Color.fromRGBO(255, 255, 255, transitionAlphas[index]));
    }
    maskStops.add(1);
    maskColors.add(Colors.transparent);

    const pillBottomFactors = <double>[
      0,
      .07,
      .14,
      .21,
      .28,
      .35,
      .42,
      .49,
      .56,
      .63,
      .70,
      .77,
      .83,
      .89,
      .94,
      1,
    ];
    final scrimStops = <double>[
      for (final factor in pillBottomFactors)
        (pillBottom * factor) / overlayHeight,
      1,
    ];

    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: overlayHeight,
          child: IgnorePointer(
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: maskStops,
                      colors: maskColors,
                    ).createShader(bounds),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: 32,
                        sigmaY: 32,
                        tileMode: TileMode.clamp,
                      ),
                      blendMode: BlendMode.srcOver,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: scrimStops,
                        colors: const [
                          Color.fromRGBO(2, 3, 5, .985),
                          Color.fromRGBO(2, 3, 5, .982),
                          Color.fromRGBO(3, 4, 6, .975),
                          Color.fromRGBO(3, 4, 7, .960),
                          Color.fromRGBO(4, 5, 8, .940),
                          Color.fromRGBO(4, 6, 9, .910),
                          Color.fromRGBO(5, 7, 10, .870),
                          Color.fromRGBO(5, 7, 11, .820),
                          Color.fromRGBO(6, 8, 12, .750),
                          Color.fromRGBO(6, 8, 12, .650),
                          Color.fromRGBO(6, 8, 12, .535),
                          Color.fromRGBO(6, 8, 12, .400),
                          Color.fromRGBO(6, 8, 12, .270),
                          Color.fromRGBO(6, 8, 12, .150),
                          Color.fromRGBO(6, 8, 12, .060),
                          Color.fromRGBO(6, 8, 12, 0),
                          Color.fromRGBO(6, 8, 12, 0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
