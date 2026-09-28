import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wrytte/domain/models/attachment_gallery_config.dart';
import 'package:wrytte/domain/models/attachment_gallery_result.dart';
import 'package:wrytte/domain/models/camera_capture_result.dart';
import 'package:wrytte/domain/models/camera_session_config.dart';
import 'package:wrytte/domain/repositories/camera_repository.dart';
import 'package:wrytte/domain/repositories/media_library_repository.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/ui/auth/view_models/profile_setup_view_model.dart';
import 'package:wrytte/ui/auth/widgets/sync_contacts_switch.dart';
import 'package:wrytte/ui/camera/views/wrytte_camera_route.dart';
import 'package:wrytte/ui/camera/widgets/attachment_camera_preview.dart';
import 'package:wrytte/ui/core/models/expanding_surface_origin.dart';
import 'package:wrytte/ui/core/themes/wrytte_theme.dart';
import 'package:wrytte/ui/media/views/attachment_gallery_sheet.dart';
import 'package:wrytte/ui/media/views/full_screen_image_view.dart';
import 'package:wrytte/ui/media/views/profile_photo_crop_view.dart';
import 'package:wrytte/ui/media/widgets/media_thumbnail_image.dart';

class ProfileSetupView extends StatefulWidget {
  const ProfileSetupView({super.key});

  @override
  State<ProfileSetupView> createState() => _ProfileSetupViewState();
}

class _ProfileSetupViewState extends State<ProfileSetupView> {
  final _nameController = TextEditingController();
  final _nameFocusNode = FocusNode();

  final _fullScreenCameraOpen = ValueNotifier<bool>(false);

  final _profilePhotoKey = GlobalKey();
  bool _finishing = false;

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    _fullScreenCameraOpen.dispose();

    super.dispose();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    final model = context.read<ProfileSetupViewModel>();
    if (!model.canFinish) return;
    _finishing = true;

    FocusManager.instance.primaryFocus?.unfocus();

    try {
      var photoPath = model.profilePhotoPath;
      if (photoPath == null && model.profilePhoto != null) {
        photoPath = await context.read<MediaLibraryRepository>().loadFilePath(
          model.profilePhoto!.id,
        );
      }
      if (photoPath != null) {
        await UserProfileService.instance.saveProfileImageLocally(
          File(photoPath),
        );
      }
    } catch (error) {
      // Keep profile setup navigation available if local avatar persistence
      // fails; the chosen photo is an optional part of signup.
      debugPrint('[ProfileSetupView] profile photo save failed: $error');
    }

    final profileName = model.name.trim();
    try {
      await UserProfileService.instance.updateDisplayName(profileName);
    } catch (error) {
      debugPrint('[ProfileSetupView] display name save failed: $error');
    }

    String? userId;
    String? phone;
    try {
      userId = await AuthService.instance.getCurrentUserId();
      phone = await AuthService.instance.getSavedPhone();
    } catch (error) {
      debugPrint('[ProfileSetupView] session read failed: $error');
    }

    if (!mounted) return;

    // Profile setup completes the authentication flow. Replace the complete
    // auth location so system Back cannot return to setup or OTP screens.
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/home',
      (_) => false,
      arguments: {'profileName': profileName, 'userId': userId, 'phone': phone},
    );
  }

  Future<void> _chooseProfilePhoto() async {
    _nameFocusNode.unfocus();

    final mediaRepository = context.read<MediaLibraryRepository>();
    final cameraRepository = context.read<CameraRepository>();

    const cameraConfig = CameraSessionConfig.profilePhoto();

    final galleryResult = showWrytteAttachmentGallery(
      context,
      config: const AttachmentGalleryConfig.profilePhoto(),
      repository: mediaRepository,
      cameraPreviewBuilder: (_) => AttachmentCameraPreview(
        repository: cameraRepository,
        fullScreenCameraOpen: _fullScreenCameraOpen,
      ),
      onMediaRequested: (asset, origin) async {
        final path = await mediaRepository.loadFilePath(asset.id);

        if (!mounted || path == null) return null;

        final croppedPath = await showWrytteProfilePhotoCrop(
          context,
          sourcePath: path,
          sourcePixelSize: Size(
            asset.width.toDouble(),
            asset.height.toDouble(),
          ),
          origin: origin,
        );

        return croppedPath == null
            ? null
            : AttachmentGalleryResult.prepared(croppedPath);
      },
      onCameraRequested: (origin, latestAsset) async {
        final thumbnail = latestAsset == null
            ? null
            : await mediaRepository.loadThumbnail(
                latestAsset.id,
                width: 160,
                height: 160,
              );

        if (!mounted) return null;

        _fullScreenCameraOpen.value = true;

        try {
          final cameraResult = await showWrytteCamera(
            context,
            repository: cameraRepository,
            config: cameraConfig,
            origin: origin,
            galleryThumbnail: thumbnail,
            returnToGallery: true,
            keepSessionAliveOnExit: true,
            captureReviewer: (cameraContext, capture) =>
                _reviewCameraCapture(cameraContext, cameraRepository, capture),
          );

          return cameraResult;
        } finally {
          if (mounted) {
            _fullScreenCameraOpen.value = false;
          }
        }
      },
    );

    // The sheet paints immediately with final grid geometry. Camera startup is
    // independent, so it cannot block media loading or make the tall first tile
    // suddenly reflow into the grid when initialization completes.
    unawaited(cameraRepository.open(cameraConfig));

    AttachmentGalleryResult? result;

    try {
      result = await galleryResult;
    } finally {
      await cameraRepository.close();
    }

    if (!mounted) return;

    final profileModel = context.read<ProfileSetupViewModel>();

    final replacedTemporaryPath = profileModel.profilePhotoPath;
    final preparedPath = result?.preparedFilePath;
    final asset = result?.firstOrNull;

    if (preparedPath != null) {
      profileModel.setPreparedProfilePhoto(preparedPath);
    } else if (asset != null) {
      profileModel.setProfilePhoto(asset);
    } else if (result?.cameraCapture case final capture?) {
      profileModel.setCapturedProfilePhoto(capture);
    }

    if (replacedTemporaryPath != null &&
        replacedTemporaryPath != profileModel.profilePhotoPath) {
      unawaited(_deleteTemporaryFile(replacedTemporaryPath));
    }

    _nameFocusNode.requestFocus();
  }

  Future<CameraCaptureResult?> _reviewCameraCapture(
    BuildContext cameraContext,
    CameraRepository repository,
    CameraCaptureResult capture,
  ) async {
    try {
      await repository.pausePreview();
    } catch (_) {
      // A few vendor camera stacks do not support pausing. The crop can still
      // safely cover the live preview without rebuilding the camera session.
    }

    if (!cameraContext.mounted) return null;

    final viewport = MediaQuery.sizeOf(cameraContext);

    final croppedPath = await showWrytteProfilePhotoCrop(
      cameraContext,
      sourcePath: capture.path,
      origin: ExpandingSurfaceOrigin(
        rect: Offset.zero & viewport,
        borderRadius: BorderRadius.zero,
      ),
    );

    if (croppedPath == null) {
      unawaited(_deleteTemporaryFile(capture.path));

      try {
        await repository.resumePreview();
      } catch (_) {
        // The existing session remains owned by the camera route. Its normal
        // lifecycle recovery handles devices that reject resumePreview.
      }

      return null;
    }

    unawaited(_deleteTemporaryFile(capture.path));

    return CameraCaptureResult(
      path: croppedPath,
      type: capture.type,
      capturedAt: capture.capturedAt,
      cameraId: capture.cameraId,
      zoom: capture.zoom,
      duration: capture.duration,
    );
  }

  Future<void> _viewProfilePhoto() async {
    _nameFocusNode.unfocus();

    final model = context.read<ProfileSetupViewModel>();

    var path = model.profilePhotoPath;

    if (path == null && model.profilePhoto != null) {
      path = await context.read<MediaLibraryRepository>().loadFilePath(
        model.profilePhoto!.id,
      );
    }

    if (!mounted) return;

    if (path == null) {
      _nameFocusNode.requestFocus();
      return;
    }

    final origin = ExpandingSurfaceOrigin.fromKey(
      _profilePhotoKey,
      borderRadius: BorderRadius.circular(1000),
    );

    final result = await showWrytteImageViewer(
      context,
      image: FileImage(File(path)),
      imageAspectRatio: 1,
      origin: origin,
      onShare: _showProfilePhotoSharePreview,
      allowDelete: true,
      showHeaderLabel: false,
      enableVerticalDragDismiss: true,
    );

    if (!mounted) return;

    if (result == FullScreenImageResult.deleteRequested) {
      final removedPath = model.profilePhotoPath;

      model.clearProfilePhoto();

      if (removedPath != null) {
        unawaited(_deleteTemporaryFile(removedPath));
      }
    }

    _nameFocusNode.requestFocus();
  }

  void _showProfilePhotoSharePreview() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Profile photo sharing will be available here.'),
        ),
      );
  }

  Future<void> _deleteTemporaryFile(String path) async {
    try {
      final file = File(path);

      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Temporary-file cleanup must not disturb navigation.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WrytteColors.background,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WrytteSpacing.contentMaxWidth,
            ),
            child: Consumer<ProfileSetupViewModel>(
              builder: (context, model, _) => SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(
                        height: 48,
                        child: TextButton(
                          onPressed: model.canFinish ? _finish : null,
                          child: Text(
                            'Done',
                            style: TextStyle(
                              fontFamily: WrytteTypography.primaryFontFamily,
                              color: model.canFinish
                                  ? WrytteColors.textPrimary
                                  : Theme.of(context).disabledColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    Center(
                      child: Semantics(
                        button: true,
                        label: model.hasProfilePhoto
                            ? 'View profile photo'
                            : 'Set profile photo',
                        child: GestureDetector(
                          onTap: model.hasProfilePhoto
                              ? _viewProfilePhoto
                              : _chooseProfilePhoto,
                          child: ClipOval(
                            child: SizedBox.square(
                              key: _profilePhotoKey,
                              dimension: 104,
                              child: !model.hasProfilePhoto
                                  ? const ColoredBox(
                                      color: WrytteColors.surfaceRaised,
                                      child: Icon(
                                        Icons.person_rounded,
                                        color: WrytteColors.textPrimary,
                                        size: 58,
                                      ),
                                    )
                                  : model.profilePhotoPath != null
                                  ? Image.file(
                                      File(model.profilePhotoPath!),
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                      filterQuality: FilterQuality.medium,
                                    )
                                  : MediaAssetThumbnail(
                                      asset: model.profilePhoto!,
                                      repository: context
                                          .read<MediaLibraryRepository>(),
                                      pixelSize:
                                          (104 *
                                                  MediaQuery.devicePixelRatioOf(
                                                    context,
                                                  ))
                                              .ceil(),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    GestureDetector(
                      key: const ValueKey('profile-photo-label-action'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _chooseProfilePhoto,
                      child: const Text(
                        'Set profile photo',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: WrytteTypography.primaryFontFamily,
                          color: WrytteColors.primary,
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),

                    const SizedBox(height: 34),

                    TextField(
                      key: const ValueKey('profile-name-field'),
                      controller: _nameController,
                      focusNode: _nameFocusNode,
                      autofocus: true,
                      keyboardType: TextInputType.name,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.name],
                      cursorColor: WrytteColors.primary,
                      style: const TextStyle(
                        fontFamily: WrytteTypography.primaryFontFamily,
                        color: WrytteColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        height: 1.4,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Enter name',
                        hintStyle: TextStyle(
                          fontFamily: WrytteTypography.primaryFontFamily,
                          color: WrytteColors.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.normal,
                          height: 1.4,
                        ),

                        // No filled background.
                        filled: false,

                        constraints: BoxConstraints(minHeight: 56),

                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 17,
                        ),

                        border: _profileNameBorder,
                        enabledBorder: _profileNameBorder,
                        focusedBorder: _profileNameBorder,
                        disabledBorder: _profileNameBorder,
                      ),
                      onChanged: model.changeName,
                      onSubmitted: (_) => _finish(),
                    ),

                    const SizedBox(height: 10),

                    const Text(
                      'Your name must include at least 1 letter or symbol',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: WrytteTypography.primaryFontFamily,
                        color: WrytteColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.normal,
                        height: 1.4,
                      ),
                    ),

                    const SizedBox(height: 24),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Sync contacts',
                              style: TextStyle(
                                fontFamily: WrytteTypography.primaryFontFamily,
                                color: WrytteColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                height: 1.4,
                              ),
                            ),
                          ),
                          SyncContactsSwitch(
                            value: model.syncContacts,
                            onChanged: model.setSyncContacts,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _profileNameBorder = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(28)),
  borderSide: BorderSide(color: WrytteColors.surfaceRaised, width: 1.5),
);
