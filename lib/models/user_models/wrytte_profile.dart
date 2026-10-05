enum WrytteProfileVisibility { everyone, contacts, approvedUsers, nobody }

extension WrytteProfileVisibilityWire on WrytteProfileVisibility {
  String get value => switch (this) {
        WrytteProfileVisibility.everyone => 'everyone',
        WrytteProfileVisibility.contacts => 'contacts',
        WrytteProfileVisibility.approvedUsers => 'approved_users',
        WrytteProfileVisibility.nobody => 'nobody',
      };
}

class WrytteProfile {
  static const firstName = 'com.wrytte.first_name';
  static const lastName = 'com.wrytte.last_name';
  static const phoneNumber = 'com.wrytte.phone_number';
  static const avatarImageUrl = 'com.wrytte.avatar_image_url';
  static const avatarVersion = 'com.wrytte.avatar_version';
  static const bio = 'com.wrytte.bio';
  static const link = 'com.wrytte.link';
  static const channelAlias = 'com.wrytte.channel_alias';
  static const groupAlias = 'com.wrytte.group_alias';
  static const visibility = 'com.wrytte.profile_visibility';
  static const onlineStatus = 'com.wrytte.online_status';

  final String userId;
  final Map<String, dynamic> fields;

  const WrytteProfile({required this.userId, required this.fields});

  String? operator [](String key) => fields[key]?.toString();

  String? get avatarUrl => fields[avatarImageUrl]?.toString();
  String? get displayName => fields['displayname']?.toString();
  String? get presence => fields['presence']?.toString();
  String? get firstNameValue => this[firstNameKey];
  String? get lastNameValue => this[lastNameKey];
  String? get phoneNumberValue => this[phoneNumber];
  String? get bioValue => this[bio];
  String? get linkValue => this[link];
  String? get channelAliasValue => this[channelAlias];
  String? get groupAliasValue => this[groupAlias];

  static const firstNameKey = firstName;
  static const lastNameKey = lastName;

  Map<String, String> get visibilitySettings {
    final raw = fields[visibility];
    if (raw is! Map) return const {};
    return raw.map((key, value) => MapEntry(key.toString(), value.toString()));
  }
}
