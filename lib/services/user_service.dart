import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';

class UserService {
  // The development backend currently exposes no FCM registration route.
  // Keep this null until the backend publishes one canonical endpoint; probing
  // several guessed URLs creates repeated 404s and unnecessary startup work.
  static const String? _fcmTokenEndpoint = null;
  Future<Map<String, dynamic>> getCurrentUserData() async {
    final uid = await AuthService.instance.getCurrentUserId() ?? '';
    final username = await AuthService.instance.getCurrentUsername() ?? '';
    final phone = await AuthService.instance.getSavedPhone() ?? '';
    return {
      'id': uid,
      'uid': uid,
      'name': username,
      'username': username,
      'phone': phone,
      'profileImage': null,
      'isOnline': true,
    };
  }

  Future<Map<String, dynamic>> getUserData(String userId) async => {
    'id': userId,
    'uid': userId,
    'name': userId,
    'username': userId,
    'profileImage': null,
    'isOnline': false,
    'phone': '',
    'lastSeen': null,
  };

  Future<List<Map<String, dynamic>>> getUsersData(List<String> userIds) async =>
      Future.wait(userIds.map(getUserData));

  Future<void> updateUserProfile({
    String? name,
    String? profileImage,
    String? status,
    String? about,
  }) async {
    if (name != null && name.trim().isNotEmpty) {
      await AuthService.instance.updateStoredUsername(name);
    }

    try {
      await MatrixAuthService.instance.restore();
      final client = MatrixClientService.instance.client;
      final matrixUserId = client.userID;
      if (matrixUserId == null) return;
      if (name != null && name.trim().isNotEmpty) {
        await client.setProfileField(matrixUserId, 'm.displayname', {
          'displayname': name.trim(),
        });
      }
      if (profileImage != null &&
          profileImage.isNotEmpty &&
          profileImage.startsWith('mxc://')) {
        await client.setProfileField(matrixUserId, 'm.avatar_url', {
          'avatar_url': profileImage,
        });
      }
    } catch (_) {}
  }

  Future<void> setUserOnlineStatus(bool isOnline) async {}

  Future<List<Map<String, dynamic>>> searchUsersByPhone(
    List<String> phoneNumbers,
  ) async {
    return phoneNumbers
        .map(
          (phone) => {
            'id': phone,
            'uid': phone,
            'phone': _normalizePhone(phone),
            'name': _normalizePhone(phone),
          },
        )
        .toList();
  }

  Future<List<Map<String, dynamic>>> searchUsersByName(String query) async =>
      [];

  Stream<Map<String, dynamic>> getUserStream(String userId) =>
      Stream.value({'id': userId, 'uid': userId, 'name': userId});

  Stream<Map<String, dynamic>> getCurrentUserStream() async* {
    yield await getCurrentUserData();
  }

  Future<bool> userExistsByPhone(String phoneNumber) async => false;

  Future<String?> getUserIdByPhone(String phoneNumber) async => null;

  Future<void> updateFcmToken(String fcmToken) async {
    final cleanedToken = fcmToken.trim();
    if (cleanedToken.isEmpty) return;
    final endpoint = _fcmTokenEndpoint;
    if (endpoint == null) {
      debugPrint(
        '[UserService] FCM token sync skipped: endpoint not configured',
      );
      return;
    }

    final authToken = await AuthService.instance.getToken();
    final userId = await AuthService.instance.getCurrentUserId();
    if (authToken == null ||
        authToken.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      debugPrint(
        '[UserService] FCM token not registered: missing auth session',
      );
      return;
    }

    final body = await _fcmTokenBody(cleanedToken, userId: userId);
    await ApiService.postJson(endpoint, body: body, token: authToken);
  }

  Future<void> removeFcmToken({String? fcmToken}) async {
    final endpoint = _fcmTokenEndpoint;
    if (endpoint == null) return;
    final authToken = await AuthService.instance.getToken();
    final userId = await AuthService.instance.getCurrentUserId();
    if (authToken == null ||
        authToken.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      return;
    }

    final body = await _fcmTokenBody(fcmToken?.trim() ?? '', userId: userId);
    await ApiService.deleteJson(endpoint, body: body, token: authToken);
  }

  Future<Map<String, dynamic>> _fcmTokenBody(
    String fcmToken, {
    required String userId,
  }) async {
    final phone = await AuthService.instance.getSavedPhone() ?? '';
    final matrixUserId = MatrixClientService.instance.userId ?? '';
    final device = await _deviceInfo();
    return {
      'userId': userId,
      'userid': userId,
      'uid': userId,
      'phone': phone,
      'matrixUserId': matrixUserId,
      'matrixuserid': matrixUserId,
      'fcmToken': fcmToken,
      'fcm_token': fcmToken,
      'token': fcmToken,
      'platform': defaultTargetPlatform.name,
      ...device,
    };
  }

  Future<Map<String, dynamic>> _deviceInfo() async {
    if (kIsWeb) return const {'deviceId': 'web', 'deviceName': 'web'};
    final plugin = DeviceInfoPlugin();
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final android = await plugin.androidInfo;
          return {
            'deviceId': android.id,
            'deviceName': '${android.manufacturer} ${android.model}',
            'deviceModel': android.model,
            'osVersion': android.version.release,
          };
        case TargetPlatform.iOS:
          final ios = await plugin.iosInfo;
          return {
            'deviceId': ios.identifierForVendor ?? '',
            'deviceName': ios.name,
            'deviceModel': ios.model,
            'osVersion': ios.systemVersion,
          };
        default:
          return {'deviceId': defaultTargetPlatform.name};
      }
    } catch (_) {
      return {'deviceId': defaultTargetPlatform.name};
    }
  }

  Future<Map<String, dynamic>> getPrivacySettings() async => {
    'lastSeen': 'everyone',
    'profilePhoto': 'everyone',
    'about': 'everyone',
    'readReceipts': true,
  };

  Future<void> updatePrivacySettings({
    String? lastSeen,
    String? profilePhoto,
    String? about,
    bool? readReceipts,
  }) async {}

  Future<void> blockUser(String blockedUserId) async {}

  Future<void> unblockUser(String blockedUserId) async {}

  Future<List<String>> getBlockedUsers() async => [];

  Future<bool> isUserBlocked(String userId) async => false;

  Future<List<Map<String, dynamic>>> getWrytteContacts(
    List<String> phoneNumbers,
  ) => searchUsersByPhone(phoneNumbers);

  Future<Map<String, dynamic>> getUserStatistics() async => {
    'contacts': 0,
    'chats': 0,
    'messages': 0,
  };

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00') && cleaned.length > 4) {
      cleaned = '+${cleaned.substring(2)}';
    }
    if (!cleaned.startsWith('+') && cleaned.isNotEmpty) cleaned = '+$cleaned';
    return cleaned;
  }
}
