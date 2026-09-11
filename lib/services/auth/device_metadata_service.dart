import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/device_region_service.dart';

/// Device information collected after signup consent. The backend associates
/// this metadata with the server-generated device ID; no local installation
/// identifier is created or transmitted.
class DeviceMetadata {
  const DeviceMetadata({
    required this.language,
    required this.region,
    required this.model,
  });

  final String language;
  final String region;
  final String model;

  Map<String, String> toJson() => {
    'language': language,
    'region': region,
    'deviceModel': model,
  };
}

class DeviceMetadataService {
  DeviceMetadataService._();

  static final DeviceMetadataService instance = DeviceMetadataService._();
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
    return _cached = DeviceMetadata(
      language: language,
      region: region,
      model: model,
    );
  }

  /// Registers the device after authentication and returns the authoritative
  /// backend record. When [userId] is supplied it is the ID from the just-
  /// completed login response; this avoids accidentally associating a device
  /// with a stale local session during an account switch.
  Future<Map<String, dynamic>?> registerWithBackend({String? userId}) async {
    final token = await AuthService.instance.getValidBackendToken();
    if (token == null || token.isEmpty) return null;
    final metadata = await collect();
    final requestedUserId = userId?.trim() ?? '';
    final currentUserId =
        requestedUserId.isNotEmpty
            ? requestedUserId
            : await AuthService.instance.getCurrentUserId() ?? '';
    if (currentUserId.trim().isEmpty) return null;
    final remembered = await _rememberedDeviceId(currentUserId);
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
    final returnedUserId =
        (result['userId'] ?? result['userid'] ?? '').toString().trim();
    if (returnedUserId.isNotEmpty &&
        currentUserId.trim().isNotEmpty &&
        returnedUserId != currentUserId.trim()) {
      throw StateError('Device registration returned a different account.');
    }
    final deviceId = (result['deviceId'] ?? '').toString().trim();
    if (currentUserId.trim().isNotEmpty && deviceId.isNotEmpty) {
      await rememberDeviceId(userId: currentUserId, deviceId: deviceId);
    }
    return result;
  }

  /// Stores only the server device id for this account. This is intentionally
  /// separate from session storage so logout can preserve it.
  Future<void> rememberDeviceId({
    required String userId,
    required String deviceId,
  }) async {
    final account = userId.trim();
    final device = deviceId.trim();
    if (account.isEmpty || device.isEmpty) return;
    await _secureStorage.write(key: _deviceIdentityKey(account), value: device);
  }

  Future<String?> rememberedDeviceId({required String userId}) =>
      _rememberedDeviceId(userId);

  Future<String?> _rememberedDeviceId(String userId) async {
    final account = userId.trim();
    if (account.isEmpty) return null;
    return (await _secureStorage.read(
      key: _deviceIdentityKey(account),
    ))?.trim();
  }

  static String _deviceIdentityKey(String userId) =>
      '$deviceIdentityKeyPrefix${userId.trim()}';

  Future<void> markCurrentDeviceLoggedOut({
    required String userId,
    required String token,
  }) async {
    final account = userId.trim();
    final bearer = token.trim();
    if (account.isEmpty || bearer.isEmpty) return;
    final deviceId = await rememberedDeviceId(userId: account);
    String? resolvedDeviceId = deviceId;
    if (resolvedDeviceId == null || resolvedDeviceId.isEmpty) {
      // Recover the identity when local secure storage was unavailable. The
      // authenticated registration endpoint creates and returns a device ID.
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
