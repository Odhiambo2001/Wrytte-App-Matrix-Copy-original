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
    );
  }

  factory ChatMessage.fromMatrix(mx.Event event) {
    final content = event.content;
    final msgType = content['msgtype']?.toString() ?? event.messageType;
    final attachmentType = _attachmentTypeFromMatrix(msgType);
    final info = content['info'];
    int? duration;
    if (info is Map && info['duration'] != null) {
      duration = ((info['duration'] as num).toInt() / 1000).round();
    }

    return ChatMessage(
      id: event.eventId,
      conversationId: event.room.id,
      senderId: event.senderId,
      receiverId: event.room.directChatMatrixID ?? '',
      content:
          event.redacted
              ? 'This message was deleted'
              : _stripReplyFallback(event.body),
      timestamp: event.originServerTs,
      status: _statusFromMatrix(event.status),
      attachmentUrl: event.attachmentMxcUrl?.toString(),
      attachmentType: attachmentType,
      voiceDuration: duration,
      replyToMessageId: event.inReplyToEventId(),
      replyToSenderId: _replySenderFromFallback(event.body),
      replyPreview: _replyPreviewFromFallback(event.body),
      senderPhone: content['wrytte.sender_phone']?.toString(),
      senderName: content['wrytte.sender_name']?.toString(),
      isForwarded: content['wrytte.forwarded'] == true,
      isDeletedForEveryone: event.redacted,
    );
  }

  static ChatMessage? fromMatrixEvent(mx.Event event) {
    if (event.type != mx.EventTypes.Message) return null;
    if (!event.redacted && event.body.isEmpty && !event.hasAttachment) {
      return null;
    }
    return ChatMessage.fromMatrix(event);
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

String _stripReplyFallback(String body) {
  final split = body.split('\n\n');
  if (body.startsWith('> ') && split.length > 1) {
    return split.sublist(1).join('\n\n');
  }
  return body;
}

String? _replyPreviewFromFallback(String body) {
  if (!body.startsWith('> ')) return null;
  final firstBlock = body.split('\n\n').first;
  final lines =
      firstBlock
          .split('\n')
          .map((line) => line.replaceFirst(RegExp(r'^> ?'), '').trim())
          .where((line) => line.isNotEmpty)
          .toList();
  if (lines.isEmpty) return null;
  final text = lines.join(' ');
  return text.length > 120 ? '${text.substring(0, 120)}...' : text;
}

String? _replySenderFromFallback(String body) {
  final preview = _replyPreviewFromFallback(body);
  if (preview == null) return null;
  final match = RegExp(r'^<([^>]+)>').firstMatch(preview);
  return match?.group(1);
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

MessageStatus _statusFromMatrix(mx.EventStatus status) {
  if (status.isSent) return MessageStatus.sent;
  final raw = status.toString().toLowerCase();
  if (raw.contains('error')) return MessageStatus.failed;
  return MessageStatus.sending;
}
