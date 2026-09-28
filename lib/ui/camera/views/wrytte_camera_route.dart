import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';
import 'package:wrytte/ui/camera/models/camera_route_result.dart';
import 'package:wrytte/ui/camera/views/wrytte_camera_view.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/core/routing/expanding_surface_route.dart';

Future<CameraRouteResult?> showWrytteCamera(
  BuildContext context, {
  required CameraRepository repository,
  required CameraSessionConfig config,
  ExpandingSurfaceOrigin? origin,
  Uint8List? galleryThumbnail,
  bool returnToGallery = false,
  bool keepSessionAliveOnExit = false,
  CameraCaptureReviewer? captureReviewer,
}) {
  final animationsDisabled = MediaQuery.disableAnimationsOf(context);
  return Navigator.of(context, rootNavigator: true).push<CameraRouteResult>(
    ExpandingSurfaceRoute<CameraRouteResult>(
      origin: origin,
      animationsDisabled: animationsDisabled,
      builder: (context, animation) => WrytteCameraView(
        repository: repository,
        config: config,
        keepSessionAliveOnExit: keepSessionAliveOnExit,
        routeAnimation: animation,
        galleryThumbnail: galleryThumbnail,
        returnToGallery: returnToGallery,
        captureReviewer: captureReviewer,
      ),
    ),
  );
}
