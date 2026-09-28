import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/core/routing/expanding_surface_route.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/core/widgets/wrytte_svg_icon.dart';
import 'package:wrytte/ui/media/widgets/media_circle_button.dart';

Future<String?> showWrytteProfilePhotoCrop(
  BuildContext context, {
  required String sourcePath,
  Size? sourcePixelSize,
  ExpandingSurfaceOrigin? origin,
}) async {
  final file = File(sourcePath);

  if (!await file.exists() || !context.mounted) {
    return null;
  }

  final sourceSize =
      sourcePixelSize ?? await _readImageSize(file);

  if (sourceSize == null || !context.mounted) {
    return null;
  }

  final targetWidth =
      (MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context))
          .round()
          .clamp(720, 2048);

  final displayImage = ResizeImage(
    FileImage(file),
    width: targetWidth,
  );

  try {
    await precacheImage(
      displayImage,
      context,
    );
  } catch (_) {
    if (!context.mounted) {
      return null;
    }
  }

  if (!context.mounted) {
    return null;
  }

  return Navigator.of(
    context,
    rootNavigator: true,
  ).push<String>(
    ExpandingSurfaceRoute<String>(
      origin: origin,
      animationsDisabled:
          MediaQuery.disableAnimationsOf(context),
      builder: (
        context,
        animation,
      ) =>
          ProfilePhotoCropView(
        sourcePath: sourcePath,
        sourcePixelSize: sourceSize,
        displayImage: displayImage,
        routeAnimation: animation,
      ),
    ),
  );
}

Future<Size?> _readImageSize(
  File file,
) async {
  try {
    final bytes =
        await file.readAsBytes();

    final codec =
        await ui.instantiateImageCodec(
      bytes,
    );

    final frame =
        await codec.getNextFrame();

    final size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );

    frame.image.dispose();
    codec.dispose();

    return size;
  } catch (_) {
    return null;
  }
}

class ProfilePhotoCropView
    extends StatefulWidget {
  const ProfilePhotoCropView({
    super.key,
    required this.sourcePath,
    required this.sourcePixelSize,
    required this.displayImage,
    required this.routeAnimation,
  });

  final String sourcePath;

  final Size sourcePixelSize;

  final ImageProvider displayImage;

  final Animation<double> routeAnimation;

  @override
  State<ProfilePhotoCropView>
      createState() =>
          _ProfilePhotoCropViewState();
}

class _ProfilePhotoCropViewState
    extends State<ProfilePhotoCropView> {
  static const _outputDimension = 640;

  Rect _activeCropRect = Rect.zero;

  double _imageScale = 1;

  Offset _imageOffset = Offset.zero;

  // ------------------------------------------------------------
  // GESTURE STATE
  // ------------------------------------------------------------

  /// Number of fingers currently driving the gesture.
  ///
  /// 1 finger:
  /// vertical pan only.
  ///
  /// 2+ fingers:
  /// zoom only.
  int _gesturePointerCount = 0;

  /// Image zoom level when a two-finger pinch begins.
  double _pinchStartImageScale = 1;

  /// Flutter's gesture-scale value at the moment we enter
  /// two-finger mode.
  ///
  /// This matters when the gesture originally began with one finger.
  /// When the second finger arrives, details.scale may not be exactly 1.
  /// Rebasing prevents the image from jumping.
  double _pinchStartGestureScale = 1;

  bool _saving = false;

  Rect _cropRectFor(
    Size viewport,
    EdgeInsets safePadding,
  ) {
    final top =
        safePadding.top + 76;

    final bottom = math.max(
      top + 1,
      viewport.height -
          safePadding.bottom -
          24,
    );

    final availableHeight =
        bottom - top;

    final diameter = math.max(
      1.0,
      math.min(
        viewport.width,
        availableHeight,
      ),
    );

    return Rect.fromCenter(
      center: Offset(
        viewport.width / 2,
        top + availableHeight / 2,
      ),
      width: diameter,
      height: diameter,
    );
  }

  double _baseImageScale(
    Rect cropRect,
  ) =>
      math.max(
        cropRect.width /
            widget.sourcePixelSize.width,
        cropRect.height /
            widget.sourcePixelSize.height,
      );

  Size _displayedImageSize(
    Rect cropRect,
    double scale,
  ) {
    final resolvedScale =
        _baseImageScale(cropRect) *
            scale;

    return Size(
      widget.sourcePixelSize.width *
          resolvedScale,
      widget.sourcePixelSize.height *
          resolvedScale,
    );
  }

  Offset _constrainOffset(
    Offset candidate,
    Rect cropRect,
    double scale,
  ) {
    final imageSize =
        _displayedImageSize(
      cropRect,
      scale,
    );

    final horizontalTravel =
        math.max(
      0,
      (imageSize.width -
              cropRect.width) /
          2,
    );

    final verticalTravel =
        math.max(
      0,
      (imageSize.height -
              cropRect.height) /
          2,
    );

    return Offset(
      scale > 1.001
          ? candidate.dx
              .clamp(
                -horizontalTravel,
                horizontalTravel,
              )
              .toDouble()
          : 0,
      candidate.dy
          .clamp(
            -verticalTravel,
            verticalTravel,
          )
          .toDouble(),
    );
  }

  Rect _resolveCropRect(
    Rect next,
  ) {
    if (!_activeCropRect.isEmpty &&
        _activeCropRect != next) {
      _imageOffset *=
          next.width /
              _activeCropRect.width;
    }

    _activeCropRect = next;

    _imageOffset =
        _constrainOffset(
      _imageOffset,
      next,
      _imageScale,
    );

    return next;
  }

  // ------------------------------------------------------------
  // GESTURES
  // ------------------------------------------------------------

  void _handleScaleStart(
    ScaleStartDetails details,
  ) {
    _gesturePointerCount =
        details.pointerCount;

    _pinchStartImageScale =
        _imageScale;

    _pinchStartGestureScale = 1;
  }

  void _handleScaleUpdate(
    ScaleUpdateDetails details,
  ) {
    if (_activeCropRect.isEmpty) {
      return;
    }

    final pointerCount =
        details.pointerCount;

    // ----------------------------------------------------------
    // POINTER COUNT CHANGED
    // ----------------------------------------------------------
    //
    // Example:
    //
    // 1 finger -> 2 fingers
    // 2 fingers -> 1 finger
    //
    // Flutter keeps this as the same scale gesture, so we rebase
    // our zoom state when the number of fingers changes.
    //
    // Skipping this update prevents a jump caused by the focal
    // point changing when a finger is added or removed.
    if (pointerCount !=
        _gesturePointerCount) {
      _gesturePointerCount =
          pointerCount;

      if (pointerCount >= 2) {
        _pinchStartImageScale =
            _imageScale;

        _pinchStartGestureScale =
            details.scale;
      }

      return;
    }

    // ----------------------------------------------------------
    // TWO OR MORE FINGERS
    // ----------------------------------------------------------
    //
    // ZOOM ONLY.
    //
    // We deliberately do not use:
    //
    // details.focalPointDelta
    // details.localFocalPoint
    //
    // Therefore moving both fingers together cannot pan the image.
    if (pointerCount >= 2) {
      final gestureScale =
          _pinchStartGestureScale ==
                  0
              ? 1.0
              : details.scale /
                  _pinchStartGestureScale;

      final nextScale =
          (_pinchStartImageScale *
                  gestureScale)
              .clamp(
                1.0,
                6.0,
              )
              .toDouble();

      setState(() {
        _imageScale = nextScale;

        // Keep the image at its current position.
        //
        // The only time the offset may change here is when
        // zooming OUT requires us to constrain the image so
        // no empty area becomes visible inside the crop circle.
        _imageOffset =
            _constrainOffset(
          _imageOffset,
          _activeCropRect,
          nextScale,
        );
      });

      return;
    }

    // ----------------------------------------------------------
    // ONE FINGER
    // ----------------------------------------------------------
    //
    // VERTICAL PAN ONLY.
    //
    // Horizontal movement is deliberately ignored.
    if (pointerCount == 1) {
      final nextOffset =
          _imageOffset +
              Offset(
                0,
                details
                    .focalPointDelta.dy,
              );

      setState(() {
        _imageOffset =
            _constrainOffset(
          nextOffset,
          _activeCropRect,
          _imageScale,
        );
      });
    }
  }

  void _handleScaleEnd(
    ScaleEndDetails _,
  ) {
    _gesturePointerCount = 0;

    _pinchStartImageScale =
        _imageScale;

    _pinchStartGestureScale = 1;
  }

  Future<void> _save() async {
    if (_saving ||
        _activeCropRect.isEmpty) {
      return;
    }

    setState(
      () => _saving = true,
    );

    unawaited(
      HapticFeedback.mediumImpact(),
    );

    try {
      final cropRect =
          _activeCropRect;

      final imageSize =
          _displayedImageSize(
        cropRect,
        _imageScale,
      );

      final imageRect =
          Rect.fromCenter(
        center:
            cropRect.center +
                _imageOffset,
        width: imageSize.width,
        height: imageSize.height,
      );

      final bytes =
          await File(
        widget.sourcePath,
      ).readAsBytes();

      final codec =
          await ui.instantiateImageCodec(
        bytes,
      );

      final frame =
          await codec.getNextFrame();

      final sourceImage =
          frame.image;

      final scaleX =
          sourceImage.width /
              imageRect.width;

      final scaleY =
          sourceImage.height /
              imageRect.height;

      final sourceCrop =
          Rect.fromLTRB(
        ((cropRect.left -
                    imageRect.left) *
                scaleX)
            .clamp(
              0,
              sourceImage.width
                  .toDouble(),
            )
            .toDouble(),

        ((cropRect.top -
                    imageRect.top) *
                scaleY)
            .clamp(
              0,
              sourceImage.height
                  .toDouble(),
            )
            .toDouble(),

        ((cropRect.right -
                    imageRect.left) *
                scaleX)
            .clamp(
              0,
              sourceImage.width
                  .toDouble(),
            )
            .toDouble(),

        ((cropRect.bottom -
                    imageRect.top) *
                scaleY)
            .clamp(
              0,
              sourceImage.height
                  .toDouble(),
            )
            .toDouble(),
      );

      final recorder =
          ui.PictureRecorder();

      final canvas =
          Canvas(recorder);

      canvas.drawImageRect(
        sourceImage,
        sourceCrop,
        const Rect.fromLTWH(
          0,
          0,
          640,
          640,
        ),
        Paint()
          ..filterQuality =
              FilterQuality.high,
      );

      sourceImage.dispose();
      codec.dispose();

      final output =
          await recorder
              .endRecording()
              .toImage(
                _outputDimension,
                _outputDimension,
              );

      final data =
          await output.toByteData(
        format:
            ui.ImageByteFormat.png,
      );

      output.dispose();

      if (data == null) {
        throw StateError(
          'Could not encode crop',
        );
      }

      final path =
          '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}'
          'wrytte_profile_'
          '${DateTime.now().microsecondsSinceEpoch}.png';

      await File(path).writeAsBytes(
        data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        ),
        flush: true,
      );

      if (mounted) {
        Navigator.of(context).pop(
          path,
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(
        () => _saving = false,
      );

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Could not prepare this photo.',
            ),
          ),
        );
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final disabled =
        MediaQuery.disableAnimationsOf(
      context,
    );

    final controls = disabled
        ? const AlwaysStoppedAnimation<
            double>(
            1,
          )
        : CurvedAnimation(
            parent:
                widget.routeAnimation,
            curve: const Interval(
              .42,
              1,
              curve:
                  Curves.easeOutCubic,
            ),
            reverseCurve:
                const Interval(
              0,
              .62,
              curve:
                  Curves.easeInCubic,
            ),
          );

    return PopScope(
      canPop: !_saving,
      child:
          AnnotatedRegion<
              SystemUiOverlayStyle>(
        value:
            const SystemUiOverlayStyle(
          statusBarColor:
              Colors.transparent,
          statusBarIconBrightness:
              Brightness.light,
          systemNavigationBarColor:
              Colors.transparent,
          systemNavigationBarIconBrightness:
              Brightness.light,
        ),
        child: Scaffold(
          backgroundColor:
              Colors.black,
          body: LayoutBuilder(
            builder: (
              context,
              constraints,
            ) {
              final viewport =
                  constraints.biggest;

              final cropRect =
                  _resolveCropRect(
                _cropRectFor(
                  viewport,
                  MediaQuery.paddingOf(
                    context,
                  ),
                ),
              );

              final imageSize =
                  _displayedImageSize(
                cropRect,
                _imageScale,
              );

              final imageRect =
                  Rect.fromCenter(
                center:
                    cropRect.center +
                        _imageOffset,
                width:
                    imageSize.width,
                height:
                    imageSize.height,
              );

              return Stack(
                fit:
                    StackFit.expand,
                children: [
                  GestureDetector(
                    behavior:
                        HitTestBehavior
                            .opaque,

                    onScaleStart:
                        _handleScaleStart,

                    onScaleUpdate:
                        _handleScaleUpdate,

                    onScaleEnd:
                        _handleScaleEnd,

                    child: Stack(
                      fit:
                          StackFit.expand,
                      children: [
                        Positioned.fromRect(
                          rect:
                              imageRect,
                          child: Image(
                            image:
                                widget
                                    .displayImage,
                            fit:
                                BoxFit.fill,
                            gaplessPlayback:
                                true,
                            filterQuality:
                                FilterQuality
                                    .high,
                          ),
                        ),

                        IgnorePointer(
                          child:
                              CustomPaint(
                            painter:
                                _CircularCropMask(
                              cropRect,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  PositionedDirectional(
                    top: 0,
                    start: 0,
                    end: 0,
                    child: SafeArea(
                      bottom:
                          false,
                      child:
                          AnimatedBuilder(
                        animation:
                            widget
                                .routeAnimation,
                        child:
                            SizedBox(
                          height: 64,
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .spaceBetween,
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsetsDirectional
                                        .only(
                                  start:
                                      12,
                                ),
                                child:
                                    MediaCircleButton(
                                  semanticLabel:
                                      'Back',
                                  onPressed:
                                      _saving
                                          ? null
                                          : () =>
                                              Navigator.of(
                                                context,
                                              ).maybePop(),
                                  child:
                                      const WrytteSvgIcon(
                                    asset:
                                        'assets/svg/ic--round-arrow-back-ios.svg',
                                    size:
                                        24,
                                    color:
                                        WrytteColors.textPrimary,
                                  ),
                                ),
                              ),

                              Padding(
                                padding:
                                    const EdgeInsetsDirectional
                                        .only(
                                  end:
                                      12,
                                ),
                                child:
                                    MediaCircleButton(
                                  semanticLabel:
                                      'Choose photo',
                                  onPressed:
                                      _saving
                                          ? null
                                          : _save,
                                  backgroundColor:
                                      WrytteColors.primary,
                                  child:
                                      _saving
                                          ? const SizedBox.square(
                                              dimension:
                                                  18,
                                              child:
                                                  CircularProgressIndicator(
                                                strokeWidth:
                                                    2,
                                                color:
                                                    Colors.white,
                                              ),
                                            )
                                          : const WrytteSvgIcon(
                                              asset:
                                                  'assets/svg/Checkmark edit.svg',
                                              size:
                                                  23,
                                              color:
                                                  Colors.white,
                                            ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        builder: (
                          context,
                          child,
                        ) =>
                            IgnorePointer(
                          ignoring:
                              !disabled &&
                                  widget.routeAnimation.value <
                                      .9,
                          child:
                              Opacity(
                            opacity:
                                controls.value,
                            child:
                                child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CircularCropMask
    extends CustomPainter {
  const _CircularCropMask(
    this.cropRect,
  );

  final Rect cropRect;

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final mask = Path()
      ..fillType =
          PathFillType.evenOdd
      ..addRect(
        Offset.zero & size,
      )
      ..addOval(
        cropRect,
      );

    canvas.drawPath(
      mask,
      Paint()
        ..isAntiAlias = true
        ..color = Colors.black
            .withValues(
          alpha: .56,
        ),
    );
  }

  @override
  bool shouldRepaint(
    covariant _CircularCropMask
        oldDelegate,
  ) =>
      oldDelegate.cropRect !=
      cropRect;
}