class Contact {
  final String? displayName;
  final List<String> phones;
  final String? avatarUrl;
  final String? bio;
  final bool isOnWrytte;
  final String? wrytteUserId;
  final String? databaseName;
  final bool isRecent;
  final bool isSaved;

  Contact({
    required this.displayName,
    required this.phones,
    this.avatarUrl,
    this.bio,
    this.isOnWrytte = false,
    this.wrytteUserId,
    this.databaseName,
    this.isRecent = false,
    this.isSaved = false,
  });

  String get formattedName => displayName ?? 'Unknown';
  String get primaryPhone => phones.isNotEmpty ? phones.first : '';

  // for easier updates
  Contact copyWith({
    String? displayName,
    List<String>? phones,
    String? avatarUrl,
    String? bio,
    bool? isOnWrytte,
    String? wrytteUserId,
    String? databaseName,
    bool? isRecent,
    bool? isSaved,
  }) {
    return Contact(
      displayName: displayName ?? this.displayName,
      phones: phones ?? this.phones,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
      isOnWrytte: isOnWrytte ?? this.isOnWrytte,
      wrytteUserId: wrytteUserId ?? this.wrytteUserId,
      databaseName: databaseName ?? this.databaseName,
      isRecent: isRecent ?? this.isRecent,
      isSaved: isSaved ?? this.isSaved,
    );
  }

  // Factory method to create a Contact with isRecent flag
  Contact withRecent(bool recent) {
    return copyWith(isRecent: recent);
  }

  // Convert to Map
  Map<String, dynamic> toMap() {
    return {
      'displayName': displayName,
      'phones': phones,
      'avatarUrl': avatarUrl,
      'bio': bio,
      'isOnWrytte': isOnWrytte,
      'wrytteUserId': wrytteUserId,
      'databaseName': databaseName,
      'isRecent': isRecent,
      'isSaved': isSaved,
    };
  }

  // Factory method to create from Map
  factory Contact.fromMap(Map<String, dynamic> map) {
    return Contact(
      displayName: map['displayName'],
      phones: List<String>.from(map['phones'] ?? []),
      avatarUrl: map['avatarUrl'],
      bio: map['bio'],
      isOnWrytte: map['isOnWrytte'] ?? false,
      wrytteUserId: map['wrytteUserId'],
      databaseName: map['databaseName'],
      isRecent: map['isRecent'] ?? false,
      isSaved: map['isSaved'] ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Contact &&
          runtimeType == other.runtimeType &&
          displayName == other.displayName &&
          primaryPhone == other.primaryPhone;

  @override
  int get hashCode => displayName.hashCode ^ primaryPhone.hashCode;
}
