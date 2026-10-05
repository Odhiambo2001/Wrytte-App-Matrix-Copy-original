class Contact {
  final String? displayName;
  final String? firstName;
  final String? lastName;
  final List<String> phones;
  final String? avatarUrl;
  final String? bio;
  final bool isOnWrytte;
  final String? wrytteUserId;
  final String? databaseName;
  final String? directRoomId;
  final String? inviteStatus;
  final bool isRecent;
  final bool isSaved;

  Contact({
    required this.displayName,
    this.firstName,
    this.lastName,
    required this.phones,
    this.avatarUrl,
    this.bio,
    this.isOnWrytte = false,
    this.wrytteUserId,
    this.databaseName,
    this.directRoomId,
    this.inviteStatus,
    this.isRecent = false,
    this.isSaved = false,
  });

  String get formattedName => displayName ?? 'Unknown';
  String get primaryPhone => phones.isNotEmpty ? phones.first : '';

  // for easier updates
  Contact copyWith({
    String? displayName,
    String? firstName,
    String? lastName,
    List<String>? phones,
    String? avatarUrl,
    String? bio,
    bool? isOnWrytte,
    String? wrytteUserId,
    String? databaseName,
    String? directRoomId,
    String? inviteStatus,
    bool? isRecent,
    bool? isSaved,
  }) {
    return Contact(
      displayName: displayName ?? this.displayName,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      phones: phones ?? this.phones,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
      isOnWrytte: isOnWrytte ?? this.isOnWrytte,
      wrytteUserId: wrytteUserId ?? this.wrytteUserId,
      databaseName: databaseName ?? this.databaseName,
      directRoomId: directRoomId ?? this.directRoomId,
      inviteStatus: inviteStatus ?? this.inviteStatus,
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
      // Canonical account-data fields consumed by Matrix contact readers.
      'userId': wrytteUserId,
      'roomId': directRoomId,
      'number': primaryPhone,
      'displayName': displayName,
      'firstName': firstName,
      'lastName': lastName,
      'phones': phones,
      'avatarUrl': avatarUrl,
      'bio': bio,
      'isOnWrytte': isOnWrytte,
      'wrytteUserId': wrytteUserId,
      'databaseName': databaseName,
      'directRoomId': directRoomId,
      'inviteStatus': inviteStatus,
      'isRecent': isRecent,
      'isSaved': isSaved,
    };
  }

  // Factory method to create from Map
  factory Contact.fromMap(Map<String, dynamic> map) {
    return Contact(
      displayName: map['displayName'],
      firstName: map['firstName'],
      lastName: map['lastName'],
      phones: List<String>.from(
        map['phones'] ??
            (map['number'] == null || map['number'].toString().isEmpty
                ? const <String>[]
                : <String>[map['number'].toString()]),
      ),
      avatarUrl: map['avatarUrl'],
      bio: map['bio'],
      isOnWrytte: map['isOnWrytte'] ?? false,
      wrytteUserId: map['wrytteUserId'] ?? map['userId'],
      databaseName: map['databaseName'],
      directRoomId: map['directRoomId'] ?? map['roomId'],
      inviteStatus: map['inviteStatus'],
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
