class ProfileScreenData {
  const ProfileScreenData({
    required this.name,
    required this.identifier,
    required this.avatarAsset,
    required this.isOwnProfile,
    this.bio = '',
  });

  const ProfileScreenData.own()
    : name = 'You',
      identifier = '+250 791 568 677',
      avatarAsset = 'assets/images/default_avatar.jpg',
      isOwnProfile = true,
      bio = 'Available on Wrytte';

  const ProfileScreenData.wrytteTeam()
    : name = 'Wrytte Team',
      identifier = '+250 791 568 677',
      avatarAsset = 'assets/images/default_avatar.jpg',
      isOwnProfile = false,
      bio = 'Private calls, messaging, and communication.';

  final String name;
  final String identifier;
  final String avatarAsset;
  final bool isOwnProfile;
  final String bio;
}
