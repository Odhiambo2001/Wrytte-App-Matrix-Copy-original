import 'chat_message.dart';
import 'package:matrix/matrix.dart' as mx;

String _userKey(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('@') && trimmed.contains(':')) {
    return trimmed.substring(1, trimmed.indexOf(':'));
  }
  return trimmed;
}

bool _sameUser(String a, String b) => _userKey(a) == _userKey(b);

bool _validMatrixUserId(String? value) {
  final trimmed = value?.trim() ?? '';
  if (!trimmed.startsWith('@')) return false;
  if (trimmed.startsWith('@!')) return false;
  return trimmed.split(':').length == 2 && trimmed.split(':').last.isNotEmpty;
}

/// Product identity for tab placement and UI treatment.
///
/// Matrix room IDs are transport identity: both DMs and groups use `!room:host`.
/// This field is the app-level identity that keeps Chats and Groups separate.
abstract class ConversationKind {
  static const String direct = 'direct';
  static const String group = 'group';
  static const String channel = 'channel';
  static const String unknown = '';

  static String normalize(String? value) {
    switch (value?.trim().toLowerCase()) {
      case direct:
        return direct;
      case group:
        return group;
      case channel:
        return channel;
      default:
        return unknown;
    }
  }
}

class ChatConversation {
  final String id;
  final List<String> participants;
  final String otherUserId;
  final String lastMessage;
  final String lastMessageSenderId;
  final DateTime lastMessageTime;
  final int unreadCount;
  final String lastMessageType;
  final bool isArchived;
  final bool isMuted;
  final bool isPinned;
  final DateTime? mutedUntil;
  final Map<String, DateTime> lastSeen;
  final DateTime? createdAt;
  final DateTime? deletedAt;
  final List<String> deletedBy;

  // ── SQLite cache fields — populated from contacts/profile data ─────────────
  // Stored locally so the UI never waits for a network call to show names/avatars
  final String? otherUserName;
  final String? otherUserAvatar;

  /// Authoritative persisted conversation type.
  final String conversationKind;

  String get conversationId => id;

  bool get hasExplicitKind => conversationKind != ConversationKind.unknown;
  bool get isGroupKind => conversationKind == ConversationKind.group;
  bool get isDirectKind => conversationKind == ConversationKind.direct;
  bool get isChannelKind => conversationKind == ConversationKind.channel;

  const ChatConversation({
    required this.id,
    required this.participants,
    required this.otherUserId,
    required this.lastMessage,
    required this.lastMessageSenderId,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.lastMessageType = 'text',
    this.isArchived = false,
    this.isMuted = false,
    this.isPinned = false,
    this.mutedUntil,
    this.lastSeen = const {},
    this.createdAt,
    this.deletedAt,
    this.deletedBy = const [],
    this.otherUserName,
    this.otherUserAvatar,
    this.conversationKind = ConversationKind.unknown,
  });

  // ── Factory: from a single ChatMessage ────────────────────────────────────

  factory ChatConversation.fromMessage(
    ChatMessage message,
    String currentUserId,
  ) {
    final isFromMe = _sameUser(message.senderId, currentUserId);
    final otherId = isFromMe ? message.receiverId : message.senderId;

    return ChatConversation(
      id: message.conversationId,
      participants: [message.senderId, message.receiverId],
      otherUserId: otherId,
      lastMessage: message.isVoiceNote ? 'Voice message' : message.content,
      lastMessageSenderId: message.senderId,
      lastMessageTime: message.timestamp,
      unreadCount: isFromMe ? 0 : 1,
      lastMessageType: message.attachmentType ?? 'text',
      conversationKind: ConversationKind.direct,
    );
  }

  factory ChatConversation.fromMatrixRoom(
    mx.Room room,
    String currentUserId, {
    String conversationKind = ConversationKind.unknown,
  }) {
    final kind = ConversationKind.normalize(conversationKind);
    if (kind == ConversationKind.group || kind == ConversationKind.channel) {
      final last = room.lastEvent;
      return ChatConversation(
        id: room.id,
        participants: [currentUserId],
        otherUserId: room.id,
        lastMessage:
            last?.messageType == mx.MessageTypes.Audio
                ? 'Voice message'
                : last?.body ?? '',
        lastMessageSenderId: last?.senderId ?? '',
        lastMessageTime: last?.originServerTs ?? DateTime.now(),
        unreadCount:
            last != null && !_sameUser(last.senderId, currentUserId) ? 1 : 0,
        otherUserName: room.getLocalizedDisplayname(),
        otherUserAvatar: room.avatar?.toString(),
        conversationKind: kind,
      );
    }
    final last = room.lastEvent;
    final directUserId = room.directChatMatrixID;
    final otherId =
        _validMatrixUserId(directUserId) &&
                !_sameUser(directUserId!, currentUserId)
            ? directUserId
            : last != null &&
                _validMatrixUserId(last.senderId) &&
                !_sameUser(last.senderId, currentUserId)
            ? last.senderId
            : room.id;
    return ChatConversation(
      id: room.id,
      participants: [currentUserId, otherId],
      otherUserId: otherId,
      lastMessage:
          last?.messageType == mx.MessageTypes.Audio
              ? 'Voice message'
              : last?.body ?? '',
      lastMessageSenderId: last?.senderId ?? '',
      lastMessageTime: last?.originServerTs ?? DateTime.now(),
      unreadCount:
          last != null && !_sameUser(last.senderId, currentUserId) ? 1 : 0,
      lastMessageType:
          last?.messageType == mx.MessageTypes.Audio ? 'voice' : 'text',
      otherUserName: room.getLocalizedDisplayname(),
      otherUserAvatar: room.avatar?.toString(),
      conversationKind: kind,
    );
  }

  // ── Factory: from legacy map data ─────────────────────────────────────────

  factory ChatConversation.fromLegacyMap(
    String docId,
    Map<String, dynamic> data,
    String currentUserId,
  ) {
    final participants = List<String>.from(data['participants'] ?? []);
    final otherId = participants.firstWhere(
      (p) => p != currentUserId,
      orElse: () => '',
    );

    DateTime lastMsgTime = DateTime.now();
    final rawLmt = data['lastMessageTime'];
    if (rawLmt != null) {
      try {
        lastMsgTime = (rawLmt as dynamic).toDate() as DateTime;
      } catch (_) {
        if (rawLmt is DateTime) lastMsgTime = rawLmt;
      }
    }

    final unreadMap = Map<String, dynamic>.from(data['unreadCount'] ?? {});
    final unread = (unreadMap[currentUserId] as num?)?.toInt() ?? 0;

    final rawLastSeen = Map<String, dynamic>.from(data['lastSeen'] ?? {});
    final lastSeen = <String, DateTime>{};
    rawLastSeen.forEach((uid, val) {
      try {
        lastSeen[uid] = (val as dynamic).toDate() as DateTime;
      } catch (_) {
        if (val is DateTime) lastSeen[uid] = val;
      }
    });

    DateTime? toDateTime(dynamic val) {
      if (val == null) return null;
      try {
        return (val as dynamic).toDate() as DateTime;
      } catch (_) {
        return val is DateTime ? val : null;
      }
    }

    final storedType = data['lastMessageType']?.toString() ?? 'text';
    var kind = ConversationKind.normalize(data['conversationKind']?.toString());
    if (kind == ConversationKind.unknown) {
      final legacyGroup =
          (storedType == 'group' || storedType == 'group_deleted') &&
          docId.startsWith('!');
      if (legacyGroup) kind = ConversationKind.group;
    }

    return ChatConversation(
      id: docId,
      participants: participants,
      otherUserId:
          kind == ConversationKind.group || kind == ConversationKind.channel
              ? docId
              : otherId,
      lastMessage: data['lastMessage']?.toString() ?? '',
      lastMessageSenderId: data['lastMessageSender']?.toString() ?? '',
      lastMessageTime: lastMsgTime,
      unreadCount: unread,
      lastMessageType: storedType,
      conversationKind: kind,
      isArchived: data['isArchived'] as bool? ?? false,
      isMuted: data['isMuted'] as bool? ?? false,
      isPinned: data['isPinned'] as bool? ?? false,
      mutedUntil: toDateTime(data['mutedUntil']),
      lastSeen: lastSeen,
      createdAt: toDateTime(data['createdAt']),
      deletedAt: toDateTime(data['deletedAt']),
      deletedBy: List<String>.from(data['deletedBy'] ?? []),
      // otherUserName / otherUserAvatar come from SQLite.
    );
  }

  // ── Update with a new message ─────────────────────────────────────────────

  ChatConversation updateWithMessage(
    ChatMessage message,
    String currentUserId,
  ) {
    final isNewer = message.timestamp.isAfter(lastMessageTime);
    final isFromMe = _sameUser(message.senderId, currentUserId);
    final preserveMarker =
        isGroupKind ||
        isChannelKind ||
        lastMessageType == 'group' ||
        lastMessageType == 'group_deleted';
    return ChatConversation(
      id: id,
      participants: participants,
      otherUserId: otherUserId,
      lastMessage:
          isNewer
              ? (message.isVoiceNote ? 'Voice message' : message.content)
              : lastMessage,
      lastMessageSenderId: isNewer ? message.senderId : lastMessageSenderId,
      lastMessageTime: isNewer ? message.timestamp : lastMessageTime,
      unreadCount: unreadCount + (isFromMe ? 0 : 1),
      lastMessageType:
          preserveMarker
              ? lastMessageType
              : (isNewer ? message.attachmentType ?? 'text' : lastMessageType),
      conversationKind: conversationKind,
      isArchived: isArchived,
      isMuted: isMuted,
      isPinned: isPinned,
      mutedUntil: mutedUntil,
      lastSeen: lastSeen,
      createdAt: createdAt,
      deletedAt: deletedAt,
      deletedBy: deletedBy,
      otherUserName: otherUserName,
      otherUserAvatar: otherUserAvatar,
    );
  }

  // ── copyWith ──────────────────────────────────────────────────────────────

  ChatConversation copyWith({
    String? id,
    List<String>? participants,
    String? otherUserId,
    String? lastMessage,
    String? lastMessageSenderId,
    DateTime? lastMessageTime,
    int? unreadCount,
    String? lastMessageType,
    bool? isArchived,
    bool? isMuted,
    bool? isPinned,
    DateTime? mutedUntil,
    Map<String, DateTime>? lastSeen,
    DateTime? createdAt,
    DateTime? deletedAt,
    List<String>? deletedBy,
    String? otherUserName,
    String? otherUserAvatar,
    String? conversationKind,
  }) {
    final requestedKind = ConversationKind.normalize(conversationKind);
    final resolvedKind =
        requestedKind == ConversationKind.unknown
            ? this.conversationKind
            : requestedKind;
    return ChatConversation(
      id: id ?? this.id,
      participants: participants ?? this.participants,
      otherUserId: otherUserId ?? this.otherUserId,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageSenderId: lastMessageSenderId ?? this.lastMessageSenderId,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      lastMessageType: lastMessageType ?? this.lastMessageType,
      isArchived: isArchived ?? this.isArchived,
      isMuted: isMuted ?? this.isMuted,
      isPinned: isPinned ?? this.isPinned,
      mutedUntil: mutedUntil ?? this.mutedUntil,
      lastSeen: lastSeen ?? this.lastSeen,
      createdAt: createdAt ?? this.createdAt,
      deletedAt: deletedAt ?? this.deletedAt,
      deletedBy: deletedBy ?? this.deletedBy,
      otherUserName: otherUserName ?? this.otherUserName,
      otherUserAvatar: otherUserAvatar ?? this.otherUserAvatar,
      conversationKind: resolvedKind,
    );
  }

  @override
  String toString() =>
      'ChatConversation(id: $id, kind: $conversationKind, '
      'other: $otherUserId, last: "$lastMessage", unread: $unreadCount)';
}
