import 'package:flutter/foundation.dart';

import 'package:wrytte/ui/chat/models/chat_message_presentation.dart';

import 'package:wrytte/ui/chat/models/chat_screen_config.dart';

// =============================================================================

// Record mode

// =============================================================================

enum ChatRecordMode { audio, video }

// =============================================================================

// Chat view model

// =============================================================================

class ChatViewModel extends ChangeNotifier {
  ChatViewModel({required this.config})
    : _messages = List<ChatMessagePresentation>.of(_previewMessages);

  final ChatScreenConfig config;

  final List<ChatMessagePresentation> _messages;

  ChatRecordMode _recordMode = ChatRecordMode.audio;

  // ===========================================================================

  // Public state

  // ===========================================================================

  List<ChatMessagePresentation> get messages =>
      List<ChatMessagePresentation>.unmodifiable(_messages);

  ChatRecordMode get recordMode => _recordMode;

  // ===========================================================================

  // Record mode

  // ===========================================================================

  void toggleRecordMode() {
    _recordMode = _recordMode == ChatRecordMode.audio
        ? ChatRecordMode.video
        : ChatRecordMode.audio;

    notifyListeners();
  }

  // ===========================================================================

  // Text

  // ===========================================================================

  void sendPreviewMessage(
    String value, {
    String? replySender,
    String? replyPreview,
  }) {
    final text = value.trim();

    if (text.isEmpty) {
      return;
    }

    _messages.add(
      ChatMessagePresentation(
        id: 'text-${_messages.length}',

        kind: ChatMessageKind.text,

        isMine: true,

        timeLabel: _clockLabel(DateTime.now()),

        text: text,

        replySender: replySender,

        replyPreview: replyPreview,

        deliveryState: ChatDeliveryState.sent,
      ),
    );

    notifyListeners();
  }

  // ===========================================================================

  // Image

  // ===========================================================================

  void sendPreviewImage(
    String path, {

    String? caption,

    int? mediaWidth,

    int? mediaHeight,
  }) {
    final cleanPath = path.trim();

    final cleanCaption = caption?.trim();

    if (cleanPath.isEmpty) {
      return;
    }

    _messages.add(
      ChatMessagePresentation(
        id: 'image-${_messages.length}',

        kind: ChatMessageKind.image,

        isMine: true,

        timeLabel: _clockLabel(DateTime.now()),

        assetPath: cleanPath,

        text: cleanCaption?.isNotEmpty == true ? cleanCaption : null,

        mediaWidth: mediaWidth,

        mediaHeight: mediaHeight,

        deliveryState: ChatDeliveryState.sent,
      ),
    );

    notifyListeners();
  }

  // ===========================================================================

  // Normal rectangular video

  // ===========================================================================

  void sendPreviewVideo(
    String path, {

    String? caption,

    int? durationSeconds,

    int? mediaWidth,

    int? mediaHeight,

    Uint8List? thumbnailBytes,

    String? thumbnailUrl,
  }) {
    final cleanPath = path.trim();

    final cleanCaption = caption?.trim();

    final cleanThumbnailUrl = thumbnailUrl?.trim();

    if (cleanPath.isEmpty) {
      return;
    }

    _messages.add(
      ChatMessagePresentation(
        id: 'video-${_messages.length}',

        kind: ChatMessageKind.video,

        // Normal rectangular video.
        isVideoNote: false,

        isMine: true,

        timeLabel: _clockLabel(DateTime.now()),

        assetPath: cleanPath,

        text: cleanCaption?.isNotEmpty == true ? cleanCaption : null,

        videoDurationSeconds: durationSeconds,

        videoThumbnailBytes: thumbnailBytes,

        videoThumbnailUrl: cleanThumbnailUrl?.isNotEmpty == true
            ? cleanThumbnailUrl
            : null,

        mediaWidth: mediaWidth,

        mediaHeight: mediaHeight,

        deliveryState: ChatDeliveryState.sent,
      ),
    );

    notifyListeners();
  }

  void sendPreviewRoundVideo(String path, {required int durationSeconds}) {
    final cleanPath = path.trim();
    if (cleanPath.isEmpty) return;
    _messages.add(
      ChatMessagePresentation(
        id: 'round-video-${_messages.length}',
        kind: ChatMessageKind.video,
        isVideoNote: true,
        isMine: true,
        timeLabel: _clockLabel(DateTime.now()),
        assetPath: cleanPath,
        videoDurationSeconds: durationSeconds,
        deliveryState: ChatDeliveryState.sent,
      ),
    );
    notifyListeners();
  }

  void sendPreviewVoice(String path, {required int durationSeconds}) {
    sendPreviewFile(
      path: path,
      name: 'Voice message',
      details: 'Audio',
      audioDurationSeconds: durationSeconds,
    );
  }

  // ===========================================================================

  // File

  // ===========================================================================

  void sendPreviewFile({
    required String path,

    required String name,

    required String details,

    String? caption,

    int? audioDurationSeconds,
  }) {
    final cleanPath = path.trim();

    final cleanName = name.trim();

    final cleanDetails = details.trim();

    final cleanCaption = caption?.trim();

    if (cleanPath.isEmpty || cleanName.isEmpty) {
      return;
    }

    _messages.add(
      ChatMessagePresentation(
        id: 'file-${_messages.length}',

        kind: ChatMessageKind.file,

        isMine: true,

        timeLabel: _clockLabel(DateTime.now()),

        assetPath: cleanPath,

        fileName: cleanName,

        fileDetails: cleanDetails.isNotEmpty ? cleanDetails : null,

        text: cleanCaption?.isNotEmpty == true ? cleanCaption : null,

        audioDurationSeconds: audioDurationSeconds,

        deliveryState: ChatDeliveryState.sent,
      ),
    );

    notifyListeners();
  }

  // ===========================================================================

  // Contact

  // ===========================================================================

  void sendPreviewContact({
    required String name,

    required String phone,

    String? avatarUrl,

    String? userId,
  }) {
    final cleanName = name.trim();

    final cleanPhone = phone.trim();

    final cleanAvatar = avatarUrl?.trim();

    final cleanUserId = userId?.trim();

    if (cleanName.isEmpty && cleanPhone.isEmpty) {
      return;
    }

    _messages.add(
      ChatMessagePresentation(
        id: 'contact-${_messages.length}',

        kind: ChatMessageKind.contact,

        isMine: true,

        timeLabel: _clockLabel(DateTime.now()),

        contactName: cleanName.isNotEmpty ? cleanName : 'Contact',

        contactPhone: cleanPhone,

        contactAvatarUrl: cleanAvatar?.isNotEmpty == true ? cleanAvatar : null,

        contactUserId: cleanUserId?.isNotEmpty == true ? cleanUserId : null,

        deliveryState: ChatDeliveryState.sent,
      ),
    );

    notifyListeners();
  }

  // ===========================================================================

  // Delete preview messages

  // ===========================================================================

  void removePreviewMessages(Iterable<String> messageIds) {
    final ids = messageIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    if (ids.isEmpty) {
      return;
    }

    final oldLength = _messages.length;

    _messages.removeWhere((message) => ids.contains(message.id));

    if (_messages.length != oldLength) {
      notifyListeners();
    }
  }

  void editPreviewMessage(
    String messageId, {
    required String text,
    String? assetPath,
  }) {
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index < 0) return;

    final cleanText = text.trim();
    _messages[index] = _messages[index].withEditedContent(
      text: cleanText.isEmpty ? null : cleanText,
      assetPath: assetPath?.trim().isNotEmpty == true
          ? assetPath!.trim()
          : null,
    );
    notifyListeners();
  }

  // ===========================================================================

  // Clock

  // ===========================================================================

  static String _clockLabel(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');

    final minute = value.minute.toString().padLeft(2, '0');

    return '$hour:$minute';
  }
}

// =============================================================================

// Preview conversation

//

// This gives us visible examples of:

//

// - text

// - images

// - normal videos

// - circular video messages

// - files

// - contacts

// =============================================================================

const List<ChatMessagePresentation>
_previewMessages = <ChatMessagePresentation>[
  // ===========================================================================
  // A natural preview conversation
  //
  // Scenario:
  // Two friends are planning a small rooftop video shoot for the next evening.
  // Every message exists because it makes sense in the conversation while also
  // exercising the real bubble variants.
  // ===========================================================================
  ChatMessagePresentation(
    id: 'conversation-text-incoming-1',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:10',
    dayLabel: 'Yesterday',
    text: 'Hey, are we still doing the rooftop shoot tomorrow?',
  ),

  ChatMessagePresentation(
    id: 'conversation-text-outgoing-1',
    kind: ChatMessageKind.text,
    isMine: true,
    timeLabel: '18:11',
    dayLabel: 'Yesterday',
    text: 'Yeah. I want to be there by 5:30 so we have enough time to set up ',
    deliveryState: ChatDeliveryState.read,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-incoming-2',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:12',
    dayLabel: 'Yesterday',
    text:
        'Perfect. I saved a couple of framing references for the opening shot.',
  ),

  // ---------------------------------------------------------------------------
  // Image without caption.
  //
  // The previous text gives the image context, so this still feels like a real
  // conversation while exercising the image metadata overlay.
  // ---------------------------------------------------------------------------
  ChatMessagePresentation(
    id: 'conversation-image-incoming',
    kind: ChatMessageKind.image,
    isMine: false,
    timeLabel: '18:13',
    dayLabel: 'Yesterday',
    assetPath: 'https://picsum.photos/id/1015/1200/800',
    mediaWidth: 1200,
    mediaHeight: 800,
  ),

  // ---------------------------------------------------------------------------
  // Image with caption.
  //
  // This intentionally has enough text to exercise the same wrapping +
  // metadata-placement rules as TextMessageBubble.
  // ---------------------------------------------------------------------------
  ChatMessagePresentation(
    id: 'conversation-image-outgoing-caption',
    kind: ChatMessageKind.image,
    isMine: true,
    timeLabel: '18:14',
    dayLabel: 'Yesterday',
    assetPath: 'https://picsum.photos/id/1016/1200/800',
    mediaWidth: 1200,
    mediaHeight: 800,
    text:
        'I like this framing more. The subject still has breathing room, but '
        'the background feels wide enough for the opening.',
    deliveryState: ChatDeliveryState.read,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-incoming-3',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:15',
    dayLabel: 'Yesterday',
    text:
        'Exactly. I also found a reference clip for the camera movement I was '
        'trying to explain.',
  ),

  // ---------------------------------------------------------------------------
  // Normal video without caption.
  //
  // IMPORTANT:
  // This MP4 and poster belong to the same MDN Tears of Steel example.
  // The thumbnail is not an unrelated placeholder image.
  // ---------------------------------------------------------------------------
  ChatMessagePresentation(
    id: 'conversation-video-incoming',
    kind: ChatMessageKind.video,
    isVideoNote: false,
    isMine: false,
    timeLabel: '18:16',
    dayLabel: 'Yesterday',
    assetPath:
        'https://developer.mozilla.org/shared-assets/videos/'
        'tears-of-steel-battle-clip-medium.mp4',
    videoThumbnailUrl:
        'https://developer.mozilla.org/shared-assets/images/examples/'
        'tears-of-steel-battle-clip-medium-poster.jpg',
    mediaWidth: 1024,
    mediaHeight: 576,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-outgoing-2',
    kind: ChatMessageKind.text,
    isMine: true,
    timeLabel: '18:17',
    dayLabel: 'Yesterday',
    text:
        'Yep, I see what you mean. I’d keep ours a little slower at the end so '
        'the last frame has time to breathe.',
    deliveryState: ChatDeliveryState.read,
  ),

  // ---------------------------------------------------------------------------
  // Normal video with caption.
  //
  // This second MDN teaching sample has its own poster.png beside the video.
  // It gives the captioned video bubble a separate, coherent media example.
  // ---------------------------------------------------------------------------
  ChatMessagePresentation(
    id: 'conversation-video-outgoing-caption',
    kind: ChatMessageKind.video,
    isVideoNote: false,
    isMine: true,
    timeLabel: '18:18',
    dayLabel: 'Yesterday',
    assetPath:
        'https://mdn.github.io/learning-area/html/multimedia-and-embedding/'
        'video-and-audio-content/rabbit320.mp4',
    videoThumbnailUrl:
        'https://mdn.github.io/learning-area/html/multimedia-and-embedding/'
        'video-and-audio-content/poster.png',
    text:
        'This is closer to the pacing I mean — steady movement first, then let '
        'the shot settle instead of cutting immediately.',
    mediaWidth: 320,
    mediaHeight: 240,
    deliveryState: ChatDeliveryState.delivered,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-incoming-4',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:19',
    text: 'That works. I’ll bring the small LED panel too.',
  ),

  // Reply and edited/pinned text variants. Audio bubbles are deliberately not
  // part of this preview conversation while recording is being rebuilt.
  ChatMessagePresentation(
    id: 'conversation-text-outgoing-reply',
    kind: ChatMessageKind.text,
    isMine: true,
    timeLabel: '18:20',
    text: 'Good call. I’ll pack the spare batteries with it.',
    replySender: 'Alex',
    replyPreview: 'That works. I’ll bring the small LED panel too.',
    deliveryState: ChatDeliveryState.read,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-incoming-edited-pinned',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:21',
    text: 'Meet at the east entrance at 5:30. Security already has our names.',
    edited: true,
    pinned: true,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-incoming-5',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:22',
    text: 'Perfect. I sent the shot list too so you can check the order.',
  ),

  // ---------------------------------------------------------------------------
  // Incoming PDF/file bubble.
  // ---------------------------------------------------------------------------
  ChatMessagePresentation(
    id: 'conversation-file-incoming',
    kind: ChatMessageKind.file,
    isMine: false,
    timeLabel: '18:23',
    assetPath:
        'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/'
        'dummy.pdf',
    fileName: 'Rooftop shot list.pdf',
    fileDetails: '1.8 MB · PDF',
  ),

  ChatMessagePresentation(
    id: 'conversation-file-outgoing',
    kind: ChatMessageKind.file,
    isMine: true,
    timeLabel: '18:24',
    assetPath:
        'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/'
        'dummy.pdf',
    fileName: 'Lighting notes.pdf',
    fileDetails: '840 KB · PDF',
    deliveryState: ChatDeliveryState.sent,
  ),

  ChatMessagePresentation(
    id: 'conversation-file-docx-incoming',
    kind: ChatMessageKind.file,
    isMine: false,
    timeLabel: '18:24',
    assetPath: 'https://example.com/files/rooftop-call-sheet.docx',
    fileName: 'Rooftop call sheet.docx',
    fileDetails: '126 KB · DOCX',
  ),

  ChatMessagePresentation(
    id: 'conversation-file-xlsx-outgoing',
    kind: ChatMessageKind.file,
    isMine: true,
    timeLabel: '18:24',
    assetPath: 'https://example.com/files/equipment-checklist.xlsx',
    fileName: 'Equipment checklist.xlsx',
    fileDetails: '94 KB · XLSX',
    deliveryState: ChatDeliveryState.delivered,
  ),

  ChatMessagePresentation(
    id: 'conversation-file-pptx-incoming',
    kind: ChatMessageKind.file,
    isMine: false,
    timeLabel: '18:24',
    assetPath: 'https://example.com/files/visual-direction.pptx',
    fileName: 'Visual direction.pptx',
    fileDetails: '3.2 MB · PPTX',
  ),

  ChatMessagePresentation(
    id: 'conversation-file-zip-outgoing',
    kind: ChatMessageKind.file,
    isMine: true,
    timeLabel: '18:25',
    assetPath: 'https://example.com/files/reference-stills.zip',
    fileName: 'Reference stills.zip',
    fileDetails: '12.4 MB · ZIP',
    deliveryState: ChatDeliveryState.read,
  ),

  ChatMessagePresentation(
    id: 'conversation-file-txt-incoming',
    kind: ChatMessageKind.file,
    isMine: false,
    timeLabel: '18:25',
    assetPath: 'https://example.com/files/access-notes.txt',
    fileName: 'Access notes.txt',
    fileDetails: '8 KB · TXT',
    text: 'The building manager added a few access details.',
  ),

  ChatMessagePresentation(
    id: 'conversation-text-incoming-6',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:25',
    text:
        'Maya said she can help with the second setup. Here’s her number in '
        'case you get there before me.',
  ),

  // ---------------------------------------------------------------------------
  // Contact bubble.
  // ---------------------------------------------------------------------------
  ChatMessagePresentation(
    id: 'conversation-contact-incoming',
    kind: ChatMessageKind.contact,
    isMine: false,
    timeLabel: '18:26',
    contactName: 'Maya Chen',
    contactPhone: '+1 613 555 0142',
  ),

  ChatMessagePresentation(
    id: 'conversation-contact-outgoing',
    kind: ChatMessageKind.contact,
    isMine: true,
    timeLabel: '18:27',
    contactName: 'Jordan Lee',
    contactPhone: '+1 416 555 0188',
    deliveryState: ChatDeliveryState.read,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-outgoing-3',
    kind: ChatMessageKind.text,
    isMine: true,
    timeLabel: '18:27',
    text: 'Got it. I’ll message her when I’m leaving.',
    deliveryState: ChatDeliveryState.read,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-incoming-7',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:28',
    text: 'I’ll send you a quick video note so you can see what I mean.',
  ),

  // ---------------------------------------------------------------------------
  // Incoming round video note.
  //
  // Reuse the matching rabbit sample/poster pair so the thumbnail still
  // belongs to the actual source video.
  // ---------------------------------------------------------------------------
  ChatMessagePresentation(
    id: 'conversation-round-video-incoming',
    kind: ChatMessageKind.video,
    isVideoNote: true,
    isMine: false,
    timeLabel: '18:29',
    assetPath:
        'https://mdn.github.io/learning-area/html/multimedia-and-embedding/'
        'video-and-audio-content/rabbit320.mp4',
    videoThumbnailUrl:
        'https://mdn.github.io/learning-area/html/multimedia-and-embedding/'
        'video-and-audio-content/poster.png',
  ),

  ChatMessagePresentation(
    id: 'conversation-round-video-outgoing',
    kind: ChatMessageKind.video,
    isVideoNote: true,
    isMine: true,
    timeLabel: '18:30',
    assetPath:
        'https://mdn.github.io/learning-area/html/multimedia-and-embedding/'
        'video-and-audio-content/rabbit320.mp4',
    videoThumbnailUrl:
        'https://mdn.github.io/learning-area/html/multimedia-and-embedding/'
        'video-and-audio-content/poster.png',
    deliveryState: ChatDeliveryState.read,
  ),

  ChatMessagePresentation(
    id: 'conversation-text-incoming-final',
    kind: ChatMessageKind.text,
    isMine: false,
    timeLabel: '18:31',
    text: 'Perfect. Then we’re set. See you there tomorrow.',
  ),

  ChatMessagePresentation(
    id: 'conversation-text-outgoing-final',
    kind: ChatMessageKind.text,
    isMine: true,
    timeLabel: '18:32',
    text: 'See you at 5:30 👍',
    deliveryState: ChatDeliveryState.read,
  ),
];
