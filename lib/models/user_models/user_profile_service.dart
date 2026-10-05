import 'package:wrytte/utils/wrytte_id.dart';

class UserProfile {
  final String uid;
  final String name;
  final String username;
  final String phone;
  final String bio;
  final String profileImage;
  final String onlineStatus;
  final String channelAlias;
  final String groupAlias;
  final Map<String, String> visibilitySettings;
  final int avatarVersion;
  final bool moduleProfileLoaded;
  final String localProfileImagePath;
  final List<String> links;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const UserProfile({
    required this.uid,
    required this.name,
    required this.username,
    required this.phone,
    required this.bio,
    required this.profileImage,
    this.onlineStatus = '',
    this.channelAlias = '',
    this.groupAlias = '',
    this.visibilitySettings = const {},
    this.avatarVersion = 0,
    this.moduleProfileLoaded = false,
    this.localProfileImagePath = '',
    required this.links,
    this.createdAt,
    this.updatedAt,
  });

  factory UserProfile.fromMap(String uid, Map<String, dynamic> data) {
    return UserProfile(
      uid: uid,
      name: data['name'] as String? ?? '',
      username: data['username'] as String? ?? '',
      phone: data['phone'] as String? ?? '',
      bio: data['bio'] as String? ?? '',
      profileImage: data['profileImage'] as String? ?? '',
      onlineStatus: data['onlineStatus'] as String? ?? '',
      channelAlias: data['channelAlias'] as String? ?? '',
      groupAlias: data['groupAlias'] as String? ?? '',
      visibilitySettings: Map<String, String>.from(
        (data['visibilitySettings'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ) ??
            const {},
      ),
      avatarVersion: int.tryParse(data['avatarVersion']?.toString() ?? '') ?? 0,
      moduleProfileLoaded: data['moduleProfileLoaded'] as bool? ?? false,
      localProfileImagePath: data['localProfileImagePath'] as String? ?? '',
      links: List<String>.from(data['links'] as List? ?? []),
      createdAt: (data['createdAt'] as dynamic)?.toDate() as DateTime?,
      updatedAt: (data['updatedAt'] as dynamic)?.toDate() as DateTime?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'username': username,
      'phone': phone,
      'bio': bio,
      'profileImage': profileImage,
      'onlineStatus': onlineStatus,
      'channelAlias': channelAlias,
      'groupAlias': groupAlias,
      'visibilitySettings': visibilitySettings,
      'avatarVersion': avatarVersion,
      'moduleProfileLoaded': moduleProfileLoaded,
      'localProfileImagePath': localProfileImagePath,
      'links': links,
    };
  }

  /// Returns true if the string looks like a phone number
  bool _looksLikePhone(String value) {
    final stripped = value.replaceAll(RegExp(r'[\s\-()]'), '');
    return stripped.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(stripped);
  }

  /// Display name falls back gracefully: name → username → phone
  String get displayName {
    if (name.isNotEmpty && !_looksLikePhone(name)) {
      return WrytteId.forDisplay(name) ?? name;
    }
    if (username.isNotEmpty && !_looksLikePhone(username)) {
      return WrytteId.forDisplay(username) ?? username;
    }
    return WrytteId.forDisplay(phone) ?? phone;
  }

  /// True only if profileImage is a non-empty valid URL
  bool get hasProfileImage =>
      profileImage.isNotEmpty &&
      (profileImage.startsWith('http') || profileImage.startsWith('mxc://'));

  bool get isOnline => onlineStatus.toLowerCase() == 'online';

  UserProfile copyWith({
    String? name,
    String? username,
    String? phone,
    String? bio,
    String? profileImage,
    String? onlineStatus,
    String? channelAlias,
    String? groupAlias,
    Map<String, String>? visibilitySettings,
    int? avatarVersion,
    bool? moduleProfileLoaded,
    String? localProfileImagePath,
    List<String>? links,
  }) {
    return UserProfile(
      uid: uid,
      name: name ?? this.name,
      username: username ?? this.username,
      phone: phone ?? this.phone,
      bio: bio ?? this.bio,
      profileImage: profileImage ?? this.profileImage,
      onlineStatus: onlineStatus ?? this.onlineStatus,
      channelAlias: channelAlias ?? this.channelAlias,
      groupAlias: groupAlias ?? this.groupAlias,
      visibilitySettings: visibilitySettings ?? this.visibilitySettings,
      avatarVersion: avatarVersion ?? this.avatarVersion,
      moduleProfileLoaded: moduleProfileLoaded ?? this.moduleProfileLoaded,
      localProfileImagePath:
          localProfileImagePath ?? this.localProfileImagePath,
      links: links ?? this.links,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
