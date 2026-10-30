import 'dart:typed_data';

// =============================================================================
// Message type
// =============================================================================

enum ChatMessageKind { text, image, video, audio, file, contact }

// =============================================================================
// Delivery
// =============================================================================

enum ChatDeliveryState { pending, sent, delivered, read, failed }

// =============================================================================
// Chat message presentation
// =============================================================================

class ChatMessagePresentation {
  const ChatMessagePresentation({
    required this.id,
    required this.kind,
    required this.isMine,
    required this.timeLabel,

    this.dayLabel = 'Today',

    this.text,
    this.assetPath,

    // File
    this.fileName,
    this.fileDetails,

    // Audio
    this.audioDurationSeconds,
    this.audioWaveform = const <double>[],

    // Video
    this.videoDurationSeconds,
    this.videoThumbnailBytes,
    this.videoThumbnailUrl,
    this.mediaWidth,
    this.mediaHeight,

    // Circular recorded video-message / video-note.
    this.isVideoNote = false,

    // Sender
    this.senderName,

    // Reply
    this.replySender,
    this.replyPreview,

    // Contact
    this.contactName,
    this.contactPhone,
    this.contactAvatarUrl,
    this.contactUserId,

    // State
    this.edited = false,
    this.pinned = false,
    this.deliveryState = ChatDeliveryState.delivered,
  });

  // ===========================================================================
  // Core
  // ===========================================================================

  final String id;

  final ChatMessageKind kind;

  final bool isMine;

  final String timeLabel;

  /// Human-readable day heading used to group the message timeline.
  ///
  /// This is presentation data rather than repository data. A connected chat
  /// will derive it from the message timestamp before creating this model.
  final String dayLabel;

  // ===========================================================================
  // Text / media
  // ===========================================================================

  final String? text;

  final String? assetPath;

  // ===========================================================================
  // File
  // ===========================================================================

  final String? fileName;

  final String? fileDetails;

  // ===========================================================================
  // Audio
  // ===========================================================================

  final int? audioDurationSeconds;

  final List<double> audioWaveform;

  // ===========================================================================
  // Video
  // ===========================================================================

  final int? videoDurationSeconds;

  final Uint8List? videoThumbnailBytes;

  final String? videoThumbnailUrl;

  final int? mediaWidth;

  final int? mediaHeight;

  /// true:
  /// circular recorded video message.
  ///
  /// false:
  /// normal rectangular video attachment.
  final bool isVideoNote;

  // ===========================================================================
  // Sender / reply
  // ===========================================================================

  final String? senderName;

  final String? replySender;

  final String? replyPreview;

  // ===========================================================================
  // Contact
  // ===========================================================================

  final String? contactName;

  final String? contactPhone;

  final String? contactAvatarUrl;

  final String? contactUserId;

  // ===========================================================================
  // State
  // ===========================================================================

  final bool edited;

  final bool pinned;

  final ChatDeliveryState deliveryState;

  ChatMessagePresentation withContactAvatar(String? avatar) =>
      ChatMessagePresentation(
        id: id,
        kind: kind,
        isMine: isMine,
        timeLabel: timeLabel,
        dayLabel: dayLabel,
        text: text,
        assetPath: assetPath,
        fileName: fileName,
        fileDetails: fileDetails,
        audioDurationSeconds: audioDurationSeconds,
        audioWaveform: audioWaveform,
        videoDurationSeconds: videoDurationSeconds,
        videoThumbnailBytes: videoThumbnailBytes,
        videoThumbnailUrl: videoThumbnailUrl,
        mediaWidth: mediaWidth,
        mediaHeight: mediaHeight,
        isVideoNote: isVideoNote,
        senderName: senderName,
        replySender: replySender,
        replyPreview: replyPreview,
        contactName: contactName,
        contactPhone: contactPhone,
        contactAvatarUrl: avatar,
        contactUserId: contactUserId,
        edited: edited,
        pinned: pinned,
        deliveryState: deliveryState,
      );

  ChatMessagePresentation withPinned(bool value) => ChatMessagePresentation(
    id: id,
    kind: kind,
    isMine: isMine,
    timeLabel: timeLabel,
    dayLabel: dayLabel,
    text: text,
    assetPath: assetPath,
    fileName: fileName,
    fileDetails: fileDetails,
    audioDurationSeconds: audioDurationSeconds,
    audioWaveform: audioWaveform,
    videoDurationSeconds: videoDurationSeconds,
    videoThumbnailBytes: videoThumbnailBytes,
    videoThumbnailUrl: videoThumbnailUrl,
    mediaWidth: mediaWidth,
    mediaHeight: mediaHeight,
    isVideoNote: isVideoNote,
    senderName: senderName,
    replySender: replySender,
    replyPreview: replyPreview,
    contactName: contactName,
    contactPhone: contactPhone,
    contactAvatarUrl: contactAvatarUrl,
    contactUserId: contactUserId,
    edited: edited,
    pinned: value,
    deliveryState: deliveryState,
  );

  ChatMessagePresentation withEditedContent({
    required String? text,
    String? assetPath,
  }) => ChatMessagePresentation(
    id: id,
    kind: kind,
    isMine: isMine,
    timeLabel: timeLabel,
    dayLabel: dayLabel,
    text: text,
    assetPath: assetPath ?? this.assetPath,
    fileName: fileName,
    fileDetails: fileDetails,
    audioDurationSeconds: audioDurationSeconds,
    audioWaveform: audioWaveform,
    videoDurationSeconds: videoDurationSeconds,
    videoThumbnailBytes: videoThumbnailBytes,
    videoThumbnailUrl: videoThumbnailUrl,
    mediaWidth: mediaWidth,
    mediaHeight: mediaHeight,
    isVideoNote: isVideoNote,
    senderName: senderName,
    replySender: replySender,
    replyPreview: replyPreview,
    contactName: contactName,
    contactPhone: contactPhone,
    contactAvatarUrl: contactAvatarUrl,
    contactUserId: contactUserId,
    edited: true,
    pinned: pinned,
    deliveryState: deliveryState,
  );
}
