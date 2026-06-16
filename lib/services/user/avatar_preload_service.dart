import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/api_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class AvatarPreloadService {
  AvatarPreloadService._();

  static Future<void> warm(String? rawUrl) async {
    final url = _resolveAvatarUrl(rawUrl);
    if (url.isEmpty) return;

    final token = await AuthService.instance.getValidBackendToken();
    final provider = CachedNetworkImageProvider(
      url,
      headers: _authHeaders(url, token),
    );
    await _warmImage(provider);
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
        host == 'wryttedev.azurewebsites.net' ||
        host == 'wrytte.com';
    if (!isWrytteImage) return null;
    return {'Authorization': 'Bearer $clean'};
  }
}
