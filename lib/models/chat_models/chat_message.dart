import 'dart:convert';

import 'package:matrix/matrix.dart' as mx;

enum MessageStatus { sending, sent, delivered, read, failed }

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
    this.voiceDuration,   // ← NEW
    this.unreadCount = 0,
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
      voiceDuration: json["voiceDuration"] != null          // ← NEW
          ? int.tryParse(json["voiceDuration"].toString())
          : null,
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
      content: event.body,
      timestamp: event.originServerTs,
      status: _statusFromMatrix(event.status),
      attachmentUrl: event.attachmentMxcUrl?.toString(),
      attachmentType: attachmentType,
      voiceDuration: duration,
    );
  }

  static ChatMessage? fromMatrixEvent(mx.Event event) {
    if (event.type != mx.EventTypes.Message) return null;
    if (event.body.isEmpty && !event.hasAttachment) return null;
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
    int? voiceDuration,   // ← NEW
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
    );
  }

  // HELPER METHODS

  bool isMine(String currentUserId) => senderId == currentUserId;

  bool get hasAttachment => attachmentUrl != null;

  bool get isVoiceNote => attachmentType == 'voice'; // ← NEW convenience getter

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
