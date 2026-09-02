import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class AvatarPreloadService {
  AvatarPreloadService._();

  static final Map<String, Future<void>> _inFlight = {};
  static final Map<String, DateTime> _failedAt = {};
  static const Duration _failureCooldown = Duration(minutes: 5);

  static void clearMemoryCache() {
    _inFlight.clear();
    _failedAt.clear();
  }

  static Future<void> warm(String? rawUrl, {String? cacheIdentity}) async {
    final url = _resolveAvatarUrl(rawUrl);
    if (url.isEmpty) return;
    final identity = cacheIdentity?.trim() ?? '';
    final providerKey = identity.isEmpty ? url : '$identity|$url';

    final failedAt = _failedAt[providerKey];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failureCooldown) {
      return;
    }
    final pending = _inFlight[providerKey];
    if (pending != null) return pending;

    final request = _warm(url, cacheKey: providerKey);
    _inFlight[providerKey] = request;
    return request.whenComplete(() {
      if (identical(_inFlight[providerKey], request)) {
        _inFlight.remove(providerKey);
      }
    });
  }

  static Future<void> _warm(String url, {required String cacheKey}) async {
    final token = await AuthService.instance.getValidBackendToken();
    final provider = CachedNetworkImageProvider(
      url,
      cacheKey: cacheKey,
      headers: _authHeaders(url, token),
    );
    try {
      await _warmImage(provider).timeout(const Duration(seconds: 12));
      _failedAt.remove(cacheKey);
    } catch (_) {
      _failedAt[cacheKey] = DateTime.now();
    }
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

  static Future<void> _warmImage(ImageProvider provider) {
    final completer = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, __) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  static String _resolveAvatarUrl(String? raw) {
    final url = raw?.trim() ?? '';
    if (url.isEmpty) return '';
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

  static Map<String, String>? _authHeaders(String url, String? token) {
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
