import 'dart:convert';

import 'package:matrix/matrix.dart' as mx;

enum MessageStatus { sending, sent, delivered, read, failed }

bool _boolFromJson(Object? value) =>
    value == true || value == 1 || value?.toString() == '1';

MessageStatus _statusFromString(String? value) {
  switch (value) {
    case "sent":
      return MessageStatus.sent;
    case "delivered":
      return MessageStatus.delivered;
    case "read":
      return MessageStatus.read;
    case "failed":
      return MessageStatus.failed;
    case "sending":
    default:
      return MessageStatus.sending;
  }
}

String _statusToString(MessageStatus status) {
  return status.name;
}

class ChatMessage {
  final String id;
  final String conversationId;

  /// Sender userId
  final String senderId;

  /// Receiver Matrix userId or direct-chat peer id.
  final String receiverId;

  final String content;
  final DateTime timestamp;
  final MessageStatus status;
  final String? attachmentUrl;

  // ── attachmentType values used in this app ─────────────────────────────────
  // 'voice'  → voice note
  // 'video'  → video clip
  // 'image'  → image
  final String? attachmentType;
  final int? mediaWidth;
  final int? mediaHeight;

  // ── Voice-note duration in seconds (null for non-voice messages) ───────────
  // Populated from Matrix media metadata when receiving and recorder output
  // when sending.
  final int? voiceDuration;

  final int unreadCount;
  final String? replyToMessageId;
  final String? replyToSenderId;
  final String? replyPreview;
  final String? senderPhone;
  final String? senderName;
  final bool isForwarded;
  final bool isStarred;
  final bool isDeletedForMe;
  final bool isDeletedForEveryone;
  final bool isEdited;
  final bool isVoiceListened;

  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.receiverId,
    required this.content,
    required this.timestamp,
    this.status = MessageStatus.sending,
    this.attachmentUrl,
    this.attachmentType,
    this.mediaWidth,
    this.mediaHeight,
    this.voiceDuration, // ← NEW
    this.unreadCount = 0,
    this.replyToMessageId,
    this.replyToSenderId,
    this.replyPreview,
    this.senderPhone,
    this.senderName,
    this.isForwarded = false,
    this.isStarred = false,
    this.isDeletedForMe = false,
    this.isDeletedForEveryone = false,
    this.isEdited = false,
    this.isVoiceListened = false,
  });

  // FROM JSON (Backend / local DB)

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json["id"]?.toString() ?? "",
      conversationId: json["conversationId"]?.toString() ?? "",
      senderId: json["senderId"]?.toString() ?? "",
      receiverId: json["receiverId"]?.toString() ?? "",
      content: json["content"]?.toString() ?? "",
      timestamp:
          json["timestamp"] != null
              ? DateTime.tryParse(json["timestamp"].toString()) ??
                  DateTime.now()
              : DateTime.now(),
      status: _statusFromString(json["status"]?.toString()),
      attachmentUrl: json["attachmentUrl"]?.toString(),
      attachmentType: json["attachmentType"]?.toString(),
      mediaWidth: int.tryParse(json["mediaWidth"]?.toString() ?? ''),
      mediaHeight: int.tryParse(json["mediaHeight"]?.toString() ?? ''),
      voiceDuration:
          json["voiceDuration"] !=
                  null // ← NEW
              ? int.tryParse(json["voiceDuration"].toString())
              : null,
      replyToMessageId: json["replyToMessageId"]?.toString(),
      replyToSenderId: json["replyToSenderId"]?.toString(),
      replyPreview: json["replyPreview"]?.toString(),
      senderPhone: json["senderPhone"]?.toString(),
      senderName: json["senderName"]?.toString(),
      isForwarded: _boolFromJson(json["isForwarded"]),
      isStarred: _boolFromJson(json["isStarred"]),
      isDeletedForMe: _boolFromJson(json["isDeletedForMe"]),
      isDeletedForEveryone: _boolFromJson(json["isDeletedForEveryone"]),
      isEdited: _boolFromJson(json["isEdited"]),
      isVoiceListened: _boolFromJson(json["isVoiceListened"]),
    );
  }

  factory ChatMessage.fromMatrix(mx.Event event) {
    final content = event.content;
    final msgType = content['msgtype']?.toString() ?? event.messageType;
    final attachmentType =
        content['wrytte.sent_as_file'] == true
            ? 'file'
            : _attachmentTypeFromMatrix(msgType);
    final info = content['info'];
    int? duration;
    int? mediaWidth;
    int? mediaHeight;
    if (info is Map && info['duration'] != null) {
      duration = ((info['duration'] as num).toInt() / 1000).round();
    }
    if (info is Map) {
      mediaWidth = int.tryParse(info['w']?.toString() ?? '');
      mediaHeight = int.tryParse(info['h']?.toString() ?? '');
    }

    return ChatMessage(
      id: event.eventId,
      conversationId: event.room.id,
      senderId: event.senderId,
      receiverId: event.room.directChatMatrixID ?? '',
      content:
          event.redacted
              ? _redactedMessageText(event)
              : _stripReplyFallback(_matrixEventBody(event)),
      timestamp: event.originServerTs,
      status: _statusFromMatrix(event.status),
      attachmentUrl: _attachmentUrlFromMatrix(event),
      attachmentType: attachmentType,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      voiceDuration: duration,
      replyToMessageId: event.inReplyToEventId(),
      replyToSenderId: _replySenderFromFallback(event.body),
      replyPreview: _replyPreviewFromFallback(event.body),
      senderPhone: content['wrytte.sender_phone']?.toString(),
      senderName: content['wrytte.sender_name']?.toString(),
      isForwarded: content['wrytte.forwarded'] == true,
      isDeletedForEveryone: event.redacted,
      isEdited: _isMatrixEdit(event),
    );
  }

  static ChatMessage? fromMatrixEvent(mx.Event event) {
    if (event.type != mx.EventTypes.Message) return null;
    if (!event.redacted &&
        _matrixEventBody(event).isEmpty &&
        !event.hasAttachment) {
      return null;
    }
    return ChatMessage.fromMatrix(event);
  }

  static String? matrixEditTargetId(mx.Event event) {
    final relatesTo = event.content['m.relates_to'];
    if (relatesTo is! Map || relatesTo['rel_type'] != 'm.replace') {
      return null;
    }
    return relatesTo['event_id']?.toString();
  }

  // TO JSON (HTTP / Local DB)

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "conversationId": conversationId,
      "senderId": senderId,
      "receiverId": receiverId,
      "content": content,
      "timestamp": timestamp.toUtc().toIso8601String(),
      "status": _statusToString(status),
      if (attachmentUrl != null) "attachmentUrl": attachmentUrl,
      if (attachmentType != null) "attachmentType": attachmentType,
      if (mediaWidth != null) "mediaWidth": mediaWidth,
      if (mediaHeight != null) "mediaHeight": mediaHeight,
      if (voiceDuration != null) "voiceDuration": voiceDuration, // ← NEW
      if (replyToMessageId != null) "replyToMessageId": replyToMessageId,
      if (replyToSenderId != null) "replyToSenderId": replyToSenderId,
      if (replyPreview != null) "replyPreview": replyPreview,
      if (senderPhone != null) "senderPhone": senderPhone,
      if (senderName != null) "senderName": senderName,
      "isForwarded": isForwarded,
      "isStarred": isStarred,
      "isDeletedForMe": isDeletedForMe,
      "isDeletedForEveryone": isDeletedForEveryone,
      "isEdited": isEdited,
      "isVoiceListened": isVoiceListened,
    };
  }

  // COPY WITH

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    String? receiverId,
    String? content,
    DateTime? timestamp,
    MessageStatus? status,
    String? attachmentUrl,
    String? attachmentType,
    int? mediaWidth,
    int? mediaHeight,
    int? voiceDuration, // ← NEW
    String? replyToMessageId,
    String? replyToSenderId,
    String? replyPreview,
    String? senderPhone,
    String? senderName,
    bool? isForwarded,
    bool? isStarred,
    bool? isDeletedForMe,
    bool? isDeletedForEveryone,
    bool? isEdited,
    bool? isVoiceListened,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      attachmentUrl: attachmentUrl ?? this.attachmentUrl,
      attachmentType: attachmentType ?? this.attachmentType,
      mediaWidth: mediaWidth ?? this.mediaWidth,
      mediaHeight: mediaHeight ?? this.mediaHeight,
      voiceDuration: voiceDuration ?? this.voiceDuration, // ← NEW
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToSenderId: replyToSenderId ?? this.replyToSenderId,
      replyPreview: replyPreview ?? this.replyPreview,
      senderPhone: senderPhone ?? this.senderPhone,
      senderName: senderName ?? this.senderName,
      isForwarded: isForwarded ?? this.isForwarded,
      isStarred: isStarred ?? this.isStarred,
      isDeletedForMe: isDeletedForMe ?? this.isDeletedForMe,
      isDeletedForEveryone: isDeletedForEveryone ?? this.isDeletedForEveryone,
      isEdited: isEdited ?? this.isEdited,
      isVoiceListened: isVoiceListened ?? this.isVoiceListened,
    );
  }

  // HELPER METHODS

  bool isMine(String currentUserId) => senderId == currentUserId;

  bool get hasAttachment => attachmentUrl != null;

  bool get isVoiceNote => attachmentType == 'voice'; // ← NEW convenience getter

  bool get isDeleted => isDeletedForMe || isDeletedForEveryone;

  // LOCAL SERIALIZATION

  String toRaw() => jsonEncode(toJson());

  factory ChatMessage.fromRaw(String source) {
    final decoded = jsonDecode(source);
    if (decoded is Map<String, dynamic>) {
      return ChatMessage.fromJson(decoded);
    }
    throw const FormatException("Invalid ChatMessage format");
  }

  @override
  String toString() {
    return "ChatMessage(id: $id, senderId: $senderId, receiverId: $receiverId, "
        "content: $content, status: $status, attachmentType: $attachmentType, "
        "voiceDuration: $voiceDuration)";
  }
}

String _redactedMessageText(mx.Event event) {
  final redactedBy = event.redactedBecause?.senderId.trim() ?? '';
  final originalSender = event.senderId.trim();
  if (redactedBy.isNotEmpty &&
      originalSender.isNotEmpty &&
      redactedBy != originalSender) {
    return 'This message was deleted by admin';
  }
  return 'This message was deleted';
}

String _stripReplyFallback(String body) {
  // Matrix prefixes the fallback of an edited reply with `* `. Strip that
  // marker only for fallback detection; it must never expose the quoted MXID
  // or homeserver in the visible message body.
  final candidate = body.startsWith('* > ') ? body.substring(2) : body;
  final split = candidate.split(RegExp(r'\r?\n\r?\n'));
  if (candidate.startsWith('> ') && split.length > 1) {
    return split.sublist(1).join('\n\n');
  }
  return body;
}

String _matrixEventBody(mx.Event event) {
  final newContent = event.content['m.new_content'];
  if (_isMatrixEdit(event) && newContent is Map) {
    final editedBody = newContent['body']?.toString() ?? '';
    if (editedBody.isNotEmpty) return editedBody;
  }
  return event.body;
}

String? _replyPreviewFromFallback(String body) {
  final candidate = body.startsWith('* > ') ? body.substring(2) : body;
  if (!candidate.startsWith('> ')) return null;
  final firstBlock = candidate.split(RegExp(r'\r?\n\r?\n')).first;
  final lines =
      firstBlock
          .split('\n')
          .map((line) => line.replaceFirst(RegExp(r'^> ?'), '').trim())
          .where((line) => line.isNotEmpty)
          .toList();
  if (lines.isEmpty) return null;
  final text = lines.join(' ').replaceFirst(RegExp(r'^<[^>]+>\s*'), '');
  if (text.trim().isEmpty) return null;
  return text.length > 120 ? '${text.substring(0, 120)}...' : text;
}

String? _replySenderFromFallback(String body) {
  final candidate = body.startsWith('* > ') ? body.substring(2) : body;
  if (!candidate.startsWith('> ')) return null;
  final firstBlock = candidate.split(RegExp(r'\r?\n\r?\n')).first;
  final firstLine = firstBlock
      .split('\n')
      .map((line) => line.replaceFirst(RegExp(r'^> ?'), '').trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  final match = RegExp(r'^<([^>]+)>').firstMatch(firstLine);
  return match?.group(1);
}

bool _isMatrixEdit(mx.Event event) {
  final relatesTo = event.content['m.relates_to'];
  return relatesTo is Map && relatesTo['rel_type'] == 'm.replace';
}

String? _attachmentTypeFromMatrix(String msgType) {
  switch (msgType) {
    case mx.MessageTypes.Audio:
      return 'voice';
    case mx.MessageTypes.Image:
      return 'image';
    case mx.MessageTypes.Video:
      return 'video';
    case mx.MessageTypes.File:
      return 'file';
    default:
      return null;
  }
}

String? _attachmentUrlFromMatrix(mx.Event event) {
  final mxcUrl = event.attachmentMxcUrl;
  if (mxcUrl == null) return null;
  if (!mxcUrl.isScheme('mxc')) return mxcUrl.toString();
  return mxcUrl.getDownloadLink(event.room.client).toString();
}

MessageStatus _statusFromMatrix(mx.EventStatus status) {
  if (status.isSent) return MessageStatus.sent;
  final raw = status.toString().toLowerCase();
  if (raw.contains('error')) return MessageStatus.failed;
  return MessageStatus.sending;
}
