import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/device_region_service.dart';

/// Device information collected after signup consent.  The installation key
/// is generated locally and is never used as a hardware identifier; it only
/// lets the backend return the same server-generated device id on retries.
class DeviceMetadata {
  const DeviceMetadata({
    required this.language,
    required this.region,
    required this.model,
    required this.installationId,
  });

  final String language;
  final String region;
  final String model;
  final String installationId;

  Map<String, String> toJson() => {
    'language': language,
    'region': region,
    'deviceModel': model,
    'installationId': installationId,
  };
}

class DeviceMetadataService {
  DeviceMetadataService._();

  static final DeviceMetadataService instance = DeviceMetadataService._();
  static const _installationKey = 'wrytte.installation.id';
  DeviceMetadata? _cached;
  Future<DeviceMetadata>? _collectInFlight;

  Future<DeviceMetadata> collect() async {
    if (_cached != null) return _cached!;
    final inFlight = _collectInFlight;
    if (inFlight != null) return inFlight;
    final future = _collectInternal();
    _collectInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_collectInFlight, future)) _collectInFlight = null;
    }
  }

  Future<DeviceMetadata> _collectInternal() async {
    if (_cached != null) return _cached!;
    final region = await DeviceRegionService.detectOnce();
    final locale = PlatformDispatcher.instance.locale;
    final language =
        locale.languageCode.trim().toLowerCase().isEmpty
            ? 'en'
            : locale.languageCode.trim().toLowerCase();
    final detectedModel = await _deviceModel();
    final model =
        detectedModel.trim().isEmpty ? Platform.operatingSystem : detectedModel;
    final preferences = await SharedPreferences.getInstance();
    var installationId = preferences.getString(_installationKey)?.trim() ?? '';
    if (installationId.isEmpty) {
      final random = Random.secure();
      installationId = List<String>.generate(
        4,
        (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
      ).join('-');
      await preferences.setString(_installationKey, installationId);
    }
    return _cached = DeviceMetadata(
      language: language,
      region: region,
      model: model,
      installationId: installationId,
    );
  }

  Future<Map<String, dynamic>?> registerWithBackend() async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.isEmpty) return null;
    final metadata = await collect();
    final response = await ApiService.postJson(
      '/api/devices/register',
      token: token,
      body: metadata.toJson(),
    );
    return response is Map ? Map<String, dynamic>.from(response) : null;
  }

  Future<String> _deviceModel() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        final manufacturer = android.manufacturer.trim();
        final model = android.model.trim();
        return [
          manufacturer,
          model,
        ].where((value) => value.isNotEmpty).join(' ').trim();
      }
      if (Platform.isIOS) {
        final ios = await info.iosInfo;
        return ios.utsname.machine.trim().isEmpty
            ? ios.model.trim()
            : ios.utsname.machine.trim();
      }
    } on PlatformException catch (error) {
      debugPrint('[DeviceMetadata] model detection failed: $error');
    } catch (error) {
      debugPrint('[DeviceMetadata] model detection failed: $error');
    }
    return Platform.operatingSystem;
  }
}
