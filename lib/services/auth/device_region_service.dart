import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Detects the signup region once for the lifetime of this app process.
class DeviceRegionService {
  const DeviceRegionService._();

  static const _channel = MethodChannel('com.example.wrytte/device_region');
  static const _regionKey = 'signup_region_code';
  static Future<String>? _cachedDetection;

  static Future<String> detectOnce() {
    return _cachedDetection ??= _loadOrDetect();
  }

  static Future<String> _loadOrDetect() async {
    final preferences = await SharedPreferences.getInstance();
    final savedRegion = _validRegion(preferences.getString(_regionKey));
    if (savedRegion != null) {
      debugPrint('[Signup.region] source="local" region="$savedRegion"');
      return savedRegion;
    }

    String? region;
    try {
      region = await _channel.invokeMethod<String>('getRegionCode');
    } on PlatformException catch (error) {
      debugPrint('[Signup.region] platform detection failed: $error');
    } on MissingPluginException {
      // Tests and unsupported platforms use the locale fallback below.
    }

    region = _validRegion(region);
    region ??= _validRegion(PlatformDispatcher.instance.locale.countryCode);
    region ??= 'US';
    await preferences.setString(_regionKey, region);
    debugPrint('[Signup.region] source="system" region="$region"');
    return region;
  }

  /// Clears the local value so the next signup visit detects the system again.
  static Future<void> clearForRegionChange() async {
    _cachedDetection = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_regionKey);
  }

  static String? _validRegion(String? value) {
    final normalized = value?.trim().toUpperCase() ?? '';
    return RegExp(r'^[A-Z]{2}$').hasMatch(normalized) ? normalized : null;
  }
}
