import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Get current user data
  Future<Map<String, dynamic>> getCurrentUserData() async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) throw Exception('No user logged in');

      final userDoc = await _firestore.collection('users').doc(uid).get();

      if (!userDoc.exists) {
        throw Exception('User document not found');
      }

      return userDoc.data()!;
    } catch (e) {
      // ignore: avoid_print
      print('Error getting current user data: $e');
      rethrow;
    }
  }

  // Get user data by ID
  Future<Map<String, dynamic>> getUserData(String userId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();

      if (!userDoc.exists) {
        return {
          'name': 'Unknown User',
          'profileImage': null,
          'isOnline': false,
          'phone': '',
          'lastSeen': null,
        };
      }

      return userDoc.data()!;
    } catch (e) {
      // ignore: avoid_print
      print('Error getting user data: $e');
      return {
        'name': 'Unknown User',
        'profileImage': null,
        'isOnline': false,
        'phone': '',
        'lastSeen': null,
      };
    }
  }

  // Get multiple users data by IDs (batch request)
  Future<List<Map<String, dynamic>>> getUsersData(List<String> userIds) async {
    try {
      if (userIds.isEmpty) return [];

      // Remove duplicates and split into chunks of 10 (Firestore limit)
      final uniqueIds = userIds.toSet().toList();
      final chunks = _splitIntoChunks(uniqueIds, 10);

      List<Map<String, dynamic>> allUsers = [];

      for (final chunk in chunks) {
        final usersSnapshot =
            await _firestore
                .collection('users')
                .where(FieldPath.documentId, whereIn: chunk)
                .get();

        for (final doc in usersSnapshot.docs) {
          allUsers.add({'id': doc.id, ...doc.data()});
        }
      }

      return allUsers;
    } catch (e) {
      // ignore: avoid_print
      print('Error getting multiple users data: $e');
      return [];
    }
  }

  // Update user profile
  Future<void> updateUserProfile({
    String? name,
    String? profileImage,
    String? status,
    String? about,
  }) async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) throw Exception('No user logged in');

      final updateData = <String, dynamic>{};

      if (name != null) updateData['name'] = name;
      if (profileImage != null) updateData['profileImage'] = profileImage;
      if (status != null) updateData['status'] = status;
      if (about != null) updateData['about'] = about;

      updateData['updatedAt'] = FieldValue.serverTimestamp();

      await _firestore.collection('users').doc(uid).update(updateData);

      try {
        await MatrixAuthService.instance.restore();
        final client = MatrixClientService.instance.client;
        final matrixUserId = client.userID;
        if (matrixUserId != null) {

          if (name != null) {await client.setProfileField(matrixUserId,'m.displayname',{'displayname': name},);
        }
        if (profileImage != null && profileImage.isNotEmpty) {await client.setProfileField(matrixUserId,'m.avatar_url', {'avatar_url': profileImage},);
        }   
        }
      } catch (e) {
        print('Matrix profile update skipped: $e');
      }

      // ignore: avoid_print
      print('User profile updated successfully');
    } catch (e) {
      // ignore: avoid_print
      print('Error updating user profile: $e');
      rethrow;
    }
  }

  // Set user online status
  Future<void> setUserOnlineStatus(bool isOnline) async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) return;

      final updateData = {
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      };

      if (!isOnline) {
        updateData['lastSeen'] = FieldValue.serverTimestamp();
      }

      await _firestore.collection('users').doc(uid).update(updateData);

      print('User online status updated: $isOnline');
    } catch (e) {
      print('Error setting online status: $e');
      // Don't rethrow - this shouldn't break the app
    }
  }

  // Search users by phone number (for contact matching)
  Future<List<Map<String, dynamic>>> searchUsersByPhone(
    String phoneNumber,
  ) async {
    try {
      final normalizedPhone = _normalizePhoneNumber(phoneNumber);

      final usersSnapshot =
          await _firestore
              .collection('users')
              .where('phone', isEqualTo: normalizedPhone)
              .limit(10)
              .get();

      return usersSnapshot.docs.map((doc) {
        return {'id': doc.id, ...doc.data()};
      }).toList();
    } catch (e) {
      print('Error searching users by phone: $e');
      return [];
    }
  }

  // Search users by name
  Future<List<Map<String, dynamic>>> searchUsersByName(String query) async {
    try {
      //  Only search if query is meaningful
      if (query.trim().length < 2) return [];

      final lowerQuery = query.toLowerCase();
      final usersSnapshot = await _firestore
          .collection('users')
          .orderBy('name')
          .startAt([lowerQuery])
          .endAt(['$lowerQuery\uf8ff'])
          .limit(20)
          .get();

      return usersSnapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
    } catch (e) {
      print('Error searching users by name: $e');
      return [];
    }
  }

  // Get user stream for real-time updates
  Stream<DocumentSnapshot> getUserStream(String userId) {
    return _firestore.collection('users').doc(userId).snapshots();
  }

  // Get current user stream
  Stream<DocumentSnapshot> getCurrentUserStream() async* {
    final uid = await AuthService.instance.getCurrentUserId() ?? '';
    if (uid.isEmpty) return;
    yield* _firestore.collection('users').doc(uid).snapshots();
  }

  // Check if user exists by phone number
  Future<bool> userExistsByPhone(String phoneNumber) async {
    try {
      final normalizedPhone = _normalizePhoneNumber(phoneNumber);

      final userSnapshot =
          await _firestore
              .collection('users')
              .where('phone', isEqualTo: normalizedPhone)
              .limit(1)
              .get();

      return userSnapshot.docs.isNotEmpty;
    } catch (e) {
      print('Error checking if user exists: $e');
      return false;
    }
  }

  // Get user ID by phone number
  Future<String?> getUserIdByPhone(String phoneNumber) async {
    try {
      final normalizedPhone = _normalizePhoneNumber(phoneNumber);

      final userSnapshot =
          await _firestore
              .collection('users')
              .where('phone', isEqualTo: normalizedPhone)
              .limit(1)
              .get();

      if (userSnapshot.docs.isNotEmpty) {
        return userSnapshot.docs.first.id;
      }

      return null;
    } catch (e) {
      print('Error getting user ID by phone: $e');
      return null;
    }
  }

  // Update user's FCM token for push notifications
  Future<void> updateFcmToken(String fcmToken) async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) return;

      await _firestore.collection('users').doc(uid).update({
        'fcmToken': fcmToken,
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      });

      print('FCM token updated successfully');
    } catch (e) {
      print('Error updating FCM token: $e');
    }
  }

  // Remove FCM token (on logout)
  Future<void> removeFcmToken() async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) return;

      await _firestore.collection('users').doc(uid).update({
        'fcmToken': FieldValue.delete(),
        'fcmTokenUpdatedAt': FieldValue.delete(),
      });

      print('FCM token removed successfully');
    } catch (e) {
      print('Error removing FCM token: $e');
    }
  }

  // Get user's privacy settings
  Future<Map<String, dynamic>> getPrivacySettings() async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) throw Exception('No user logged in');

      final userDoc = await _firestore.collection('users').doc(uid).get();

      final data = userDoc.data() ?? {};

      return {
        'lastSeen': data['privacy_lastSeen'] ?? 'everyone',
        'profilePhoto': data['privacy_profilePhoto'] ?? 'everyone',
        'status': data['privacy_status'] ?? 'everyone',
        'readReceipts': data['privacy_readReceipts'] ?? true,
      };
    } catch (e) {
      print('Error getting privacy settings: $e');
      return {
        'lastSeen': 'everyone',
        'profilePhoto': 'everyone',
        'status': 'everyone',
        'readReceipts': true,
      };
    }
  }

  // Update privacy settings
  Future<void> updatePrivacySettings({
    String? lastSeen,
    String? profilePhoto,
    String? status,
    bool? readReceipts,
  }) async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) throw Exception('No user logged in');

      final updateData = <String, dynamic>{};

      if (lastSeen != null) updateData['privacy_lastSeen'] = lastSeen;
      if (profilePhoto != null)
        updateData['privacy_profilePhoto'] = profilePhoto;
      if (status != null) updateData['privacy_status'] = status;
      if (readReceipts != null)
        updateData['privacy_readReceipts'] = readReceipts;

      updateData['privacyUpdatedAt'] = FieldValue.serverTimestamp();

      await _firestore.collection('users').doc(uid).update(updateData);

      print('Privacy settings updated successfully');
    } catch (e) {
      print('Error updating privacy settings: $e');
      rethrow;
    }
  }

  // Block a user
  Future<void> blockUser(String blockedUserId) async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) return;

      await _firestore.collection('users').doc(uid).update({
        'blockedUsers': FieldValue.arrayUnion([blockedUserId]),
        'blockedUsersUpdatedAt': FieldValue.serverTimestamp(),
      });

      print('User blocked successfully: $blockedUserId');
    } catch (e) {
      print('Error blocking user: $e');
      rethrow;
    }
  }

  // Unblock a user
  Future<void> unblockUser(String blockedUserId) async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) return;

      await _firestore.collection('users').doc(uid).update({
        'blockedUsers': FieldValue.arrayRemove([blockedUserId]),
      });

      print('User unblocked successfully: $blockedUserId');
    } catch (e) {
      print('Error unblocking user: $e');
      rethrow;
    }
  }

  // Get blocked users list
  Future<List<String>> getBlockedUsers() async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) return [];

      final userDoc = await _firestore.collection('users').doc(uid).get();

      final data = userDoc.data() ?? {};
      final blockedUsers = data['blockedUsers'] as List<dynamic>?;

      return blockedUsers?.cast<String>() ?? [];
    } catch (e) {
      print('Error getting blocked users: $e');
      return [];
    }
  }

  // Check if user is blocked
  Future<bool> isUserBlocked(String userId) async {
    try {
      final blockedUsers = await getBlockedUsers();
      return blockedUsers.contains(userId);
    } catch (e) {
      print('Error checking if user is blocked: $e');
      return false;
    }
  }

  // Helper method to split list into chunks
  List<List<T>> _splitIntoChunks<T>(List<T> list, int chunkSize) {
    List<List<T>> chunks = [];
    for (int i = 0; i < list.length; i += chunkSize) {
      int end = (i + chunkSize < list.length) ? i + chunkSize : list.length;
      chunks.add(list.sublist(i, end));
    }
    return chunks;
  }

  // Helper method to normalize phone number
  String _normalizePhoneNumber(String phone) {
    // Remove all non-digit characters except +
    return phone.replaceAll(RegExp(r'[^\d+]'), '');
  }

  // Get user's contacts who are on Wrytte (optimized version)
  Future<List<Map<String, dynamic>>> getWrytteContacts(
    List<String> phoneNumbers,
  ) async {
    try {
      if (phoneNumbers.isEmpty) return [];

      final normalizedNumbers =
          phoneNumbers.map(_normalizePhoneNumber).toList();
      final chunks = _splitIntoChunks(normalizedNumbers, 10);

      List<Map<String, dynamic>> wrytteContacts = [];

      for (final chunk in chunks) {
        final usersSnapshot =
            await _firestore
                .collection('users')
                .where('phone', whereIn: chunk)
                .get();

        for (final doc in usersSnapshot.docs) {
          wrytteContacts.add({'id': doc.id, ...doc.data()});
        }
      }

      return wrytteContacts;
    } catch (e) {
      print('Error getting Wrytte contacts: $e');
      return [];
    }
  }

  // Get user statistics
  Future<Map<String, dynamic>> getUserStatistics() async {
    try {
      final uid = await AuthService.instance.getCurrentUserId() ?? '';
      if (uid.isEmpty) throw Exception('No user logged in');

      // Get total chats count
      final chatsCount = await _firestore
          .collection('chats')
          .where('participants', arrayContains: uid)
          .get()
          .then((snapshot) => snapshot.size);

      // Get total messages sent (approximate)
      final messagesCount = await _firestore
          .collectionGroup('messages')
          .where('senderId', isEqualTo: uid)
          .get()
          .then((snapshot) => snapshot.size);

      return {
        'chatsCount': chatsCount,
        'messagesSent': messagesCount,
        'accountCreated':
            FieldValue.serverTimestamp(), // This would be stored in user doc
      };
    } catch (e) {
      print('Error getting user statistics: $e');
      return {'chatsCount': 0, 'messagesSent': 0, 'accountCreated': null};
    }
  }
}
