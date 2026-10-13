import 'package:wrytte/domain/models/media_asset.dart';

enum AttachmentPurpose { chat, profilePhoto, channel, generic }

enum AttachmentSelectionMode { single, multiple }

enum AttachmentSheetExtent { compact, expanded }

class AttachmentGalleryConfig {
  const AttachmentGalleryConfig({
    required this.purpose,
    this.allowedKinds = const {MediaKind.image, MediaKind.video},
    this.selectionMode = AttachmentSelectionMode.multiple,
    this.maxSelectionCount = 10,
    this.initialExtent = AttachmentSheetExtent.compact,
    this.showCameraPlaceholder = true,
  }) : assert(maxSelectionCount > 0);

  const AttachmentGalleryConfig.profilePhoto()
    : purpose = AttachmentPurpose.profilePhoto,
      allowedKinds = const {MediaKind.image},
      selectionMode = AttachmentSelectionMode.single,
      maxSelectionCount = 1,
      initialExtent = AttachmentSheetExtent.compact,
      showCameraPlaceholder = true;

  final AttachmentPurpose purpose;
  final Set<MediaKind> allowedKinds;
  final AttachmentSelectionMode selectionMode;
  final int maxSelectionCount;
  final AttachmentSheetExtent initialExtent;
  final bool showCameraPlaceholder;
}
