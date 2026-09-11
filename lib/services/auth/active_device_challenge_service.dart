import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/device_metadata_service.dart';
import 'package:wrytte/services/notification_service.dart';

/// Polls the authenticated account's pending active-device challenges. This
/// is the transport for the login code when no SMS is used; it runs only while
/// the user is inside HomeScreen.
class ActiveDeviceChallengeService {
  Timer? _timer;
  bool _pollInFlight = false;
  final Set<String> _shownChallenges = <String>{};

  Future<void> start() async {
    if (_timer != null) return;
    await _poll();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_poll());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _shownChallenges.clear();
  }

  Future<void> _poll() async {
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      final token = await AuthService.instance.getValidBackendToken();
      if (token == null || token.isEmpty) return;
      final userId = await AuthService.instance.getCurrentUserId();
      final deviceId =
          userId == null
              ? null
              : await DeviceMetadataService.instance.rememberedDeviceId(
                userId: userId,
              );
      final response = await ApiService.get(
        '/api/devices/login-challenges/pending',
        token: token,
        queryParameters: {
          if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
        },
      );
      if (response is! List) return;
      for (final raw in response.whereType<Map>()) {
        final challenge = Map<String, dynamic>.from(raw);
        final id = (challenge['challengeId'] ?? '').toString().trim();
        final code = (challenge['code'] ?? '').toString().trim();
        if (id.isEmpty || code.isEmpty || _shownChallenges.contains(id)) {
          continue;
        }
        await NotificationService.instance.showActiveDeviceLoginCode(code, id);
        _shownChallenges.add(id);
      }
    } catch (error) {
      // A failed poll must not interrupt chat or logout. The next tick retries.
      debugPrint('[ActiveDeviceChallenge] poll skipped: ${error.runtimeType}');
    } finally {
      _pollInFlight = false;
    }
  }
}
