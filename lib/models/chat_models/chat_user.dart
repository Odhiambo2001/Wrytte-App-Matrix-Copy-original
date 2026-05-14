import 'package:equatable/equatable.dart';
import 'package:matrix/matrix.dart' as mx;

class ChatUser extends Equatable {
  final String id;
  final String username;
  final String? displayName;
  final String? photoUrl;
  final bool isOnline;
  final DateTime? lastSeen;

  const ChatUser({
    required this.id,
    required this.username,
    this.displayName,
    this.photoUrl,
    required this.isOnline,
    this.lastSeen,
  });

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    return ChatUser(
      id: json['id'],
      username: json['username'],
      displayName: json['display_name'],
      photoUrl: json['photo_url'],
      isOnline: json['is_online'] ?? false,
      lastSeen:
          json['last_seen'] != null ? DateTime.parse(json['last_seen']) : null,
    );
  }

  factory ChatUser.fromMatrixProfile(mx.Profile profile) {
    return ChatUser(
      id: profile.userId,
      username: profile.displayName ?? profile.userId,
      displayName: profile.displayName,
      photoUrl: profile.avatarUrl?.toString(),
      isOnline: false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'display_name': displayName,
      'photo_url': photoUrl,
      'is_online': isOnline,
      'last_seen': lastSeen?.toIso8601String(),
    };
  }

  @override
  List<Object?> get props => [
    id,
    username,
    displayName,
    photoUrl,
    isOnline,
    lastSeen,
  ];
}
