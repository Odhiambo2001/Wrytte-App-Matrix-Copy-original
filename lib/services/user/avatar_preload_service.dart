import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/matrix/matrix_client.dart';
import 'package:wrytte/services/matrix/matrix_config.dart';

class AvatarPreloadService {
  AvatarPreloadService._();

  /// Incremented whenever a persistent avatar file is created or promoted.
  /// Visible avatar widgets listen to this so a background retry becomes
  /// visible without requiring a profile/navigation rebuild.
  static final ValueNotifier<int> cacheRevision = ValueNotifier<int>(0);

  static final Map<String, Future<void>> _inFlight = {};
  static final Map<String, DateTime> _failedAt = {};
  static final Map<String, int> _retryAttempts = {};
  static final Map<String, Timer> _retryTimers = {};
  static const Duration _failureCooldown = Duration(minutes: 5);

  static void clearMemoryCache() {
    _inFlight.clear();
    _failedAt.clear();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _retryAttempts.clear();
    cacheRevision.value++;
  }

  static Future<void> warm(String? rawUrl, {String? cacheIdentity}) async {
    final url = _resolveAvatarUrl(rawUrl);
    if (url.isEmpty) return;
    // Deduplicate by the resolved media URL, not by widget/cache identity.
    // The same avatar is rendered by the conversation tile, chat header,
    // profile, and viewer with different identities. Keying by identity made
    // each surface start its own Matrix download and none of them reliably
    // shared the persisted result.
    final requestKey = url;

    final failedAt = _failedAt[requestKey];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failureCooldown) {
      return;
    }
    final pending = _inFlight[requestKey];
    if (pending != null) return pending;

    final request = _warm(url, rawUrl: rawUrl!, cacheKey: requestKey);
    _inFlight[requestKey] = request;
    return request.whenComplete(() {
      if (identical(_inFlight[requestKey], request)) {
        _inFlight.remove(requestKey);
      }
    });
  }

  static Future<void> _warm(
    String url, {
    required String rawUrl,
    required String cacheKey,
  }) async {
    if (await _downloadToPersistentCache(url, rawUrl: rawUrl)) {
      _failedAt.remove(cacheKey);
      _retryAttempts.remove(cacheKey);
      _retryTimers.remove(cacheKey)?.cancel();
      return;
    }
    final token = await AuthService.instance.getValidBackendToken();
    final provider = CachedNetworkImageProvider(
      url,
      cacheKey: cacheKey,
      headers: _authHeaders(url, token),
    );
    try {
      final painted = await _warmImage(provider).timeout(
        const Duration(seconds: 12),
      );
      if (!painted) throw StateError('avatar image resolution failed');
      _failedAt.remove(cacheKey);
      _retryAttempts.remove(cacheKey);
      _retryTimers.remove(cacheKey)?.cancel();
    } catch (_) {
      _failedAt[cacheKey] = DateTime.now();
      _scheduleRetry(url, rawUrl: rawUrl, cacheKey: cacheKey);
    }
  }

  static Future<String?> localPathFor(String? rawUrl) async {
    final url = _resolveAvatarUrl(rawUrl);
    if (url.isEmpty) return null;
    final file = await _cacheFile(url);
    if (await file.exists() && await file.length() > 0) {
      debugPrint(
        '[AvatarCache] local_hit source=persistent path="${file.path}"',
      );
      return file.path;
    }
    final cached = await _networkCacheFile(url);
    if (cached != null) {
      debugPrint(
        '[AvatarCache] local_hit source=flutter_disk path="${cached.path}"',
      );
      return cached.path;
    }
    return null;
  }

  static Future<bool> _downloadToPersistentCache(
    String url, {
    required String rawUrl,
  }) async {
    final file = await _cacheFile(url);
    if (await file.exists() && await file.length() > 0) {
      debugPrint('[AvatarCache] local_hit url="$url" path="${file.path}"');
      return true;
    }
    final cached = await _networkCacheFile(url);
    if (cached != null) {
      final temp = File('${file.path}.promote.tmp');
      await temp.writeAsBytes(await cached.readAsBytes(), flush: true);
      await temp.rename(file.path);
      if (!await file.exists() || await file.length() == 0) return false;
      cacheRevision.value++;
      debugPrint(
        '[AvatarCache] promoted source=flutter_disk path="${file.path}"',
      );
      return true;
    }
    try {
      final token = await AuthService.instance.getValidBackendToken();
      final matrixToken =
          MatrixClientService.instance.accessToken ??
          await AuthService.instance.getMatrixAccessToken();
      final response = await http
          .get(
            Uri.parse(url),
            headers: _authHeaders(
              url,
              token,
              rawUrl: rawUrl,
              matrixToken: matrixToken,
            ),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.isEmpty) {
        debugPrint(
          '[AvatarCache] miss status=${response.statusCode} url="$url"',
        );
        return false;
      }
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(response.bodyBytes, flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
      if (!await file.exists() || await file.length() != response.bodyBytes.length) {
        debugPrint('[AvatarCache] verify_failed url="$url" path="${file.path}"');
        return false;
      }
      cacheRevision.value++;
      debugPrint(
        '[AvatarCache] saved bytes=${response.bodyBytes.length} path="${file.path}"',
      );
      return true;
    } catch (error) {
      debugPrint('[AvatarCache] download_failed url="$url" error="$error"');
      return false;
    }
  }

  static void _scheduleRetry(
    String url, {
    required String rawUrl,
    required String cacheKey,
  }) {
    if (_retryTimers.containsKey(cacheKey)) return;
    final attempt = _retryAttempts[cacheKey] ?? 0;
    if (attempt >= 3) return;
    _retryAttempts[cacheKey] = attempt + 1;
    const delays = <Duration>[
      Duration(seconds: 3),
      Duration(seconds: 15),
      Duration(seconds: 45),
    ];
    final delay = delays[attempt];
    debugPrint(
      '[AvatarCache] retry_scheduled url="$url" attempt=${attempt + 1} delay_s=${delay.inSeconds}',
    );
    _retryTimers[cacheKey] = Timer(delay, () {
      _retryTimers.remove(cacheKey);
      _failedAt.remove(cacheKey);
      unawaited(warm(rawUrl, cacheIdentity: cacheKey));
    });
  }

  static Future<File?> _networkCacheFile(String url) async {
    try {
      final info = await DefaultCacheManager().getFileFromCache(url);
      final file = info?.file;
      if (file != null && await file.exists() && await file.length() > 0) {
        return file;
      }
    } catch (error) {
      debugPrint('[AvatarCache] disk_lookup_failed url="$url" error="$error"');
    }
    return null;
  }

  static Future<File> _cacheFile(String url) async {
    final directory = await getApplicationSupportDirectory();
    final key = sha256.convert(utf8.encode(_stripVersion(url))).toString();
    final directoryPath = Directory('${directory.path}/wrytte_avatar_cache');
    await directoryPath.create(recursive: true);
    return File('${directoryPath.path}/$key.avatar');
  }

  static Future<void> replace({
    required String? oldUrl,
    required String? newUrl,
  }) async {
    final oldResolved = _resolveAvatarUrl(oldUrl);
    final newResolved = _resolveAvatarUrl(newUrl);
    if (newResolved.isEmpty) return;

    final evictTargets = <String>{
      if (oldResolved.isNotEmpty) oldResolved,
      if (oldResolved.isNotEmpty) _stripVersion(oldResolved),
      newResolved,
      _stripVersion(newResolved),
    }..removeWhere((url) => url.isEmpty);

    for (final url in evictTargets) {
      try {
        await CachedNetworkImage.evictFromCache(url);
      } catch (e) {
        debugPrint('[AvatarPreloadService] cache evict skipped url="$url": $e');
      }
    }

    await warm(newResolved);
  }

  static Future<bool> _warmImage(ImageProvider provider) {
    final completer = Completer<bool>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, __) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete(true);
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete(false);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  static String _resolveAvatarUrl(String? raw) {
    final url = raw?.trim() ?? '';
    if (url.isEmpty) return '';
    if (url.startsWith('mxc://')) {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty || uri.pathSegments.isEmpty) {
        return '';
      }
      final homeserver = Uri.tryParse(MatrixConfig.homeserver);
      if (homeserver == null || !homeserver.hasScheme) return '';
      return homeserver
          .resolve(
            '/_matrix/client/v1/media/download/${Uri.encodeComponent(uri.host)}/${Uri.encodeComponent(uri.pathSegments.join('/'))}',
          )
          .replace(
            queryParameters: uri.queryParameters.isEmpty
                ? null
                : uri.queryParameters,
          )
          .toString();
    }
    return url.startsWith('/') ? '${ApiService.baseUrl}$url' : url;
  }

  static String _stripVersion(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return url;
    final params = Map<String, String>.from(uri.queryParameters)..remove('v');
    return uri
        .replace(queryParameters: params.isEmpty ? null : params)
        .toString();
  }

  static Map<String, String>? _authHeaders(
    String url,
    String? token, {
    String? rawUrl,
    String? matrixToken,
  }) {
    if ((rawUrl ?? '').trim().startsWith('mxc://')) {
      final cleanMatrixToken =
          (matrixToken ?? MatrixClientService.instance.accessToken ?? '')
              .trim();
      return cleanMatrixToken.isEmpty
          ? null
          : {'Authorization': 'Bearer $cleanMatrixToken'};
    }
    final clean = token?.trim() ?? '';
    if (clean.isEmpty) return null;
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final isWrytteImage =
        url.startsWith('${ApiService.baseUrl}/usrimg/') ||
        url.startsWith('/usrimg/') ||
        ApiService.isBackendHost(host) ||
        host == 'wrytte.com';
    if (!isWrytteImage) return null;
    return {'Authorization': 'Bearer $clean'};
  }
}
