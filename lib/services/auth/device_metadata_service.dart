import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
  static const deviceInstallationKey = 'wrytte.device.installation.id';
  static const deviceIdentityKeyPrefix = 'wrytte.device.identity.';
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
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
    installationId =
        installationId.isEmpty
            ? (await _secureStorage.read(key: deviceInstallationKey))?.trim() ??
                ''
            : installationId;
    if (installationId.isEmpty) {
      final random = Random.secure();
      installationId = List<String>.generate(
        4,
        (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
      ).join('-');
    }
    // Shared preferences can be cleared during logout; the secure copy lets
    // this installation recover the same server device id after restart.
    await Future.wait([
      preferences.setString(_installationKey, installationId),
      _secureStorage.write(key: deviceInstallationKey, value: installationId),
    ]);
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
    final currentUserId = await AuthService.instance.getCurrentUserId() ?? '';
    final remembered = await _rememberedDeviceId(
      currentUserId,
      metadata.installationId,
    );
    final requestBody = <String, dynamic>{...metadata.toJson()};
    if (remembered != null && remembered.isNotEmpty) {
      requestBody['deviceId'] = remembered;
    }
    final response = await ApiService.postJson(
      '/api/devices/register',
      token: token,
      body: requestBody,
    );
    if (response is! Map) return null;
    final result = Map<String, dynamic>.from(response);
    final deviceId = (result['deviceId'] ?? '').toString().trim();
    if (currentUserId.trim().isNotEmpty && deviceId.isNotEmpty) {
      await rememberDeviceId(
        userId: currentUserId,
        installationId: metadata.installationId,
        deviceId: deviceId,
      );
    }
    return result;
  }

  /// Stores only the server device id for this account/install pair. This is
  /// intentionally separate from session storage so logout can preserve it.
  Future<void> rememberDeviceId({
    required String userId,
    required String installationId,
    required String deviceId,
  }) async {
    final account = userId.trim();
    final installation = installationId.trim();
    final device = deviceId.trim();
    if (account.isEmpty || installation.isEmpty || device.isEmpty) return;
    await _secureStorage.write(
      key: _deviceIdentityKey(account, installation),
      value: device,
    );
  }

  Future<String?> rememberedDeviceId({
    required String userId,
    required String installationId,
  }) => _rememberedDeviceId(userId, installationId);

  Future<String?> _rememberedDeviceId(
    String userId,
    String installationId,
  ) async {
    final account = userId.trim();
    final installation = installationId.trim();
    if (account.isEmpty || installation.isEmpty) return null;
    return (await _secureStorage.read(
      key: _deviceIdentityKey(account, installation),
    ))?.trim();
  }

  static String _deviceIdentityKey(String userId, String installationId) =>
      '$deviceIdentityKeyPrefix${userId.trim()}.$installationId';

  Future<void> markCurrentDeviceLoggedOut({
    required String userId,
    required String token,
  }) async {
    final account = userId.trim();
    final bearer = token.trim();
    if (account.isEmpty || bearer.isEmpty) return;
    final metadata = await collect();
    final deviceId = await rememberedDeviceId(
      userId: account,
      installationId: metadata.installationId,
    );
    String? resolvedDeviceId = deviceId;
    if (resolvedDeviceId == null || resolvedDeviceId.isEmpty) {
      // Upgrade path for installations created before durable device identity
      // storage existed: the authenticated registration endpoint is
      // idempotent and returns the existing device id when possible.
      final registered = await registerWithBackend();
      resolvedDeviceId = (registered?['deviceId'] ?? '').toString().trim();
    }
    if (resolvedDeviceId.isEmpty) return;
    await ApiService.postJson(
      '/api/devices/logout',
      token: bearer,
      body: {'userId': account, 'deviceId': resolvedDeviceId},
    );
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
