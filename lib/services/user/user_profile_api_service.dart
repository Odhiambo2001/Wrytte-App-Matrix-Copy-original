import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/file_upload_limits.dart';

/// Handles avatar binary upload only. Profile fields use MatrixProfileService.
class UserProfileApiService {
  UserProfileApiService._();
  static final UserProfileApiService instance = UserProfileApiService._();

  Future<String> uploadAvatarImage(File file) async {
    await FileUploadLimits.validateAvatarImagePath(file.path);

    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Missing backend auth token.');
    }

    final response = await ApiService.postMultipart(
      '/api/UserProfile/UploadAvatarImage',
      const {},
      files: [await http.MultipartFile.fromPath('file', file.path)],
      token: token,
    );
    final avatar = _avatarFromResponse(response);
    if (avatar.isEmpty) {
      throw Exception('Avatar upload completed without an image URL.');
    }
    return avatar;
  }

  String _avatarFromResponse(dynamic response) {
    if (response is! Map) return '';
    for (final key in const ['AvatarImg', 'avatarImg', 'avatarUrl', 'url']) {
      final value = response[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
    }
    return '';
  }
}
