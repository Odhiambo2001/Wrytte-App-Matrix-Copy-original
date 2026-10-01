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
  static const bio = 'com.wrytte.bio';
  static const link = 'com.wrytte.link';
  static const channelAlias = 'com.wrytte.channel_alias';
  static const groupAlias = 'com.wrytte.group_alias';
  static const visibility = 'com.wrytte.profile_visibility';

  final String userId;
  final Map<String, dynamic> fields;

  const WrytteProfile({required this.userId, required this.fields});

  String? operator [](String key) => fields[key]?.toString();

  Map<String, String> get visibilitySettings {
    final raw = fields[visibility];
    if (raw is! Map) return const {};
    return raw.map((key, value) => MapEntry(key.toString(), value.toString()));
  }
}
