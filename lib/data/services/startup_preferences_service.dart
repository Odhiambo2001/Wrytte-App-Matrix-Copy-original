import 'package:shared_preferences/shared_preferences.dart';

class StartupPreferencesService {
  StartupPreferencesService({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const _introductionSeenKey = 'startup.introduction_seen.v2';

  final SharedPreferencesAsync _preferences;

  Future<bool> hasSeenIntroduction() async {
    return await _preferences.getBool(_introductionSeenKey) ?? false;
  }

  Future<void> markIntroductionSeen() {
    return _preferences.setBool(_introductionSeenKey, true);
  }
}
