import 'package:hive/hive.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';

class LocalUserService {
  static const boxName = 'users_box';

  Future<Box> _box() async => await Hive.openBox(boxName);

  Future<void> saveUser(String phone, String userId) async {
    final box = await _box();
    await box.put(phone, userId);
  }

  Future<Map<String, String>> getUsers(List<String> phones) async {
    final box = await _box();
    final result = <String, String>{};

    for (var phone in phones) {
      final userId = box.get(phone);
      if (userId != null) {
        result[phone] = userId;
      }
    }
    return result;
  }

  String? get matrixUserId => MatrixClientService.instance.userId;

  String? get matrixAccessToken => MatrixClientService.instance.accessToken;
}
