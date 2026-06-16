import 'package:wrytte/models/contact_model.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';

/// The account owner's own profile. This is the signed-in user's account data.
typedef OwnerUserProfile = UserProfile;

/// Public contact profile for someone who has not been saved as a contact.
///
/// The backend does not know this as "profile 1"; it only returns a user
/// profile for a user ID. The FE treats that returned profile as
/// ContactUserProfile1 when the person is not saved.
class ContactUserProfile1 {
  final String userId;
  final String displayName;
  final String phone;
  final String? avatarUrl;
  final String? bio;

  const ContactUserProfile1({
    required this.userId,
    required this.displayName,
    required this.phone,
    this.avatarUrl,
    this.bio,
  });

  factory ContactUserProfile1.fromBackendProfile(
    String userId,
    UserProfile profile, {
    String fallbackPhone = '',
  }) {
    final avatar = profile.hasProfileImage ? profile.profileImage.trim() : '';
    final bio = profile.bio.trim();
    return ContactUserProfile1(
      userId: userId,
      displayName: profile.displayName.trim(),
      phone:
          profile.phone.trim().isNotEmpty
              ? profile.phone.trim()
              : fallbackPhone.trim(),
      avatarUrl: avatar.isEmpty ? null : avatar,
      bio: bio.isEmpty ? null : bio,
    );
  }
}

/// Saved contact profile created by the FE after the user taps save.
///
/// This is the app's ContactUserProfile2. It keeps the user's saved name, but
/// copies phone, avatar, and bio from ContactUserProfile1 when available.
class ContactUserProfile2 {
  final String displayName;
  final List<String> phones;
  final String? avatarUrl;
  final String? bio;
  final bool isOnWrytte;
  final String? wrytteUserId;
  final String? databaseName;
  final bool isRecent;
  final bool isSaved;

  const ContactUserProfile2({
    required this.displayName,
    required this.phones,
    this.avatarUrl,
    this.bio,
    required this.isOnWrytte,
    this.wrytteUserId,
    this.databaseName,
    this.isRecent = false,
    this.isSaved = true,
  });

  factory ContactUserProfile2.fromSavedContact({
    required String savedDisplayName,
    required String typedPhone,
    required bool isOnWrytte,
    String? wrytteUserId,
    ContactUserProfile1? contactUserProfile1,
  }) {
    final phoneFromProfile1 = contactUserProfile1?.phone.trim() ?? '';
    return ContactUserProfile2(
      displayName: savedDisplayName,
      phones: [phoneFromProfile1.isNotEmpty ? phoneFromProfile1 : typedPhone],
      avatarUrl: contactUserProfile1?.avatarUrl,
      bio: contactUserProfile1?.bio,
      isOnWrytte: isOnWrytte,
      wrytteUserId: wrytteUserId?.trim().isEmpty == true ? null : wrytteUserId,
      isSaved: true,
    );
  }

  Contact toContact() {
    return Contact(
      displayName: displayName,
      phones: phones,
      avatarUrl: avatarUrl,
      bio: bio,
      isOnWrytte: isOnWrytte,
      wrytteUserId: wrytteUserId,
      databaseName: databaseName,
      isRecent: isRecent,
      isSaved: isSaved,
    );
  }
}
