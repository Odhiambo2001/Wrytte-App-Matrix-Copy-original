import 'package:wrytte/domain/models/attachment_contact.dart';
import 'package:wrytte/domain/models/camera_capture_result.dart';
import 'package:wrytte/domain/models/media_asset.dart';
import 'package:wrytte/domain/models/picked_attachment_file.dart';
import 'package:wrytte/domain/models/poll_attachment_draft.dart';

class AttachmentGalleryResult {
  const AttachmentGalleryResult(this.assets)
    : cameraCapture = null,
      preparedFilePath = null,
      files = const [],
      contacts = const [],
      locationLabel = null,
      poll = null;

  const AttachmentGalleryResult.camera(this.cameraCapture)
    : assets = const <MediaAsset>[],
      preparedFilePath = null,
      files = const [],
      contacts = const [],
      locationLabel = null,
      poll = null;

  const AttachmentGalleryResult.prepared(this.preparedFilePath)
    : assets = const <MediaAsset>[],
      cameraCapture = null,
      files = const [],
      contacts = const [],
      locationLabel = null,
      poll = null;

  const AttachmentGalleryResult.files(this.files)
    : assets = const [],
      cameraCapture = null,
      preparedFilePath = null,
      contacts = const [],
      locationLabel = null,
      poll = null;

  const AttachmentGalleryResult.contacts(this.contacts)
    : assets = const [],
      cameraCapture = null,
      preparedFilePath = null,
      files = const [],
      locationLabel = null,
      poll = null;

  const AttachmentGalleryResult.location(this.locationLabel)
    : assets = const [],
      cameraCapture = null,
      preparedFilePath = null,
      files = const [],
      contacts = const [],
      poll = null;

  const AttachmentGalleryResult.poll(this.poll)
    : assets = const [],
      cameraCapture = null,
      preparedFilePath = null,
      files = const [],
      contacts = const [],
      locationLabel = null;

  final List<MediaAsset> assets;
  final CameraCaptureResult? cameraCapture;
  final String? preparedFilePath;
  final List<PickedAttachmentFile> files;
  final List<AttachmentContact> contacts;
  final String? locationLabel;
  final PollAttachmentDraft? poll;

  MediaAsset? get firstOrNull => assets.isEmpty ? null : assets.first;
}
